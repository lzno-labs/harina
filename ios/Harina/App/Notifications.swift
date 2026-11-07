// SPDX-License-Identifier: MPL-2.0
import HarinaKit
import SwiftData
import SwiftUI
import UIKit
import UserNotifications

/// "Pick a category" notifications after an Apple Pay capture (docs/design/siri-y-notificaciones.md).
enum PaymentNotifier {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "categoryNotifications") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "categoryNotifications") }
    }

    /// Asks once; later calls return the current answer without a prompt.
    @discardableResult
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func authorized() async -> Bool {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        return s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
    }

    /// Offers the most likely categories for a payment that harina could not categorize on its own.
    @MainActor
    static func askCategory(for dto: TransactionDTO, ranked: [CategoryItem]) async {
        guard enabled, await authorized() else { return }
        let center = UNUserNotificationCenter.current()
        let picks = Array(ranked.prefix(NotificationIds.maxButtons))
        let categoryId = NotificationIds.category(for: picks.map(\.id))
        var actions = picks.map { c in
            UNNotificationAction(identifier: NotificationIds.action(for: c.id), title: "\(Looks.of(c).glyph) \(c.displayName)", options: [])
        }
        actions.append(UNNotificationAction(identifier: NotificationIds.other, title: L("notify.other"), options: [.foreground]))
        let category = UNNotificationCategory(identifier: categoryId, actions: actions, intentIdentifiers: [], options: [])
        await register(category)

        let content = UNMutableNotificationContent()
        let money = Formatting.money(dto.amount_minor, dto.currency)
        content.title = dto.merchant.map { String(localized: "notify.title \(money) \($0)") } ?? money
        content.body = L("notify.body")
        content.sound = .default
        content.categoryIdentifier = categoryId
        content.userInfo = [NotificationIds.movementKey: dto.id]
        try? await center.add(UNNotificationRequest(identifier: dto.id, content: content, trigger: nil))
    }

    /// A payment whose amount could not be read: tapping opens "Por revisar".
    @MainActor
    static func askReview(for dto: TransactionDTO) async {
        guard enabled, await authorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = L("notify.reviewTitle")
        content.body = String(localized: "notify.reviewBody \(dto.raw_amount ?? "?")")
        content.sound = .default
        content.categoryIdentifier = NotificationIds.review
        content.userInfo = [NotificationIds.movementKey: dto.id]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: dto.id, content: content, trigger: nil))
    }

    private static func register(_ category: UNNotificationCategory) async {
        let center = UNUserNotificationCenter.current()
        let existing = await center.notificationCategories()
        var order = (UserDefaults.standard.stringArray(forKey: "notificationCategoryOrder") ?? []).filter { $0 != category.identifier }
        order.append(category.identifier)
        let keep = Set(NotificationIds.trimmed(order))
        var all = existing.filter { keep.contains($0.identifier) && $0.identifier != category.identifier }
        all.insert(category)
        center.setNotificationCategories(all)
        UserDefaults.standard.set(NotificationIds.trimmed(order), forKey: "notificationCategoryOrder")
        // The system registers categories asynchronously; give it a moment before posting.
        try? await Task.sleep(nanoseconds: 300_000_000)
    }
}

/// Receives notification actions, also when harina was not running.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let movementId = info[NotificationIds.movementKey] as? String else { return }
        if let categoryId = NotificationIds.categoryId(fromAction: response.actionIdentifier) {
            await MainActor.run {
                let context = Store.container.mainContext
                let id = movementId
                if let m = try? context.fetch(FetchDescriptor<Movement>(predicate: #Predicate { $0.id == id })).first {
                    m.setCategory(byPerson: categoryId)
                    m.touch()
                    try? context.save()
                }
            }
            await SyncService.shared.sync()
        } else if response.actionIdentifier != UNNotificationDismissActionIdentifier {
            // "Otra…" or a tap on the notification: open harina on "Por revisar".
            UserDefaults.standard.set(3, forKey: "openTab")
        }
    }
}
