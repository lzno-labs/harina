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
    public var merchant: String?
    public var note: String?
    public var card: String?
    public var source: String
    public var raw_amount: String?
    public var needs_review: Int?
    public var occurred_at: String
    public var updated_at: Int64
    public var deleted: Int?

    public init(id: String, kind: String, amount_minor: Int64, currency: String, category_id: String? = nil,
                account_id: String? = nil, merchant: String? = nil, note: String? = nil, card: String? = nil,
                source: String, raw_amount: String? = nil, needs_review: Int? = 0, occurred_at: String,
                updated_at: Int64, deleted: Int? = 0) {
        self.id = id; self.kind = kind; self.amount_minor = amount_minor; self.currency = currency
        self.category_id = category_id; self.account_id = account_id; self.merchant = merchant; self.note = note
        self.card = card; self.source = source; self.raw_amount = raw_amount; self.needs_review = needs_review
        self.occurred_at = occurred_at; self.updated_at = updated_at; self.deleted = deleted
    }
}

public struct CategoryDTO: Codable, Equatable, Sendable {
    public var id: String
    public var key: String?
    public var name: String?
    public var updated_at: Int64
    public var deleted: Int?
    public init(id: String, key: String? = nil, name: String? = nil, updated_at: Int64, deleted: Int? = 0) {
        self.id = id; self.key = key; self.name = name; self.updated_at = updated_at; self.deleted = deleted
    }
}

public struct AccountDTO: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var card: String?
    public var updated_at: Int64
    public var deleted: Int?
    public init(id: String, name: String, card: String? = nil, updated_at: Int64, deleted: Int? = 0) {
        self.id = id; self.name = name; self.card = card; self.updated_at = updated_at; self.deleted = deleted
    }
}

public struct SyncRecords: Codable, Equatable, Sendable {
    public var accounts: [AccountDTO]
    public var categories: [CategoryDTO]
    public var transactions: [TransactionDTO]
    public init(accounts: [AccountDTO] = [], categories: [CategoryDTO] = [], transactions: [TransactionDTO] = []) {
        self.accounts = accounts; self.categories = categories; self.transactions = transactions
    }
    public var isEmpty: Bool { accounts.isEmpty && categories.isEmpty && transactions.isEmpty }
}

public struct PullResponse: Codable, Sendable {
    public var seq: Int64
    public var more: Bool
    public var records: SyncRecords
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
