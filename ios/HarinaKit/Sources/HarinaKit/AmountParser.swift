// SPDX-License-Identifier: MPL-2.0
import Foundation

/// An amount read from text, in the currency's minor unit (cents for CRC and USD).
public struct ParsedAmount: Equatable, Sendable {
    public var minor: Int64
    /// ISO 4217 code found in the text, or nil when the text had no currency sign or code.
    public var currency: String?
}

public enum Money {
    static let zeroDecimal: Set<String> = ["JPY", "KRW", "CLP", "PYG"]
    public static func minorUnits(_ currency: String) -> Int { zeroDecimal.contains(currency) ? 0 : 2 }

    public static func decimal(minor: Int64, currency: String) -> Decimal {
        var d = Decimal(minor)
        for _ in 0..<minorUnits(currency) { d /= 10 }
        return d
    }

    /// "4500.50" style text with a dot, for exports.
    public static func plain(minor: Int64, currency: String) -> String {
        let d = minorUnits(currency)
        guard d > 0 else { return String(minor) }
        var s = String(minor)
        while s.count <= d { s = "0" + s }
        let cut = s.index(s.endIndex, offsetBy: -d)
        return "\(s[..<cut]).\(s[cut...])"
    }
}

public enum AmountParser {
    /// Currency signs and codes as they appear in Wallet and Shortcuts, longest first.
    static let markers: [(String, String)] = [
        ("US$", "USD"), ("USD", "USD"), ("CRC", "CRC"), ("₡", "CRC"), ("EUR", "EUR"), ("€", "EUR"),
        ("MXN", "MXN"), ("COP", "COP"), ("$", "USD"),
    ]

    public static func detectCurrency(_ text: String) -> String? {
        let upper = text.uppercased()
        return markers.first { upper.contains($0.0) }?.1
    }

    /// Parses "₡4 500,00", "CRC 4,500.00", "$12.50", "12,50 US$" or "4500".
    /// The last "," or "." followed by one or two digits is the decimal mark; others group thousands.
    public static func parse(_ text: String, defaultCurrency: String = "CRC") -> ParsedAmount? {
        let currency = detectCurrency(text)
        let kept = text.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) && $0.isASCII || $0 == "," || $0 == "." || $0 == "-" }
        let s = String(String.UnicodeScalarView(kept))
        guard !s.isEmpty, !s.contains("-"), s.contains(where: \.isNumber) else { return nil }
        var whole = s
        var frac = ""
        if let mark = s.lastIndex(where: { $0 == "," || $0 == "." }) {
            let after = s[s.index(after: mark)...]
            if (1...2).contains(after.count), after.allSatisfy(\.isNumber) {
                whole = String(s[..<mark])
                frac = String(after)
            }
        }
        whole.removeAll { $0 == "," || $0 == "." }
        guard whole.allSatisfy(\.isNumber), !(whole.isEmpty && frac.isEmpty) else { return nil }
        let digits = Money.minorUnits(currency ?? defaultCurrency)
        frac = String((frac + String(repeating: "0", count: digits)).prefix(digits))
        guard let minor = Int64((whole.isEmpty ? "0" : whole) + frac) else { return nil }
        return ParsedAmount(minor: minor, currency: currency)
    }
}
