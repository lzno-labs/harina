// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Wire format of the sync API (snake_case JSON). Same fields as the server tables.
public struct TransactionDTO: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var amount_minor: Int64
    public var currency: String
    public var category_id: String?
    public var account_id: String?
    /// Savings pot (docs/design/budgets-reminders-savings.md): kind saving/withdrawal, or an expense paid from it.
    public var pot_id: String?
    public var merchant: String?
    public var note: String?
    public var card: String?
    public var source: String
    public var raw_amount: String?
    public var needs_review: Int?
    /// 0 set by the person, 1 set automatically, 2 automatic then corrected.
    public var category_auto: Int?
    public var occurred_at: String
    public var updated_at: Int64
    public var deleted: Int?
    /// Space of the row (docs/adr/0006-people-and-spaces.md); nil means the person's personal space.
    public var space_id: String?
    /// Who added it (set by the server).
    public var created_by: String?

    public init(id: String, kind: String, amount_minor: Int64, currency: String, category_id: String? = nil,
                account_id: String? = nil, merchant: String? = nil, note: String? = nil, card: String? = nil,
                source: String, raw_amount: String? = nil, needs_review: Int? = 0, category_auto: Int? = 0,
                occurred_at: String, updated_at: Int64, deleted: Int? = 0, space_id: String? = nil, created_by: String? = nil,
                pot_id: String? = nil) {
        self.id = id; self.kind = kind; self.amount_minor = amount_minor; self.currency = currency
        self.category_id = category_id; self.account_id = account_id; self.merchant = merchant; self.note = note
        self.card = card; self.source = source; self.raw_amount = raw_amount; self.needs_review = needs_review
        self.category_auto = category_auto
        self.occurred_at = occurred_at; self.updated_at = updated_at; self.deleted = deleted
        self.space_id = space_id; self.created_by = created_by; self.pot_id = pot_id
    }
}

public struct CategoryDTO: Codable, Equatable, Sendable {
    public var id: String
    public var key: String?
    public var name: String?
    public var icon: String?
    public var color: String?
    public var updated_at: Int64
    public var deleted: Int?
    public var space_id: String?
    public init(id: String, key: String? = nil, name: String? = nil, icon: String? = nil, color: String? = nil,
                updated_at: Int64, deleted: Int? = 0, space_id: String? = nil) {
        self.id = id; self.key = key; self.name = name; self.icon = icon; self.color = color
        self.updated_at = updated_at; self.deleted = deleted; self.space_id = space_id
    }
}

public struct AccountDTO: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var card: String?
    public var updated_at: Int64
    public var deleted: Int?
    public var space_id: String?
    public init(id: String, name: String, card: String? = nil, updated_at: Int64, deleted: Int? = 0, space_id: String? = nil) {
        self.id = id; self.name = name; self.card = card; self.updated_at = updated_at; self.deleted = deleted; self.space_id = space_id
    }
}

/// A monthly payment Harina cannot see (card, electricity): day of the month, amount optional.
public struct ReminderDTO: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var amount_minor: Int64?
    public var currency: String?
    public var day_of_month: Int
    public var category_id: String?
    public var account_id: String?
    /// "YYYY-MM" of the last payment.
    public var paid_month: String?
    public var note: String?
    public var updated_at: Int64
    public var deleted: Int?
    public var space_id: String?
    public init(id: String, name: String, amount_minor: Int64? = nil, currency: String? = nil, day_of_month: Int,
                category_id: String? = nil, account_id: String? = nil, paid_month: String? = nil, note: String? = nil,
                updated_at: Int64, deleted: Int? = 0, space_id: String? = nil) {
        self.id = id; self.name = name; self.amount_minor = amount_minor; self.currency = currency; self.day_of_month = day_of_month
        self.category_id = category_id; self.account_id = account_id; self.paid_month = paid_month; self.note = note
        self.updated_at = updated_at; self.deleted = deleted; self.space_id = space_id
    }
}

/// An envelope: a monthly limit for some categories. `category_ids` is the JSON list the server stores.
public struct BudgetDTO: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var amount_minor: Int64
    public var currency: String
    public var category_ids: String
    public var updated_at: Int64
    public var deleted: Int?
    public var space_id: String?
    public init(id: String, name: String, amount_minor: Int64, currency: String, category_ids: [String],
                updated_at: Int64, deleted: Int? = 0, space_id: String? = nil) {
        self.id = id; self.name = name; self.amount_minor = amount_minor; self.currency = currency
        self.category_ids = (try? String(data: JSONEncoder().encode(category_ids), encoding: .utf8)) ?? "[]"
        self.updated_at = updated_at; self.deleted = deleted; self.space_id = space_id
    }
    public var categoryIds: [String] { (try? JSONDecoder().decode([String].self, from: Data(category_ids.utf8))) ?? [] }
}

/// A savings pot with an optional goal.
public struct PotDTO: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var currency: String
    public var goal_minor: Int64?
    public var goal_date: String?
    public var updated_at: Int64
    public var deleted: Int?
    public var space_id: String?
    public init(id: String, name: String, currency: String, goal_minor: Int64? = nil, goal_date: String? = nil,
                updated_at: Int64, deleted: Int? = 0, space_id: String? = nil) {
        self.id = id; self.name = name; self.currency = currency; self.goal_minor = goal_minor; self.goal_date = goal_date
        self.updated_at = updated_at; self.deleted = deleted; self.space_id = space_id
    }
}

public struct SyncRecords: Codable, Equatable, Sendable {
    public var accounts: [AccountDTO]
    public var categories: [CategoryDTO]
    public var transactions: [TransactionDTO]
    public var reminders: [ReminderDTO]
    public var budgets: [BudgetDTO]
    public var pots: [PotDTO]
    public init(accounts: [AccountDTO] = [], categories: [CategoryDTO] = [], transactions: [TransactionDTO] = [],
                reminders: [ReminderDTO] = [], budgets: [BudgetDTO] = [], pots: [PotDTO] = []) {
        self.accounts = accounts; self.categories = categories; self.transactions = transactions
        self.reminders = reminders; self.budgets = budgets; self.pots = pots
    }
    /// Older servers send only the first three lists.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try c.decodeIfPresent([AccountDTO].self, forKey: .accounts) ?? []
        categories = try c.decodeIfPresent([CategoryDTO].self, forKey: .categories) ?? []
        transactions = try c.decodeIfPresent([TransactionDTO].self, forKey: .transactions) ?? []
        reminders = try c.decodeIfPresent([ReminderDTO].self, forKey: .reminders) ?? []
        budgets = try c.decodeIfPresent([BudgetDTO].self, forKey: .budgets) ?? []
        pots = try c.decodeIfPresent([PotDTO].self, forKey: .pots) ?? []
    }
    public var isEmpty: Bool {
        accounts.isEmpty && categories.isEmpty && transactions.isEmpty && reminders.isEmpty && budgets.isEmpty && pots.isEmpty
    }
}

public struct PullResponse: Codable, Sendable {
    public var seq: Int64
    public var more: Bool
    public var records: SyncRecords
    /// The person's spaces, with members (docs/design/people-and-spaces.md).
    public var spaces: [SpaceInfo]?
}

public struct PushRequest: Codable, Sendable {
    public var changes: SyncRecords
    public init(changes: SyncRecords) { self.changes = changes }
}

public struct PushResponse: Codable, Sendable {
    public var seq: Int64
    public var records: SyncRecords
}

public struct LinkResponse: Codable, Sendable {
    public var deviceId: String
    public var token: String
}

public enum ISODate {
    nonisolated(unsafe) static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) static let plain = ISO8601DateFormatter()

    public static func string(_ date: Date) -> String { withFraction.string(from: date) }
    public static func date(_ text: String) -> Date? { withFraction.date(from: text) ?? plain.date(from: text) }
}

/// A space as the server lists it, with its members' names (docs/design/people-and-spaces.md).
public struct SpaceInfo: Codable, Equatable, Sendable, Identifiable {
    public struct Member: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String?
        public var role: String
        public var me: Bool
    }
    public var id: String
    public var kind: String
    public var name: String?
    public var role: String
    public var members: [Member]
    public var isPersonal: Bool { kind == "personal" }
}

