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
