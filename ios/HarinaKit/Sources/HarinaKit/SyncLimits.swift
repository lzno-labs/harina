// SPDX-License-Identifier: MPL-2.0
import Foundation

/// The server's text limits (src/sync.js), counted the way the server counts: UTF-16 code units,
/// where an emoji takes two or more. Text is cut to fit before it is sent, so no record is refused
/// for its length (docs/adr/0008-partial-push.md).
public enum SyncLimits {
    /// The longest run of whole characters that fits in `max` UTF-16 code units.
    public static func clip(_ text: String, _ max: Int) -> String {
        if text.utf16.count <= max { return text }
        var used = 0
        var end = text.startIndex
        for character in text {
            let size = character.utf16.count
            if used + size > max { break }
            used += size
            end = text.index(after: end)
        }
        return String(text[..<end])
    }

    public static func clip(_ text: String?, _ max: Int) -> String? { text.map { clip($0, max) } }
}

public extension TransactionDTO {
    func clipped() -> TransactionDTO {
        var t = self
        t.merchant = SyncLimits.clip(merchant, 200)
        t.note = SyncLimits.clip(note, 1000)
        t.card = SyncLimits.clip(card, 100)
        t.raw_amount = SyncLimits.clip(raw_amount, 100)
        return t
    }
}

public extension AccountDTO {
    func clipped() -> AccountDTO {
        var a = self
        a.name = SyncLimits.clip(name, 100)
        a.card = SyncLimits.clip(card, 100)
        return a
    }
}

public extension CategoryDTO {
    func clipped() -> CategoryDTO {
        var c = self
        c.key = SyncLimits.clip(key, 40)
        c.name = SyncLimits.clip(name, 100)
        c.icon = SyncLimits.clip(icon, 16)
        return c
    }
}

public extension ReminderDTO {
    func clipped() -> ReminderDTO {
        var r = self
        r.name = SyncLimits.clip(name, 100)
        r.note = SyncLimits.clip(note, 500)
        return r
    }
}

public extension BudgetDTO {
    func clipped() -> BudgetDTO {
        var b = self
        b.name = SyncLimits.clip(name, 100)
        return b
    }
}

public extension PotDTO {
    func clipped() -> PotDTO {
        var p = self
        p.name = SyncLimits.clip(name, 100)
        return p
    }
}

public extension SyncRecords {
    func clipped() -> SyncRecords {
        SyncRecords(accounts: accounts.map { $0.clipped() }, categories: categories.map { $0.clipped() },
                    transactions: transactions.map { $0.clipped() }, reminders: reminders.map { $0.clipped() },
                    budgets: budgets.map { $0.clipped() }, pots: pots.map { $0.clipped() })
    }

    /// Pushes of at most `size` records (the server takes 500). Accounts, categories, reminders,
    /// envelopes and pots go first, so a movement never points at a record the server lacks.
    func chunked(size: Int) -> [SyncRecords] {
        var out: [SyncRecords] = []
        var current = SyncRecords()
        var count = 0
        func add(_ put: (inout SyncRecords) -> Void) {
            if count == size {
                out.append(current)
                current = SyncRecords()
                count = 0
            }
            put(&current)
            count += 1
        }
        for x in accounts { add { $0.accounts.append(x) } }
        for x in categories { add { $0.categories.append(x) } }
        for x in reminders { add { $0.reminders.append(x) } }
        for x in budgets { add { $0.budgets.append(x) } }
        for x in pots { add { $0.pots.append(x) } }
        for x in transactions { add { $0.transactions.append(x) } }
        if count > 0 { out.append(current) }
        return out
    }
}

/// A change the server refused (docs/adr/0008-partial-push.md). It stays on the iPhone, marked to
/// send, until it is fixed or deleted.
public struct RejectedChange: Codable, Equatable, Sendable {
    public var entity: String
    public var id: String
    public var space_id: String?
    /// "invalid_record", "invalid_space" or "invalid_entity".
    public var error: String
    /// The field that broke a rule, for "invalid_record".
    public var field: String?

    public init(entity: String, id: String, space_id: String? = nil, error: String, field: String? = nil) {
        self.entity = entity; self.id = id; self.space_id = space_id; self.error = error; self.field = field
    }

    /// Unique in a list: the same id can exist in two spaces (suggested categories).
    public var key: String { "\(entity):\(space_id ?? ""):\(id)" }
}
