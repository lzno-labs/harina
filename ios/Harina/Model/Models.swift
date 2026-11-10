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
    /// Space of the movement; "" is the person's personal space (docs/design/people-and-spaces.md).
    var space: String = ""
    /// Who added it, in a shared space (person id from the server).
    var createdBy: String?

    init(_ dto: TransactionDTO, dirty: Bool) {
        space = Spaces.local(dto.space_id); createdBy = dto.created_by
        id = dto.id; kind = dto.kind; amountMinor = dto.amount_minor; currency = dto.currency
        categoryId = dto.category_id; accountId = dto.account_id; merchant = dto.merchant; note = dto.note
        card = dto.card; source = dto.source; rawAmount = dto.raw_amount; needsReview = (dto.needs_review ?? 0) != 0
        categoryAuto = dto.category_auto ?? 0
        occurredAt = ISODate.date(dto.occurred_at) ?? Date(); updatedAt = dto.updated_at
        deleted = (dto.deleted ?? 0) != 0; self.dirty = dirty
    }

    func update(from dto: TransactionDTO) {
        space = Spaces.local(dto.space_id); createdBy = dto.created_by ?? createdBy
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
                       updated_at: updatedAt, deleted: deleted ? 1 : 0, space_id: Spaces.wire(space), created_by: createdBy)
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
    /// "space:id": suggested categories keep the same id in every space.
    @Attribute(.unique) var uid: String
    var id: String
    var space: String = ""
    var key: String?
    var name: String?
    /// Emoji and #rrggbb color chosen by the person; nil means the suggestion's or a generated look.
    var icon: String?
    var color: String?
    var updatedAt: Int64
    var deleted: Bool
    var dirty: Bool

    init(_ dto: CategoryDTO, dirty: Bool) {
        space = Spaces.local(dto.space_id); uid = Spaces.uid(Spaces.local(dto.space_id), dto.id)
        id = dto.id; key = dto.key; name = dto.name; icon = dto.icon; color = dto.color; updatedAt = dto.updated_at
        deleted = (dto.deleted ?? 0) != 0; self.dirty = dirty
    }

    func update(from dto: CategoryDTO) {
        key = dto.key; name = dto.name; icon = dto.icon; color = dto.color; updatedAt = dto.updated_at
        deleted = (dto.deleted ?? 0) != 0; dirty = false
    }

    var dto: CategoryDTO {
        CategoryDTO(id: id, key: key, name: name, icon: icon, color: color, updated_at: updatedAt, deleted: deleted ? 1 : 0,
                    space_id: Spaces.wire(space))
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
    /// The card's space: its Apple Pay payments land there.
    var space: String = ""

    init(_ dto: AccountDTO, dirty: Bool) {
        space = Spaces.local(dto.space_id)
        id = dto.id; name = dto.name; card = dto.card; updatedAt = dto.updated_at
        deleted = (dto.deleted ?? 0) != 0; self.dirty = dirty
    }

    func update(from dto: AccountDTO) {
        space = Spaces.local(dto.space_id)
        name = dto.name; card = dto.card; updatedAt = dto.updated_at; deleted = (dto.deleted ?? 0) != 0; dirty = false
    }

    var dto: AccountDTO { AccountDTO(id: id, name: name, card: card, updated_at: updatedAt, deleted: deleted ? 1 : 0, space_id: Spaces.wire(space)) }
}

enum Store {
    /// One container for the app and its App Intents (they run in the app's process).
    static let container: ModelContainer = {
        do {
            // Spaces changed the category key (ADR-0006): a new store file; test data was discarded.
            let url = URL.applicationSupportDirectory.appending(path: "harina-spaces.store")
            return try ModelContainer(for: Movement.self, CategoryItem.self, AccountItem.self,
                                      configurations: ModelConfiguration(url: url))
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
    /// The person agreed to the hosted decision model on a device without Apple Intelligence
    /// (docs/design/hosted-decision-model.md). Mirrors the server, which also enforces it.
    static var hostedDecider: Bool {
        get { defaults.bool(forKey: "hostedDecider") }
        set { defaults.set(newValue, forKey: "hostedDecider") }
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

/// Spaces on the iPhone (docs/design/people-and-spaces.md). Locally "" is the personal space, so data
/// captured before linking needs no rewrite; shared spaces use their server id.
enum Spaces {
    static var list: [SpaceInfo] {
        get { (AppSettings.defaults.data(forKey: "spaces")).flatMap { try? JSONDecoder().decode([SpaceInfo].self, from: $0) } ?? [] }
        set { AppSettings.defaults.set(try? JSONEncoder().encode(newValue), forKey: "spaces") }
    }
    static var personalId: String? { list.first(where: \.isPersonal)?.id }

    /// Server space id to local ("" for personal or none).
    static func local(_ wire: String?) -> String {
        guard let wire, wire != personalId else { return "" }
        return wire
    }
    /// Local space to the server's (nil lets the server use the personal space).
    static func wire(_ local: String) -> String? { local.isEmpty ? nil : local }
    static func uid(_ space: String, _ id: String) -> String { "\(space):\(id)" }

    static var shared: [SpaceInfo] { list.filter { !$0.isPersonal } }
    /// The space the person is looking at ("" personal); a space they left falls back to personal.
    static var current: String { valid(AppSettings.defaults.string(forKey: "space") ?? "") }
    static func valid(_ space: String) -> String { space.isEmpty || list.contains { $0.id == space } ? space : "" }
    static func info(_ local: String) -> SpaceInfo? { local.isEmpty ? list.first(where: \.isPersonal) : list.first { $0.id == local } }
    static func name(_ local: String) -> String {
        local.isEmpty ? L("spaces.personal") : (info(local)?.name ?? L("spaces.personal"))
    }
    /// "Ana" for a movement someone else added in a shared space.
    static func addedBy(_ m: Movement) -> String? {
        guard !m.space.isEmpty, let by = m.createdBy, let member = info(m.space)?.members.first(where: { $0.id == by }), !member.me else { return nil }
        return member.name ?? L("spaces.someone")
    }
}

extension Array where Element == Movement {
    func inSpace(_ space: String) -> [Movement] { filter { $0.space == space } }
}
extension Array where Element == CategoryItem {
    func inSpace(_ space: String) -> [CategoryItem] { filter { $0.space == space } }
}
extension Array where Element == AccountItem {
    func inSpace(_ space: String) -> [AccountItem] { filter { $0.space == space } }
}

