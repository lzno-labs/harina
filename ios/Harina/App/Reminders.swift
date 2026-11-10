// SPDX-License-Identifier: MPL-2.0
import Foundation
import HarinaKit
import SwiftData
import UserNotifications

/// Local notifications for fixed charges, payment reminders and envelopes
/// (docs/design/budgets-reminders-savings.md). Nothing leaves the phone.
@MainActor
enum Reminders {
    static let prefix = "harina.alert."
    static let maxScheduled = 40

    static var hour: Int {
        get { AppSettings.defaults.object(forKey: "alertsHour") as? Int ?? 9 }
        set { AppSettings.defaults.set(newValue, forKey: "alertsHour") }
    }
    static var fixedAlerts: Bool { AppSettings.defaults.object(forKey: "fixedAlerts") as? Bool ?? true }
    static var reminderAlerts: Bool { AppSettings.defaults.object(forKey: "reminderAlerts") as? Bool ?? true }
    static var budgetAlerts: Bool { AppSettings.defaults.object(forKey: "budgetAlerts") as? Bool ?? true }

    private static var context: ModelContext { Store.container.mainContext }

    /// Replaces every scheduled alert with the current ones (after each sync and when the app opens).
    static func reschedule(now: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        guard await PaymentNotifier.authorized() else { return }

        var alerts: [(id: String, at: Date, title: String, body: String)] = []
        let cal = Calendar.current
        func at(_ day: Date) -> Date? { cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) }

        if fixedAlerts {
            let movements = (try? context.fetch(FetchDescriptor<Movement>(predicate: #Predicate { $0.deleted == false }))) ?? []
            for r in Insights.recurring(movements.map(\.dto), now: now) where r.status != .missed {
                guard let next = ISODate.date(r.next), let dayBefore = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: next)),
                      let when = at(dayBefore), when > now, when < now.addingTimeInterval(35 * 86400) else { continue }
                let money = Formatting.money(r.amount, r.currency)
                alerts.append((prefix + "fixed." + r.key, when, String(localized: "alerts.fixedTitle \(r.merchant)"),
                               String(localized: "alerts.fixedBody \(money)")))
            }
        }
        if reminderAlerts {
            let reminders = (try? context.fetch(FetchDescriptor<ReminderItem>(predicate: #Predicate { $0.deleted == false }))) ?? []
            for r in reminders {
                let st = MoneyTools.reminder(r.dto, now: now)
                guard st.status != .paid else { continue }
                let amount = r.amountMinor.map { Formatting.money($0, r.currency ?? AppSettings.defaultCurrency) }
                for (offset, key) in [(-1, "alerts.reminderTomorrow"), (0, "alerts.reminderToday")] {
                    guard let day = cal.date(byAdding: .day, value: offset, to: st.due), let when = at(day), when > now else { continue }
                    let body = amount.map { String(localized: "alerts.reminderAmount \($0)") } ?? L("alerts.reminderNoAmount")
                    alerts.append((prefix + "rem.\(r.uid).\(offset)", when, L(key) + " " + r.name, body))
                }
            }
        }
        for a in alerts.sorted(by: { $0.at < $1.at }).prefix(maxScheduled) {
            let content = UNMutableNotificationContent()
            content.title = a.title
            content.body = a.body
            content.sound = .default
            let parts = cal.dateComponents([.year, .month, .day, .hour, .minute], from: a.at)
            try? await center.add(UNNotificationRequest(identifier: a.id, content: content,
                                                        trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
        }
    }

    /// After a payment is saved: how much is left in its envelope, if it has one. Alerts at 80 % and 100 %.
    static func envelopeLine(for dto: TransactionDTO, space: String, notify: Bool) async -> String? {
        guard dto.kind == "expense", let cat = dto.category_id else { return nil }
        let budgets = (try? context.fetch(FetchDescriptor<BudgetItem>(predicate: #Predicate { $0.deleted == false && $0.space == space }))) ?? []
        guard let b = budgets.first(where: { $0.currency == dto.currency && $0.categoryIds.contains(cat) }) else { return nil }
        let movements = (try? context.fetch(FetchDescriptor<Movement>(predicate: #Predicate { $0.deleted == false && $0.space == space }))) ?? []
        let st = MoneyTools.budget(b.dto, movements.map(\.dto), month: MoneyTools.month(Date()))
        let line = st.left >= 0
            ? String(localized: "alerts.envelopeLeft \(Formatting.money(st.left, b.currency)) \(b.name)")
            : String(localized: "alerts.envelopeOver \(b.name) \(Formatting.money(-st.left, b.currency))")
        if notify, budgetAlerts, st.level != .ok, await PaymentNotifier.authorized() {
            let content = UNMutableNotificationContent()
            content.title = st.level == .over ? String(localized: "alerts.envelopeOverTitle \(b.name)") : String(localized: "alerts.envelopeWarnTitle \(b.name)")
            content.body = line
            content.sound = .default
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: prefix + "env." + dto.id, content: content, trigger: nil))
        }
        return line
    }
}
