// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Merge rules shared by every synced record (docs/adr/0002-sync.md).
public enum SyncRules {
    /// Whether a record from the server replaces the local copy.
    /// A local change that is not pushed yet and is newer than the server's wins; it will be pushed.
    public static func serverWins(localUpdatedAt: Int64?, localDirty: Bool, serverUpdatedAt: Int64) -> Bool {
        guard let local = localUpdatedAt else { return true }
        if localDirty && local > serverUpdatedAt { return false }
        return true
    }

    /// Milliseconds since 1970, the clock used for last-writer-wins.
    public static func now() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }
}

public enum MerchantKey {
    /// Same normalization as the server: case, accents and punctuation do not matter.
    public static func normalize(_ name: String?) -> String {
        guard let name else { return "" }
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var out = ""
        var space = false
        for ch in folded {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                if space && !out.isEmpty { out.append(" ") }
                out.append(ch)
                space = false
            } else {
                space = true
            }
        }
        return out
    }
}
