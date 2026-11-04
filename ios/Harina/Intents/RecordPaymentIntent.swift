// SPDX-License-Identifier: MPL-2.0
import AppIntents
import Foundation
import HarinaKit
import SwiftData

/// "Registrar pago en harina": run by a Shortcuts "Transaction" automation on every Apple Pay
/// payment (docs/design/apple-pay-capture.md). Saves on the iPhone first, so it works offline.
struct RecordPaymentIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.record.title"
    static let description = IntentDescription("intent.record.description")
    static let openAppWhenRun = false

    @Parameter(title: "intent.param.amount")
    var amount: String

    @Parameter(title: "intent.param.merchant")
    var merchant: String?

    @Parameter(title: "intent.param.card")
    var card: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = Store.container.mainContext
        let accountId = Self.account(forCard: card, in: context)
        let dto = PaymentCapture.movement(merchant: merchant, amountText: amount, card: card, accountId: accountId,
                                          defaultCurrency: AppSettings.defaultCurrency)
        context.insert(Movement(dto, dirty: true))
        try context.save()
        // Best effort: without signal the payment waits in the queue and syncs later.
        await SyncService.shared.sync()
        let shown = dto.needs_review == 1
            ? String(localized: "intent.record.savedReview")
            : String(localized: "intent.record.saved \(Formatting.money(dto.amount_minor, dto.currency))")
        return .result(dialog: IntentDialog(stringLiteral: shown))
    }

    /// The account whose card matches what Wallet reports; a new account named after the card otherwise.
    @MainActor
    static func account(forCard card: String?, in context: ModelContext) -> String? {
        guard let card = card?.trimmingCharacters(in: .whitespacesAndNewlines), !card.isEmpty else { return nil }
        let accounts = (try? context.fetch(FetchDescriptor<AccountItem>(predicate: #Predicate { $0.deleted == false }))) ?? []
        let key = MerchantKey.normalize(card)
        if let match = accounts.first(where: { MerchantKey.normalize($0.card) == key }) { return match.id }
        let dto = AccountDTO(id: UUID().uuidString, name: String(card.prefix(100)), card: String(card.prefix(100)),
                             updated_at: SyncRules.now())
        context.insert(AccountItem(dto, dirty: true))
        return dto.id
    }
}

struct HarinaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RecordPaymentIntent(),
            phrases: ["intent.phrase \(.applicationName)"],
            shortTitle: "intent.record.short",
            systemImageName: "creditcard"
        )
    }
}
