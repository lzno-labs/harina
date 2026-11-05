// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Suggested categories, with the same keys and ids (`default-<key>`) as the web and the server,
/// so a phone that starts offline and a server that seeded the defaults converge by id.
public struct SuggestedCategory: Equatable, Sendable {
    public let key: String
    public let glyph: String
    public let from: UInt32
    public let to: UInt32
    /// On by default (the seven PRD categories); the rest are suggestions to add.
    public let on: Bool
    public var id: String { "default-\(key)" }
}

public enum CategoryCatalog {
    public static let all: [SuggestedCategory] = [
        .init(key: "food", glyph: "🍽️", from: 0xFF8A4C, to: 0xFF5F6D, on: true),
        .init(key: "groceries", glyph: "🛒", from: 0x22C58B, to: 0x0EA5A4, on: true),
        .init(key: "transport", glyph: "🚗", from: 0x4C8DFF, to: 0x6A5CFF, on: true),
        .init(key: "home", glyph: "🏠", from: 0xA77BFF, to: 0xD061FF, on: true),
        .init(key: "health", glyph: "💊", from: 0xFF5C8A, to: 0xFF3F5F, on: true),
        .init(key: "entertainment", glyph: "🎬", from: 0xFFC23D, to: 0xFF8F3D, on: true),
        .init(key: "other", glyph: "📦", from: 0x8E97A8, to: 0x5F6779, on: true),
        .init(key: "coffee", glyph: "☕", from: 0xC08457, to: 0x8A5A3B, on: false),
        .init(key: "utilities", glyph: "💡", from: 0xFACC15, to: 0xF59E0B, on: false),
        .init(key: "subscriptions", glyph: "🔁", from: 0x38BDF8, to: 0x6366F1, on: false),
        .init(key: "clothing", glyph: "👕", from: 0xF472B6, to: 0xDB2777, on: false),
        .init(key: "pets", glyph: "🐶", from: 0xFB923C, to: 0xEA580C, on: false),
        .init(key: "education", glyph: "📚", from: 0x60A5FA, to: 0x2563EB, on: false),
        .init(key: "travel", glyph: "✈️", from: 0x22D3EE, to: 0x0891B2, on: false),
        .init(key: "gifts", glyph: "🎁", from: 0xF87171, to: 0xDC2626, on: false),
        .init(key: "personal", glyph: "💇", from: 0xE879F9, to: 0xA855F7, on: false),
        .init(key: "kids", glyph: "🧸", from: 0xFBBF24, to: 0xD97706, on: false),
        .init(key: "sports", glyph: "🏋️", from: 0x4ADE80, to: 0x16A34A, on: false),
        .init(key: "salary", glyph: "💼", from: 0x34D399, to: 0x059669, on: false),
    ]

    public static func suggestion(_ key: String?) -> SuggestedCategory? { all.first { $0.key == key } }

    /// Colors offered in the category editor, as stored (`#rrggbb`, same list as the web).
    public static let colors = ["#ff5f6d", "#ff8a4c", "#f59e0b", "#eab308", "#22c58b", "#14b8a6",
                                "#0ea5e9", "#4c8dff", "#6366f1", "#a855f7", "#ec4899", "#8e97a8"]

    public static let emojis = ["🍽️", "🛒", "🚗", "🏠", "💊", "🎬", "📦", "☕", "🍔", "🍕", "🍺", "⛽", "🚌", "🅿️", "💡", "📱",
                                "🔁", "👕", "👟", "🐶", "📚", "✈️", "🏖️", "🎁", "💇", "🧸", "🏋️", "⚽", "🎮", "🎵", "💻", "🔧",
                                "🏥", "🦷", "💼", "💰", "🏦", "❤️", "⛪", "🌱"]

    /// Parses `#rrggbb` into a 24-bit value.
    public static func hex(_ text: String?) -> UInt32? {
        guard let text, text.count == 7, text.first == "#", let v = UInt32(text.dropFirst(), radix: 16) else { return nil }
        return v
    }

    /// A darker shade for the second gradient stop.
    public static func shade(_ c: UInt32, _ f: Double = 0.72) -> UInt32 {
        let r = UInt32(Double((c >> 16) & 0xFF) * f), g = UInt32(Double((c >> 8) & 0xFF) * f), b = UInt32(Double(c & 0xFF) * f)
        return (r << 16) | (g << 8) | b
    }

    /// First grapheme of what the person typed, so one emoji (with skin tone or flags) is kept whole.
    public static func firstEmoji(_ text: String) -> String? {
        text.trimmingCharacters(in: .whitespaces).first.map(String.init)
    }
}

/// A `harina://link?server=…&code=…` URL from the web's QR code.
public struct LinkRequest: Equatable, Sendable, Identifiable {
    public var id: String { code }
    public let server: URL
    public let code: String

    /// Accepts only https servers (or localhost for development) and a plausible code.
    /// The app still asks the person to confirm the server before linking.
    public static func parse(_ url: URL) -> LinkRequest? {
        guard url.scheme == "harina", url.host == "link",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let serverText = items.first(where: { $0.name == "server" })?.value,
              let code = items.first(where: { $0.name == "code" })?.value,
              let server = URL(string: serverText), let host = server.host, !host.isEmpty
        else { return nil }
        let secure = server.scheme == "https" || (server.scheme == "http" && (host == "localhost" || host == "127.0.0.1"))
        let cleanCode = code.uppercased().filter { $0.isLetter || $0.isNumber }
        guard secure, server.user == nil, server.password == nil, (6...16).contains(cleanCode.count) else { return nil }
        return LinkRequest(server: server, code: code)
    }
}
