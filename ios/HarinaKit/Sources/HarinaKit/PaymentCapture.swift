// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Turns what the Shortcuts "Transaction" automation passes into a movement to store
/// (docs/design/apple-pay-capture.md). Never throws: a payment is never lost, at worst it is
/// saved for review with the raw text.
public enum PaymentCapture {
    public static let maxText = 200

    public static func movement(
        id: String = UUID().uuidString,
        merchant: String?,
        amountText: String,
        card: String?,
        accountId: String?,
        defaultCurrency: String,
        at date: Date = Date(),
        updatedAt: Int64 = SyncRules.now()
    ) -> TransactionDTO {
        let clean = { (s: String?) -> String? in
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return String(t.prefix(maxText))
        }
        let raw = String(amountText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        let parsed = AmountParser.parse(raw, defaultCurrency: defaultCurrency)
        let currency = parsed?.currency ?? defaultCurrency
        // Review when the amount could not be read, or its currency had to be guessed.
        let review = parsed == nil || parsed?.currency == nil
        return TransactionDTO(
            id: id,
            kind: "expense",
            amount_minor: parsed?.minor ?? 0,
            currency: currency,
            account_id: accountId,
            merchant: clean(merchant),
            card: clean(card).map { String($0.prefix(100)) },
            source: "apple_pay",
            raw_amount: raw.isEmpty ? nil : raw,
            needs_review: review ? 1 : 0,
            occurred_at: ISODate.string(date),
            updated_at: updatedAt
        )
    }
}

/// CSV export with the same columns as the server; headers come from the app's strings.
public enum CSVExport {
    public static func cell(_ value: String?) -> String {
        var s = value ?? ""
        if let first = s.first, "=+-@\t\r".contains(first) { s = "'" + s }
        if s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            s = "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    /// - Parameters:
    ///   - headers: 12 localized column names (date, kind, amount, currency, category, account,
    ///     merchant, note, card, source, needs_review, id)
    ///   - label: localized label for a kind or source value
    public static func make(
        _ txs: [TransactionDTO], headers: [String], categoryName: (String?) -> String,
        accountName: (String?) -> String, label: (String) -> String
    ) -> String {
        var lines = [headers.map(cell).joined(separator: ",")]
        for t in txs where (t.deleted ?? 0) == 0 {
            lines.append([
                t.occurred_at, label(t.kind), Money.plain(minor: t.amount_minor, currency: t.currency), t.currency,
                categoryName(t.category_id), accountName(t.account_id), t.merchant, t.note, t.card, label(t.source),
                String(t.needs_review ?? 0), t.id,
            ].map(cell).joined(separator: ","))
        }
        return "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n"
    }
}
