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
        // The card's space decides where the payment lands (docs/design/people-and-spaces.md).
        let account = Self.account(forCard: card, in: context)
        var dto = PaymentCapture.movement(merchant: merchant, amountText: amount, card: card, accountId: account?.id,
                                          defaultCurrency: AppSettings.defaultCurrency)
        dto.space_id = Spaces.wire(account?.space ?? "")
        // Decision model, well-known merchants and Apple Intelligence (docs/design/apple-intelligence.md):
        // only acts when it is sure.
        var autoCategory: CategoryItem?
        let brain = Smart.brain(context, space: account?.space ?? "")
        let decision = AppSettings.autoCategory && dto.needs_review == 0
            ? await Smart.categorize(dto, brain: brain)
            : brain.model.decide(brain.calibration, DecisionState(dto))
        if AppSettings.autoCategory, dto.needs_review == 0, decision.band == .act,
           let id = decision.categoryId, let c = brain.categories.first(where: { $0.id == id }) {
            dto.category_id = id
            dto.category_auto = 1
            autoCategory = c
        }
        context.insert(Movement(dto, dirty: true))
        try context.save()
        // Best effort: without signal the payment waits in the queue and syncs later.
        await SyncService.shared.sync()
        // First-week check: remember one payment that could not reach the server right away.
        let capturedId = dto.id
        if AppSettings.offlineCaptureId == nil, SyncService.shared.isLinked,
           let saved = try? context.fetch(FetchDescriptor<Movement>(predicate: #Predicate { $0.id == capturedId })).first, saved.dirty {
            AppSettings.offlineCaptureId = dto.id
        }
        // Not categorized automatically: offer the likely categories in a notification (one tap).
        if dto.needs_review == 1 {
            await PaymentNotifier.askReview(for: dto)
        } else if autoCategory == nil {
            let ranked = decision.ranked.compactMap { r in brain.categories.first { $0.id == r.id } }
            let rest = brain.categories.filter { c in !ranked.contains { $0.id == c.id } }.sorted { $0.displayName < $1.displayName }
            await PaymentNotifier.askCategory(for: dto, ranked: ranked + rest)
        }
        let money = Formatting.money(dto.amount_minor, dto.currency)
        let shown = dto.needs_review == 1
            ? String(localized: "intent.record.savedReview")
            : autoCategory.map { String(localized: "intent.record.savedAuto \(money) \($0.displayName)") }
            ?? String(localized: "intent.record.saved \(money)")
        return .result(dialog: IntentDialog(stringLiteral: shown))
    }

    /// The account whose card matches what Wallet reports, in any space; a new personal account named
    /// after the card otherwise.
    @MainActor
    static func account(forCard card: String?, in context: ModelContext) -> (id: String, space: String)? {
        guard let card = card?.trimmingCharacters(in: .whitespacesAndNewlines), !card.isEmpty else { return nil }
        let accounts = (try? context.fetch(FetchDescriptor<AccountItem>(predicate: #Predicate { $0.deleted == false }))) ?? []
        let key = MerchantKey.normalize(card)
        if let match = accounts.first(where: { MerchantKey.normalize($0.card) == key }) { return (match.id, match.space) }
        let dto = AccountDTO(id: UUID().uuidString, name: String(card.prefix(100)), card: String(card.prefix(100)),
                             updated_at: SyncRules.now())
        context.insert(AccountItem(dto, dirty: true))
        return (dto.id, "")
    }
}

struct HarinaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddMovementIntent(),
            phrases: [
                "voice.phrase.expense \(.applicationName)",
                "voice.phrase.kind \(\.$kind) \(.applicationName)",
                "voice.phrase.add \(.applicationName)",
            ],
            shortTitle: "voice.short",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: RecordPaymentIntent(),
            phrases: ["intent.phrase \(.applicationName)"],
            shortTitle: "intent.record.short",
            systemImageName: "creditcard"
        )
    }
}
