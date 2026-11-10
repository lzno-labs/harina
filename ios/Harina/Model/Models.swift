// SPDX-License-Identifier: MPL-2.0
import Foundation
import HarinaKit
import SwiftData

/// Local copies of the synced records. `dirty` marks a change not pushed to the server yet.
@Model
final class Movement {
    @Attribute(.unique) var id: String
    var kind: String
    var amountMinor: Int64
    var currency: String
    var categoryId: String?
    var accountId: String?
    var merchant: String?
    var note: String?
    var card: String?
    var source: String
    var rawAmount: String?
    var needsReview: Bool
    /// 0 set by the person, 1 set automatically by the decision model, 2 automatic then corrected.
    var categoryAuto: Int = 0
    var occurredAt: Date
    var updatedAt: Int64
    var deleted: Bool
    var dirty: Bool

    init(_ dto: TransactionDTO, dirty: Bool) {
        id = dto.id; kind = dto.kind; amountMinor = dto.amount_minor; currency = dto.currency
        categoryId = dto.category_id; accountId = dto.account_id; merchant = dto.merchant; note = dto.note
        card = dto.card; source = dto.source; rawAmount = dto.raw_amount; needsReview = (dto.needs_review ?? 0) != 0
        categoryAuto = dto.category_auto ?? 0
        occurredAt = ISODate.date(dto.occurred_at) ?? Date(); updatedAt = dto.updated_at
        deleted = (dto.deleted ?? 0) != 0; self.dirty = dirty
    }

    func update(from dto: TransactionDTO) {
        kind = dto.kind; amountMinor = dto.amount_minor; currency = dto.currency; categoryId = dto.category_id
        accountId = dto.account_id; merchant = dto.merchant; note = dto.note; card = dto.card; source = dto.source
        rawAmount = dto.raw_amount; needsReview = (dto.needs_review ?? 0) != 0
        categoryAuto = dto.category_auto ?? 0
        occurredAt = ISODate.date(dto.occurred_at) ?? occurredAt; updatedAt = dto.updated_at
        deleted = (dto.deleted ?? 0) != 0; dirty = false
    }

    var dto: TransactionDTO {
        TransactionDTO(id: id, kind: kind, amount_minor: amountMinor, currency: currency, category_id: categoryId,
                       account_id: accountId, merchant: merchant, note: note, card: card, source: source,
                       raw_amount: rawAmount, needs_review: needsReview ? 1 : 0, category_auto: categoryAuto,
                       occurred_at: ISODate.string(occurredAt),
                       updated_at: updatedAt, deleted: deleted ? 1 : 0)
    }

    /// Marks a local edit: new clock value, waiting to be pushed.
    func touch() {
        updatedAt = max(SyncRules.now(), updatedAt + 1)
        dirty = true
    }

    var isPendingReview: Bool { !deleted && (needsReview || (kind == "expense" && categoryId == nil)) }

    /// Sets the category from a person's choice: a changed automatic category counts as a correction.
    func setCategory(byPerson id: String?) {
        if categoryAuto == 1 { categoryAuto = id == categoryId ? 1 : 2 }
        categoryId = id
    }
}

@Model
final class CategoryItem {
    @Attribute(.unique) var id: String
    var key: String?
    var name: String?
    /// Emoji and #rrggbb color chosen by the person; nil means the suggestion's or a generated look.
    var icon: String?
    var color: String?
    var updatedAt: Int64
    var deleted: Bool
    var dirty: Bool

    init(_ dto: CategoryDTO, dirty: Bool) {
        id = dto.id; key = dto.key; name = dto.name; icon = dto.icon; color = dto.color; updatedAt = dto.updated_at
        deleted = (dto.deleted ?? 0) != 0; self.dirty = dirty
    }

    func update(from dto: CategoryDTO) {
        key = dto.key; name = dto.name; icon = dto.icon; color = dto.color; updatedAt = dto.updated_at
        deleted = (dto.deleted ?? 0) != 0; dirty = false
    }

    var dto: CategoryDTO {
        CategoryDTO(id: id, key: key, name: name, icon: icon, color: color, updated_at: updatedAt, deleted: deleted ? 1 : 0)
    }

    /// Marks a local edit: new clock value, waiting to be pushed.
    func touch() {
        updatedAt = max(SyncRules.now(), updatedAt + 1)
        dirty = true
    }

    /// Default categories show their translated name until renamed.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        return L("category." + (key ?? "other"))
    }
}

@Model
final class AccountItem {
    @Attribute(.unique) var id: String
    var name: String
    var card: String?
    var updatedAt: Int64
    var deleted: Bool
    var dirty: Bool

    init(_ dto: AccountDTO, dirty: Bool) {
        id = dto.id; name = dto.name; card = dto.card; updatedAt = dto.updated_at
        deleted = (dto.deleted ?? 0) != 0; self.dirty = dirty
    }

    func update(from dto: AccountDTO) {
        name = dto.name; card = dto.card; updatedAt = dto.updated_at; deleted = (dto.deleted ?? 0) != 0; dirty = false
    }

    var dto: AccountDTO { AccountDTO(id: id, name: name, card: card, updated_at: updatedAt, deleted: deleted ? 1 : 0) }
}

enum Store {
    /// One container for the app and its App Intents (they run in the app's process).
    static let container: ModelContainer = {
        do {
            return try ModelContainer(for: Movement.self, CategoryItem.self, AccountItem.self)
        } catch {
            fatalError("SwiftData store failed to open: \(error)")
        }
    }()
}

enum AppSettings {
    static let defaults = UserDefaults.standard
    static var serverURL: URL? {
        get { defaults.string(forKey: "serverURL").flatMap(URL.init(string:)) }
        set { defaults.set(newValue?.absoluteString, forKey: "serverURL") }
    }
    static var lastSeq: Int64 {
        get { Int64(defaults.integer(forKey: "lastSeq")) }
        set { defaults.set(Int(newValue), forKey: "lastSeq") }
    }
    /// Currency used when a payment's text has no sign or code.
    static var defaultCurrency: String {
        get { defaults.string(forKey: "defaultCurrency") ?? "CRC" }
        set { defaults.set(newValue, forKey: "defaultCurrency") }
    }
    /// Off until the person turns it on (onboarding or settings).
    static var appLock: Bool {
        get { defaults.object(forKey: "appLock") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "appLock") }
    }
    /// The decision model may categorize Apple Pay payments on its own (docs/design/fijos-y-categoria-automatica.md).
    static var autoCategory: Bool {
        get { defaults.object(forKey: "autoCategory") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoCategory") }
    }
    /// Apple Intelligence on the iPhone for merchants harina does not know yet (docs/design/apple-intelligence.md).
    /// Runs on the device only; the person can turn it off in settings.
    static var appleIntelligence: Bool {
        get { defaults.object(forKey: "appleIntelligence") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "appleIntelligence") }
    }
    static var onboarded: Bool {
        get { defaults.bool(forKey: "onboarded") }
        set { defaults.set(newValue, forKey: "onboarded") }
    }
    static var onboardedAt: Date? {
        get { defaults.object(forKey: "onboardedAt") as? Date }
        set { defaults.set(newValue, forKey: "onboardedAt") }
    }
    /// Id of the first payment captured with no signal, for the first-week check.
    static var offlineCaptureId: String? {
        get { defaults.string(forKey: "offlineCaptureId") }
        set { defaults.set(newValue, forKey: "offlineCaptureId") }
    }
}
