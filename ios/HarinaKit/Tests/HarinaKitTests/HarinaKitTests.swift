// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import HarinaKit

final class AmountParserTests: XCTestCase {
    func testWalletFormats() {
        let cases: [(String, Int64, String?)] = [
            ("₡4 500,00", 450_000, "CRC"),
            ("₡4\u{00A0}500,00", 450_000, "CRC"),
            ("CRC 4,500.00", 450_000, "CRC"),
            ("$12.50", 1250, "USD"),
            ("12,50 US$", 1250, "USD"),
            ("USD 1,234.5", 123_450, "USD"),
            ("4500", 450_000, nil),
            ("4.500", 450_000, nil),
            ("1.234.567,89", 123_456_789, nil),
        ]
        for (text, minor, currency) in cases {
            XCTAssertEqual(AmountParser.parse(text), ParsedAmount(minor: minor, currency: currency), text)
        }
    }

    func testRejectsNonAmounts() {
        for text in ["", "abc", "-5", "₡", ","] { XCTAssertNil(AmountParser.parse(text), text) }
    }

    func testPlain() {
        XCTAssertEqual(Money.plain(minor: 450_050, currency: "CRC"), "4500.50")
        XCTAssertEqual(Money.plain(minor: 5, currency: "USD"), "0.05")
        XCTAssertEqual(Money.plain(minor: 1500, currency: "JPY"), "1500")
    }
}

final class CaptureTests: XCTestCase {
    func testCapturedPaymentIsUncategorizedExpense() {
        let t = PaymentCapture.movement(merchant: " Automercado ", amountText: "₡4 500,00", card: "BAC Visa",
                                        accountId: "a1", defaultCurrency: "CRC", updatedAt: 1)
        XCTAssertEqual(t.kind, "expense")
        XCTAssertEqual(t.source, "apple_pay")
        XCTAssertNil(t.category_id)
        XCTAssertEqual(t.amount_minor, 450_000)
        XCTAssertEqual(t.currency, "CRC")
        XCTAssertEqual(t.merchant, "Automercado")
        XCTAssertEqual(t.account_id, "a1")
        XCTAssertEqual(t.needs_review, 0)
    }

    func testUnreadableAmountIsKeptForReview() {
        let t = PaymentCapture.movement(merchant: nil, amountText: "importe ???", card: nil, accountId: nil, defaultCurrency: "CRC")
        XCTAssertEqual(t.needs_review, 1)
        XCTAssertEqual(t.amount_minor, 0)
        XCTAssertEqual(t.raw_amount, "importe ???")
    }

    func testGuessedCurrencyNeedsReview() {
        let t = PaymentCapture.movement(merchant: "Soda", amountText: "4500", card: nil, accountId: nil, defaultCurrency: "CRC")
        XCTAssertEqual(t.currency, "CRC")
        XCTAssertEqual(t.needs_review, 1)
    }

    func testDateRoundTrip() {
        let t = PaymentCapture.movement(merchant: "x", amountText: "$1.00", card: nil, accountId: nil, defaultCurrency: "CRC",
                                        at: Date(timeIntervalSince1970: 1_793_000_000))
        XCTAssertEqual(ISODate.date(t.occurred_at)?.timeIntervalSince1970, 1_793_000_000)
    }
}

final class SyncRulesTests: XCTestCase {
    func testLastWriterWins() {
        XCTAssertTrue(SyncRules.serverWins(localUpdatedAt: nil, localDirty: false, serverUpdatedAt: 1))
        XCTAssertTrue(SyncRules.serverWins(localUpdatedAt: 5, localDirty: false, serverUpdatedAt: 1))
        XCTAssertFalse(SyncRules.serverWins(localUpdatedAt: 5, localDirty: true, serverUpdatedAt: 1))
        XCTAssertTrue(SyncRules.serverWins(localUpdatedAt: 5, localDirty: true, serverUpdatedAt: 9))
    }

    func testMerchantKeyMatchesServer() {
        XCTAssertEqual(MerchantKey.normalize("AUTOMERCADO  Escazú!"), "automercado escazu")
        XCTAssertEqual(MerchantKey.normalize(nil), "")
    }

    func testWireFormatMatchesServer() throws {
        let json = #"{"seq":9,"more":false,"records":{"accounts":[],"categories":[{"id":"default-food","key":"food","name":null,"updated_at":0,"deleted":0,"seq":1}],"transactions":[{"id":"t1","kind":"expense","amount_minor":450000,"currency":"CRC","category_id":null,"account_id":null,"merchant":"Soda","note":null,"card":null,"source":"apple_pay","raw_amount":null,"needs_review":0,"occurred_at":"2026-11-04T12:00:00Z","updated_at":5,"deleted":0,"seq":8}]}}"#
        let r = try JSONDecoder().decode(PullResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.records.categories.first?.key, "food")
        XCTAssertEqual(r.records.transactions.first?.amount_minor, 450_000)
        XCTAssertNotNil(ISODate.date(r.records.transactions[0].occurred_at))
    }

    func testCSV() {
        let t = TransactionDTO(id: "t1", kind: "expense", amount_minor: 450_050, currency: "CRC", merchant: "=cmd", source: "manual",
                               occurred_at: "2026-11-02T12:00:00Z", updated_at: 1)
        let csv = CSVExport.make([t], headers: Array(repeating: "h", count: 12), categoryName: { _ in "" },
                                 accountName: { _ in "" }, label: { $0 })
        XCTAssertTrue(csv.contains("2026-11-02T12:00:00Z,expense,4500.50,CRC,,,'=cmd,,,manual,0,t1"))
    }
}

final class OnboardingLogicTests: XCTestCase {
    func testCatalogMatchesTheServerDefaults() {
        XCTAssertEqual(CategoryCatalog.all.filter(\.on).map(\.key),
                       ["food", "groceries", "transport", "home", "health", "entertainment", "other"])
        XCTAssertEqual(CategoryCatalog.suggestion("coffee")?.id, "default-coffee")
        XCTAssertEqual(Set(CategoryCatalog.all.map(\.key)).count, CategoryCatalog.all.count)
    }

    func testColors() {
        XCTAssertEqual(CategoryCatalog.hex("#22c58b"), 0x22C58B)
        XCTAssertNil(CategoryCatalog.hex("red"))
        XCTAssertEqual(CategoryCatalog.shade(0xFFFFFF, 0.5), 0x7F7F7F)
        XCTAssertEqual(CategoryCatalog.firstEmoji("👍🏽 hola"), "👍🏽")
    }

    func testLinkRequest() {
        let ok = LinkRequest.parse(URL(string: "harina://link?server=https%3A%2F%2Fharina.lzno.app&code=K7QF-M2XA")!)
        XCTAssertEqual(ok?.server.host, "harina.lzno.app")
        XCTAssertEqual(ok?.code, "K7QF-M2XA")
        XCTAssertNotNil(LinkRequest.parse(URL(string: "harina://link?server=http://localhost:8787&code=K7QFM2XA")!))
        for bad in [
            "harina://link?server=http://evil.example&code=K7QFM2XA",
            "harina://link?server=https://u:p@evil.example&code=K7QFM2XA",
            "harina://link?code=K7QFM2XA",
            "harina://link?server=https://harina.lzno.app&code=1",
            "other://link?server=https://harina.lzno.app&code=K7QFM2XA",
            "harina://other?server=https://harina.lzno.app&code=K7QFM2XA",
        ] {
            XCTAssertNil(LinkRequest.parse(URL(string: bad)!), bad)
        }
    }

    func testCategoryWireFormatHasLook() throws {
        let c = try JSONDecoder().decode(CategoryDTO.self, from: Data(##"{"id":"c1","key":null,"name":"Gym","icon":"🏋️","color":"#16a34a","updated_at":5,"deleted":0,"seq":3}"##.utf8))
        XCTAssertEqual(c.icon, "🏋️")
        XCTAssertEqual(c.color, "#16a34a")
    }
}

/// Same answers as public/insights.js on the shared fixture (tests/fixtures/insights.json).
final class InsightsParityTests: XCTestCase {
    struct Fixture: Decodable {
        struct Pred: Decodable { let band: String; let categoryId: String?; let confidence: Double }
        struct Cal: Decodable { let threshold: Double?; let cases: Int; let accuracy: Double?; let coverage: Double }
        struct Change: Decodable { let from: Int64; let to: Int64 }
        struct Rec: Decodable {
            let key: String, cadence: String, period: Int, count: Int, confidence: String, next: String, status: String
            let priceChange: Change?, amount: Int64, monthly: Int64, daysToNext: Int
        }
        struct Proj: Decodable { let spent: Int64; let fixedRemaining: Int64; let dailyVariable: Int64; let projected: Int64 }
        struct Expected: Decodable {
            let calibration: Cal, predictions: [Pred], recurring: [Rec]
            let projection: [String: Proj?]
        }
        let now: String
        let transactions: [TransactionDTO]
        let expected: Expected
    }

    static let queries = [
        DecisionState(merchant: "Automercado Escazú", card: "BAC Visa", amountMinor: 2_500_000, currency: "CRC"),
        DecisionState(merchant: "AUTOMERCADO ESCAZU", card: "BAC Visa", amountMinor: 900_000, currency: "CRC"),
        DecisionState(merchant: "Soda Tapia", card: "BAC Visa", amountMinor: 650_000, currency: "CRC"),
        DecisionState(merchant: "Uber", card: "BAC Visa", amountMinor: 420_000, currency: "CRC"),
        DecisionState(merchant: "Automercado Santa Ana", card: "BAC Visa", amountMinor: 3_000_000, currency: "CRC"),
        DecisionState(merchant: "Ferretería EPA", card: "BAC Visa", amountMinor: 1_800_000, currency: "CRC"),
    ]

    func load() throws -> Fixture {
        // ios/HarinaKit/Tests/HarinaKitTests/<this file> → repository root → tests/fixtures
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("tests/fixtures/insights.json")))
    }

    func testDecisionModelMatchesTheWeb() throws {
        let f = try load()
        let active = Set(f.transactions.compactMap(\.category_id))
        let cal = CategoryModel.calibrate(f.transactions, active: active)
        XCTAssertEqual(cal.threshold, f.expected.calibration.threshold)
        XCTAssertEqual(cal.cases, f.expected.calibration.cases)
        XCTAssertEqual(cal.accuracy ?? -1, f.expected.calibration.accuracy ?? -1, accuracy: 1e-6)
        XCTAssertEqual(cal.coverage, f.expected.calibration.coverage, accuracy: 1e-6)
        let model = CategoryModel.train(f.transactions, active: active)
        for (q, want) in zip(Self.queries, f.expected.predictions) {
            let d = model.decide(cal, q)
            XCTAssertEqual(d.band.rawValue, want.band, q.merchant ?? "")
            XCTAssertEqual(d.categoryId, want.categoryId, q.merchant ?? "")
            XCTAssertEqual(d.confidence, want.confidence, accuracy: 1e-6, q.merchant ?? "")
        }
    }

    func testRecurringAndProjectionMatchTheWeb() throws {
        let f = try load()
        let now = try XCTUnwrap(ISODate.date(f.now))
        let rec = Insights.recurring(f.transactions, now: now)
        XCTAssertEqual(rec.map(\.key), f.expected.recurring.map(\.key))
        for (r, w) in zip(rec, f.expected.recurring) {
            XCTAssertEqual(r.cadence.rawValue, w.cadence, w.key)
            XCTAssertEqual(r.period, w.period, w.key)
            XCTAssertEqual(r.count, w.count, w.key)
            XCTAssertEqual(r.sure ? "sure" : "likely", w.confidence, w.key)
            XCTAssertEqual(r.next, w.next, w.key)
            XCTAssertEqual(r.status.rawValue, w.status, w.key)
            XCTAssertEqual(r.priceChange, w.priceChange.map { PriceChange(from: $0.from, to: $0.to) }, w.key)
            XCTAssertEqual(r.amount, w.amount, w.key)
            XCTAssertEqual(r.monthly, w.monthly, w.key)
            XCTAssertEqual(r.daysToNext, w.daysToNext, w.key)
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        for cur in ["CRC", "USD"] {
            let p = Insights.projectMonth(f.transactions, recurring: rec, currency: cur, now: now, calendar: utc)
            let w = f.expected.projection[cur] ?? nil
            XCTAssertEqual(p?.spent, w?.spent, cur)
            XCTAssertEqual(p?.fixedRemaining, w?.fixedRemaining, cur)
            XCTAssertEqual(p?.dailyVariable, w?.dailyVariable, cur)
            XCTAssertEqual(p?.projected, w?.projected, cur)
        }
    }

    func testPriceChange() {
        XCTAssertEqual(Insights.priceChange([699, 699, 699, 799]), PriceChange(from: 699, to: 799))
        XCTAssertNil(Insights.priceChange([699, 799, 799, 799]))
        XCTAssertNil(Insights.priceChange([2600, 2800, 2700, 2900]))
    }
}

final class NotificationIdsTests: XCTestCase {
    func testRoundTrip() {
        XCTAssertEqual(NotificationIds.category(for: ["a", "b", "c", "d"]), "pick.a|b|c")
        XCTAssertEqual(NotificationIds.categoryId(fromAction: NotificationIds.action(for: "default-food")), "default-food")
        XCTAssertNil(NotificationIds.categoryId(fromAction: NotificationIds.other))
        XCTAssertNil(NotificationIds.categoryId(fromAction: "com.apple.UNNotificationDefaultActionIdentifier"))
        XCTAssertNil(NotificationIds.categoryId(fromAction: "cat:"))
        XCTAssertEqual(NotificationIds.trimmed((1...40).map(String.init)).count, 30)
        XCTAssertEqual(NotificationIds.trimmed((1...40).map(String.init)).first, "11")
    }
}

final class MoneyToolsTests: XCTestCase {
    var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    func tx(_ id: String, _ kind: String = "expense", _ amount: Int64, cat: String? = nil, cur: String = "CRC",
            at: String = "2026-11-10T12:00:00Z", pot: String? = nil, deleted: Int = 0) -> TransactionDTO {
        TransactionDTO(id: id, kind: kind, amount_minor: amount, currency: cur, category_id: cat, source: "manual",
                       occurred_at: at, updated_at: 1, deleted: deleted, pot_id: pot)
    }

    func testEnvelope() {
        let txs = [
            tx("1", "expense", 8000, cat: "a", at: "2026-11-02T12:00:00Z"),
            tx("2", "expense", 9000, cat: "b", at: "2026-11-20T12:00:00Z"),
            tx("3", "expense", 5000, cat: "a", at: "2026-10-30T12:00:00Z"),
            tx("4", "expense", 5000, cat: "a", cur: "USD", at: "2026-11-05T12:00:00Z"),
            tx("5", "expense", 5000, cat: "c", at: "2026-11-05T12:00:00Z"),
            tx("6", "income", 5000, cat: "a", at: "2026-11-05T12:00:00Z"),
        ]
        let b = BudgetDTO(id: "b", name: "Mesada", amount_minor: 20000, currency: "CRC", category_ids: ["a", "b"], updated_at: 1)
        let s = MoneyTools.budget(b, txs, month: "2026-11", calendar: utc)
        XCTAssertEqual(s.spent, 17000)
        XCTAssertEqual(s.left, 3000)
        XCTAssertEqual(s.level, .warn)
        var small = b
        small.amount_minor = 10000
        XCTAssertEqual(MoneyTools.budget(small, txs, month: "2026-11", calendar: utc).level, .over)
    }

    func testPot() {
        let txs = [
            tx("1", "saving", 1000, pot: "p"), tx("2", "saving", 500, pot: "p"), tx("3", "withdrawal", 200, pot: "p"),
            tx("4", "expense", 300, pot: "p"), tx("5", "saving", 9999, pot: "other"), tx("6", "saving", 7777, pot: "p", deleted: 1),
        ]
        let s = MoneyTools.pot(PotDTO(id: "p", name: "E", currency: "CRC", goal_minor: 2000, updated_at: 1), txs)
        XCTAssertEqual(s, MoneyTools.PotState(balance: 1000, saved: 1500, goal: 2000, progress: 0.5))
    }

    func testReminder() {
        func at(_ s: String) -> Date { ISODate.date(s)! }
        let r31 = ReminderDTO(id: "r", name: "x", day_of_month: 31, updated_at: 1)
        let a = MoneyTools.reminder(r31, now: at("2026-11-10T12:00:00Z"), calendar: utc)
        XCTAssertEqual(MoneyTools.month(a.due, calendar: utc), "2026-11")
        XCTAssertEqual(utc.component(.day, from: a.due), 30)
        XCTAssertEqual(a.days, 20)
        XCTAssertEqual(a.status, .upcoming)
        let r15 = ReminderDTO(id: "r", name: "x", day_of_month: 15, updated_at: 1)
        XCTAssertEqual(MoneyTools.reminder(r15, now: at("2026-11-14T12:00:00Z"), calendar: utc).status, .soon)
        XCTAssertEqual(MoneyTools.reminder(r15, now: at("2026-11-15T09:00:00Z"), calendar: utc).status, .today)
        let r5 = ReminderDTO(id: "r", name: "x", day_of_month: 5, updated_at: 1)
        XCTAssertEqual(MoneyTools.reminder(r5, now: at("2026-11-10T12:00:00Z"), calendar: utc).status, .late)
        var paid = r5
        paid.paid_month = "2026-11"
        let p = MoneyTools.reminder(paid, now: at("2026-11-10T12:00:00Z"), calendar: utc)
        XCTAssertEqual(p.status, .paid)
        XCTAssertEqual(p.days, 25)
    }
}
