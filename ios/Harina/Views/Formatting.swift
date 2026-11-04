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

    static func editable(_ minor: Int64, _ currency: String) -> String {
        Money.decimal(minor: minor, currency: currency)
            .formatted(.number.precision(.fractionLength(Money.minorUnits(currency))).grouping(.never))
    }
}

/// Looks up a key built at run time (a literal key can use Text("key") directly).
func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }
