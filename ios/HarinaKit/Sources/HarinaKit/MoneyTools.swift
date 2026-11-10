// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Envelopes, savings pots and payment reminders (docs/design/budgets-reminders-savings.md).
/// Same rules as `public/insights.js` on the web.
public enum MoneyTools {
    public enum Level: String, Sendable { case ok, warn, over }

    public struct BudgetState: Equatable, Sendable {
        public var spent: Int64
        public var left: Int64
        public var ratio: Double
        public var level: Level
    }

    /// Local "YYYY-MM" of a date.
    public static func month(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    /// Spending of a month in an envelope's categories and currency; warn at 80 %, over at 100 %.
    public static func budget(_ b: BudgetDTO, _ txs: [TransactionDTO], month: String, calendar: Calendar = .current) -> BudgetState {
        let ids = Set(b.categoryIds)
        var spent: Int64 = 0
        for t in txs where (t.deleted ?? 0) == 0 && t.kind == "expense" && t.currency == b.currency {
            guard let c = t.category_id, ids.contains(c), let d = ISODate.date(t.occurred_at) else { continue }
            if Self.month(d, calendar: calendar) == month { spent += t.amount_minor }
        }
        let ratio = b.amount_minor > 0 ? Double(spent) / Double(b.amount_minor) : 0
        return BudgetState(spent: spent, left: b.amount_minor - spent, ratio: ratio, level: ratio >= 1 ? .over : ratio >= 0.8 ? .warn : .ok)
    }

    public struct PotState: Equatable, Sendable {
        public var balance: Int64
        public var saved: Int64
        public var goal: Int64?
        public var progress: Double?
    }

    /// Savings minus withdrawals minus expenses paid from the pot.
    public static func pot(_ p: PotDTO, _ txs: [TransactionDTO]) -> PotState {
        var saved: Int64 = 0
        var out: Int64 = 0
        for t in txs where (t.deleted ?? 0) == 0 && t.pot_id == p.id {
            if t.kind == "saving" { saved += t.amount_minor } else if t.kind == "withdrawal" || t.kind == "expense" { out += t.amount_minor }
        }
        let balance = saved - out
        let progress = p.goal_minor.map { $0 > 0 ? max(0, min(1, Double(balance) / Double($0))) : 0 }
        return PotState(balance: balance, saved: saved, goal: p.goal_minor, progress: progress)
    }

    public enum ReminderStatus: String, Sendable { case paid, late, today, soon, upcoming }

    public struct ReminderState: Equatable, Sendable {
        public var due: Date
        public var days: Int
        public var status: ReminderStatus
    }

    /// Next due date (day 31 is the month's last day) and status; paid this month moves it to next month.
    public static func reminder(_ r: ReminderDTO, now: Date = Date(), calendar: Calendar = .current) -> ReminderState {
        let today = calendar.startOfDay(for: now)
        func due(addingMonths n: Int) -> Date {
            let first = calendar.date(from: calendar.dateComponents([.year, .month], from: today))!
            let start = calendar.date(byAdding: .month, value: n, to: first)!
            let days = calendar.range(of: .day, in: .month, for: start)?.count ?? 28
            return calendar.date(byAdding: .day, value: min(r.day_of_month, days) - 1, to: start)!
        }
        let paid = r.paid_month == month(today, calendar: calendar)
        let d = due(addingMonths: paid ? 1 : 0)
        let days = calendar.dateComponents([.day], from: today, to: d).day ?? 0
        let status: ReminderStatus = paid ? .paid : days < 0 ? .late : days == 0 ? .today : days <= 3 ? .soon : .upcoming
        return ReminderState(due: d, days: days, status: status)
    }
}
