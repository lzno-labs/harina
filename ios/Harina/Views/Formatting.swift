// SPDX-License-Identifier: MPL-2.0
import Foundation
import HarinaKit

/// Money and dates follow the iPhone's region; words come from Localizable.strings.
enum Formatting {
    static func money(_ minor: Int64, _ currency: String) -> String {
        Money.decimal(minor: minor, currency: currency).formatted(.currency(code: currency))
    }

    static func day(_ date: Date) -> String { date.formatted(.dateTime.day().month(.abbreviated)) }

    static func month(_ date: Date) -> String { date.formatted(.dateTime.month(.wide).year()) }

    /// "noviembre"
    static func monthName(_ date: Date) -> String { date.formatted(.dateTime.month(.wide)) }

    /// "Nov 2026"
    static func shortMonth(_ date: Date) -> String {
        let s = date.formatted(.dateTime.month(.abbreviated)).replacingOccurrences(of: ".", with: "")
        return s.prefix(1).uppercased() + s.dropFirst() + " " + date.formatted(.dateTime.year())
    }

    /// "Hoy", "Ayer" or "lun 2 nov"
    static func dayHeader(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return L("month.today") }
        if cal.isDateInYesterday(date) { return L("month.yesterday") }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// Spending of a day per currency, for the day header.
    static func dayTotals(_ list: [Movement]) -> String {
        Dictionary(grouping: list.filter { $0.kind == "expense" }, by: \.currency)
            .sorted { $0.key < $1.key }
            .map { money($0.value.reduce(0) { $0 + $1.amountMinor }, $0.key) }
            .joined(separator: " · ")
    }

    static func editable(_ minor: Int64, _ currency: String) -> String {
        Money.decimal(minor: minor, currency: currency)
            .formatted(.number.precision(.fractionLength(Money.minorUnits(currency))).grouping(.never))
    }
}

/// Looks up a key built at run time (a literal key can use Text("key") directly).
func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }
