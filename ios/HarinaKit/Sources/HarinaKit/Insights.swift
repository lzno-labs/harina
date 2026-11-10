// SPDX-License-Identifier: MPL-2.0
import Foundation

// Insights computed on the device from the person's own movements
// (docs/design/fijos-y-categoria-automatica.md). Mirrors public/insights.js; both are checked
// against tests/fixtures/insights.json. Keep them in step.

private let day: Double = 86_400_000

private func millis(_ iso: String) -> Double {
    (ISODate.date(iso)?.timeIntervalSince1970 ?? 0) * 1000
}

private func iso(_ ms: Double) -> String {
    ISODate.string(Date(timeIntervalSince1970: ms / 1000))
}

// MARK: - Decision model for categories

/// What the model answers about.
public struct DecisionState: Sendable {
    public var merchant: String?
    public var card: String?
    public var amountMinor: Int64?
    public var currency: String?
    public init(merchant: String?, card: String?, amountMinor: Int64?, currency: String?) {
        self.merchant = merchant; self.card = card; self.amountMinor = amountMinor; self.currency = currency
    }
    public init(_ t: TransactionDTO) {
        self.init(merchant: t.merchant, card: t.card, amountMinor: t.amount_minor, currency: t.currency)
    }
}

public struct Prediction: Sendable {
    public var ranked: [(id: String, p: Double)]
    public var confidence: Double
    public var knownMerchant: Bool
    public var merchantSignal: Bool
}

public struct Calibration: Sendable, Equatable {
    /// Lowest confidence that was right at least 95 times in 100 on the person's history; nil = not yet.
    public var threshold: Double?
    public var cases: Int
    public var accuracy: Double?
    public var precision: Double?
    public var coverage: Double
}

public enum Band: String, Sendable { case act, suggest, ask }

public struct Decision: Sendable {
    public var band: Band
    public var categoryId: String?
    public var confidence: Double
    public var ranked: [(id: String, p: Double)]
    /// Who made the call: the person's history or Apple Intelligence.
    public var source: DecisionSource = .model
}

public enum DecisionSource: String, Sendable { case model, ai }

/// Multinomial naive Bayes over merchant, merchant words, card and amount bucket.
public struct CategoryModel: Sendable {
    struct Class: Sendable {
        var id: String
        var docs = 0
        var total = 0
        var counts: [String: Int] = [:]
    }

    public static let suggestAt = 0.4
    public static let targetPrecision = 0.95
    public static let minCalibrationCases = 20
    static let thresholds: [Double] = [50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 99].map { $0 / 100 }
    static let merchantWeight = 3

    var docs = 0
    var classes: [Class] = []
    var vocab: Set<String> = []

    public init() {}

    public static func features(_ s: DecisionState) -> [String] {
        var out: [String] = []
        let m = MerchantKey.normalize(s.merchant)
        if !m.isEmpty {
            for _ in 0..<merchantWeight { out.append("m:\(m)") }
            for w in m.split(separator: " ") where w.count >= 2 && !w.allSatisfy(\.isNumber) { out.append("w:\(w)") }
        }
        let c = MerchantKey.normalize(s.card)
        if !c.isEmpty { out.append("c:\(c)") }
        if let cur = s.currency, !cur.isEmpty, let a = s.amountMinor, a >= 0 {
            out.append("a:\(cur):\(Int(floor(log2(Double(a) / 100 + 1))))")
        }
        return out
    }

    public static func isLabel(_ t: TransactionDTO, active: Set<String>) -> Bool {
        guard (t.deleted ?? 0) == 0, t.kind == "expense", let c = t.category_id, active.contains(c) else { return false }
        return (t.category_auto ?? 0) != 1
    }

    static func byDate(_ a: TransactionDTO, _ b: TransactionDTO) -> Bool {
        a.occurred_at != b.occurred_at ? a.occurred_at < b.occurred_at : a.id < b.id
    }

    public mutating func learn(_ t: TransactionDTO) {
        guard let cat = t.category_id else { return }
        let i: Int
        if let found = classes.firstIndex(where: { $0.id == cat }) { i = found } else {
            classes.append(Class(id: cat)); i = classes.count - 1
        }
        classes[i].docs += 1
        docs += 1
        for f in Self.features(DecisionState(t)) {
            classes[i].counts[f, default: 0] += 1
            classes[i].total += 1
            vocab.insert(f)
        }
    }

    public static func train(_ txs: [TransactionDTO], active: Set<String>) -> CategoryModel {
        var m = CategoryModel()
        for t in txs.filter({ isLabel($0, active: active) }).sorted(by: byDate) { m.learn(t) }
        return m
    }

    public func predict(_ s: DecisionState) -> Prediction {
        let all = Self.features(s)
        let known = vocab.contains("m:\(MerchantKey.normalize(s.merchant))")
        let signal = all.contains { ($0.hasPrefix("m:") || $0.hasPrefix("w:")) && vocab.contains($0) }
        let n = classes.count
        guard n > 0 else { return Prediction(ranked: [], confidence: 0, knownMerchant: known, merchantSignal: signal) }
        let v = Double(vocab.count)
        let fs = all.filter { vocab.contains($0) }
        var scores: [(String, Double)] = []
        for c in classes {
            var lp = log(Double(c.docs) / Double(docs))
            for f in fs { lp += log(Double((c.counts[f] ?? 0) + 1) / (Double(c.total) + v)) }
            scores.append((c.id, lp))
        }
        let maxScore = scores.map(\.1).max() ?? 0
        let exps = scores.map { ($0.0, exp($0.1 - maxScore)) }
        let sum = exps.reduce(0) { $0 + $1.1 }
        let ranked = exps.map { (id: $0.0, p: $0.1 / sum) }
            .sorted { $0.p != $1.p ? $0.p > $1.p : $0.id < $1.id }
        let confidence = n < 2 ? 0 : max(0, (ranked[0].p - 1 / Double(n)) / (1 - 1 / Double(n)))
        return Prediction(ranked: ranked, confidence: confidence, knownMerchant: known, merchantSignal: signal)
    }

    /// Replays the labels in date order, each predicted from the earlier ones, and picks the lowest
    /// threshold whose predictions were right at least 95 times in 100 (over 20 or more cases).
    public static func calibrate(_ txs: [TransactionDTO], active: Set<String>) -> Calibration {
        var model = CategoryModel()
        var cases: [(confidence: Double, correct: Bool, known: Bool)] = []
        for t in txs.filter({ isLabel($0, active: active) }).sorted(by: byDate) {
            if model.classes.count >= 2 && model.docs >= 10 {
                let r = model.predict(DecisionState(t))
                cases.append((r.confidence, r.ranked[0].id == t.category_id, r.knownMerchant))
            }
            model.learn(t)
        }
        let accuracy = cases.isEmpty ? nil : Double(cases.filter(\.correct).count) / Double(cases.count)
        let known = cases.filter(\.known)
        for t in thresholds {
            let above = known.filter { $0.confidence >= t }
            if above.count < minCalibrationCases { continue }
            let precision = Double(above.filter(\.correct).count) / Double(above.count)
            if precision >= targetPrecision {
                return Calibration(threshold: t, cases: cases.count, accuracy: accuracy, precision: precision,
                                   coverage: known.isEmpty ? 0 : Double(above.count) / Double(known.count))
            }
        }
        return Calibration(threshold: nil, cases: cases.count, accuracy: accuracy, precision: nil, coverage: 0)
    }

    /// Act (assign automatically), suggest (highlight in review) or ask.
    public func decide(_ calibration: Calibration, _ s: DecisionState) -> Decision {
        let r = predict(s)
        let top = r.ranked.first
        var band = Band.ask
        if top != nil, let t = calibration.threshold, r.knownMerchant, r.confidence >= t {
            band = .act
        } else if top != nil, r.merchantSignal, r.confidence >= Self.suggestAt {
            band = .suggest
        }
        return Decision(band: band, categoryId: top?.id, confidence: r.confidence, ranked: r.ranked)
    }

    /// Automatic categories kept versus corrected by the person.
    public static func liveStats(_ txs: [TransactionDTO]) -> (auto: Int, corrected: Int, precision: Double?) {
        let live = txs.filter { ($0.deleted ?? 0) == 0 }
        let auto = live.filter { $0.category_auto == 1 }.count
        let corrected = live.filter { $0.category_auto == 2 }.count
        return (auto, corrected, auto + corrected > 0 ? Double(auto) / Double(auto + corrected) : nil)
    }
}

// MARK: - Recurring expenses

public enum Cadence: String, Sendable, CaseIterable {
    case weekly, monthly, yearly
    var window: ClosedRange<Double> {
        switch self {
        case .weekly: 5...9
        case .monthly: 25...35
        case .yearly: 350...380
        }
    }
    var grace: Double {
        switch self {
        case .weekly: 2
        case .monthly: 5
        case .yearly: 15
        }
    }
    var perMonth: Double {
        switch self {
        case .weekly: 52.0 / 12.0
        case .monthly: 1
        case .yearly: 1.0 / 12.0
        }
    }
}

public enum RecurringStatus: String, Sendable { case soon, scheduled, missed }

public struct PriceChange: Sendable, Equatable {
    public var from: Int64
    public var to: Int64
}

public struct Recurring: Sendable, Identifiable {
    public var id: String { key }
    public var key: String
    public var merchant: String
    public var currency: String
    public var amount: Int64
    public var cadence: Cadence
    public var period: Int
    public var count: Int
    public var sure: Bool
    public var last: String
    public var next: String
    public var daysToNext: Int
    public var status: RecurringStatus
    public var priceChange: PriceChange?
    public var categoryId: String?
    public var monthly: Int64
}

public struct MonthProjection: Sendable, Equatable {
    public var spent: Int64
    public var fixedRemaining: Int64
    public var dailyVariable: Int64
    public var projected: Int64
}

public enum Insights {
    private static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    private static func same(_ a: Int64, _ b: Int64) -> Bool {
        Double(abs(a - b)) / Double(min(a, b)) <= 0.02
    }

    /// A stable price that changed in one of the last two charges; varying bills never qualify.
    public static func priceChange(_ amounts: [Int64]) -> PriceChange? {
        let n = amounts.count
        var i = n - 1
        while i > 0 && same(amounts[i], amounts[i - 1]) { i -= 1 }
        if i == 0 || i < n - 2 { return nil }
        let before = Array(amounts[..<i]), after = Array(amounts[i...])
        let stable: ([Int64]) -> Bool = { xs in xs.allSatisfy { same($0, xs[0]) } }
        return stable(before) && stable(after) ? PriceChange(from: before[before.count - 1], to: after[after.count - 1]) : nil
    }

    /// Expenses with the same merchant and currency, a regular cadence and a similar amount.
    public static func recurring(_ txs: [TransactionDTO], now: Date = Date()) -> [Recurring] {
        var groups: [String: [TransactionDTO]] = [:]
        for t in txs where (t.deleted ?? 0) == 0 && t.kind == "expense" {
            let k = MerchantKey.normalize(t.merchant)
            if k.isEmpty { continue }
            groups["\(k)|\(t.currency)", default: []].append(t)
        }
        let nowMs = now.timeIntervalSince1970 * 1000
        var out: [Recurring] = []
        for (key, unsorted) in groups where unsorted.count >= 2 {
            let list = unsorted.sorted(by: CategoryModel.byDate)
            let times = list.map { millis($0.occurred_at) }
            let intervals = (1..<times.count).map { (times[$0] - times[$0 - 1]) / day }
            let period = median(intervals)
            guard let cadence = Cadence.allCases.first(where: { $0.window.contains(period) }) else { continue }
            let inWindow = intervals.filter { cadence.window.contains($0) }.count
            if Double(inWindow) / Double(intervals.count) < 0.75 { continue }
            let amounts = list.map(\.amount_minor)
            guard let lo = amounts.min(), let hi = amounts.max(), lo > 0, Double(hi) / Double(lo) <= 1.35 else { continue }
            let last = list[list.count - 1]
            let lastTime = times[times.count - 1]
            if (nowMs - lastTime) / day > 2.5 * period { continue } // ended
            let next = lastTime + ((period * day) / 60_000).rounded() * 60_000
            let daysToNext = (next - nowMs) / day
            let status: RecurringStatus = -daysToNext > cadence.grace ? .missed : daysToNext <= 7 ? .soon : .scheduled
            out.append(Recurring(
                key: key, merchant: last.merchant ?? key, currency: last.currency, amount: last.amount_minor,
                cadence: cadence, period: Int(period.rounded()), count: list.count, sure: list.count >= 3,
                last: iso(lastTime), next: iso(next), daysToNext: Int(daysToNext.rounded(.up)), status: status,
                priceChange: priceChange(amounts), categoryId: last.category_id,
                monthly: Int64((Double(last.amount_minor) * cadence.perMonth).rounded())
            ))
        }
        return out.sorted { $0.next != $1.next ? $0.next < $1.next : $0.key < $1.key }
    }

    /// Month-end estimate for one currency, from day 3 of the current month.
    public static func projectMonth(_ txs: [TransactionDTO], recurring: [Recurring], currency: String,
                                    now: Date = Date(), calendar: Calendar = .current) -> MonthProjection? {
        let dayOfMonth = calendar.component(.day, from: now)
        if dayOfMonth < 3 { return nil }
        guard let interval = calendar.dateInterval(of: .month, for: now) else { return nil }
        let start = interval.start.timeIntervalSince1970 * 1000
        let end = interval.end.timeIntervalSince1970 * 1000
        let nowMs = now.timeIntervalSince1970 * 1000
        let daysInMonth = ((end - start) / day).rounded()
        let fixedKeys = Set(recurring.filter { $0.currency == currency }.map(\.key))
        var spent: Int64 = 0, fixedSoFar: Int64 = 0
        for t in txs where (t.deleted ?? 0) == 0 && t.kind == "expense" && t.currency == currency {
            let at = millis(t.occurred_at)
            if at < start || at > nowMs { continue }
            spent += t.amount_minor
            if fixedKeys.contains("\(MerchantKey.normalize(t.merchant))|\(currency)") { fixedSoFar += t.amount_minor }
        }
        var fixedRemaining: Int64 = 0
        for r in recurring where r.currency == currency {
            let next = millis(r.next)
            if next < nowMs {
                if millis(r.last) < start { fixedRemaining += r.amount }
                continue
            }
            var d = next
            while d < end {
                fixedRemaining += r.amount
                d += Double(r.period) * day
            }
        }
        let dailyVariable = Double(spent - fixedSoFar) / Double(dayOfMonth)
        let projected = (Double(spent + fixedRemaining) + dailyVariable * (daysInMonth - Double(dayOfMonth))).rounded()
        return MonthProjection(spent: spent, fixedRemaining: fixedRemaining,
                               dailyVariable: Int64(dailyVariable.rounded()), projected: Int64(projected))
    }
}
