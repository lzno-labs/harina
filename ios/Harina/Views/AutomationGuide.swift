// SPDX-License-Identifier: MPL-2.0
import Foundation
import UIKit

/// How the Apple Pay automation is set up (docs/design/apple-pay-capture.md).
/// A build can ship a ready-made shortcut (`HARINA_SHORTCUT_URL`, an iCloud link): then the person
/// adds it with one tap instead of wiring Amount, Merchant and Card by hand. On iOS 27 the shared
/// shortcut also carries its Wallet "Transaction" automation, so only the cards are left to pick.
enum AutomationGuide {
    static var shortcutURL: URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "HarinaShortcutURL") as? String,
              text.hasPrefix("https://www.icloud.com/shortcuts/") else { return nil }
        return URL(string: text)
    }

    /// Localization keys of the steps to show, from the easiest path available on this iPhone.
    static func stepKeys(short: Bool) -> [String] {
        guard shortcutURL != nil else {
            return (1...6).map { "automation.step\($0)" + (short ? ".short" : "") }
        }
        if #available(iOS 27, *) {
            return (1...3).map { "automation.link27.step\($0)" }
        }
        return (1...3).map { "automation.link.step\($0)" }
    }

    /// Opens the ready-made shortcut when there is one, the Shortcuts app otherwise.
    @MainActor
    static func open() {
        if let url = shortcutURL ?? URL(string: "shortcuts://") { UIApplication.shared.open(url) }
    }
}
