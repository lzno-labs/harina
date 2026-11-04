// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import UIKit

/// harina's visual language, shared with the web: warm brand gradient, colored category tiles.
enum Theme {
    static let brandColors = [Color(hex: 0xFF9A3C), Color(hex: 0xFF4F6D), Color(hex: 0x8B5CF6)]
    static let brand = LinearGradient(colors: brandColors, startPoint: .topLeading, endPoint: .bottomTrailing)
    static let brandHorizontal = LinearGradient(colors: brandColors, startPoint: .leading, endPoint: .trailing)
    static let spend = Color(hex: 0xFF5A73)
    static let earn = Color(hex: 0x1FCB8B)
    static let warn = Color(hex: 0xF59E0B)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let fill = Color(uiColor: .tertiarySystemFill)
    static let radius: CGFloat = 22
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

struct CategoryLook {
    let glyph: String
    let from: Color
    let to: Color
    var gradient: LinearGradient { LinearGradient(colors: [from, to], startPoint: .topLeading, endPoint: .bottomTrailing) }
}

enum Looks {
    static let defaults: [String: CategoryLook] = [
        "food": CategoryLook(glyph: "🍽️", from: Color(hex: 0xFF8A4C), to: Color(hex: 0xFF5F6D)),
        "groceries": CategoryLook(glyph: "🛒", from: Color(hex: 0x22C58B), to: Color(hex: 0x0EA5A4)),
        "transport": CategoryLook(glyph: "🚗", from: Color(hex: 0x4C8DFF), to: Color(hex: 0x6A5CFF)),
        "home": CategoryLook(glyph: "🏠", from: Color(hex: 0xA77BFF), to: Color(hex: 0xD061FF)),
        "health": CategoryLook(glyph: "💊", from: Color(hex: 0xFF5C8A), to: Color(hex: 0xFF3F5F)),
        "entertainment": CategoryLook(glyph: "🎬", from: Color(hex: 0xFFC23D), to: Color(hex: 0xFF8F3D)),
        "other": CategoryLook(glyph: "📦", from: Color(hex: 0x8E97A8), to: Color(hex: 0x5F6779)),
    ]
    static let palette: [(UInt32, UInt32)] = [
        (0x14B8A6, 0x0891B2), (0xF97316, 0xEF4444), (0x6366F1, 0xA855F7), (0xEC4899, 0xF43F5E),
        (0x84CC16, 0x16A34A), (0x0EA5E9, 0x2563EB), (0xEAB308, 0xF97316),
    ]
    static let none = CategoryLook(glyph: "?", from: Color(hex: 0x9AA1B4), to: Color(hex: 0x6B7389))
    static let income = CategoryLook(glyph: "↓", from: Color(hex: 0x34E0A1), to: Color(hex: 0x0FB57A))

    static func of(_ c: CategoryItem?) -> CategoryLook {
        guard let c else { return none }
        if let key = c.key, let l = defaults[key] { return l }
        var n: UInt32 = 0
        for u in c.id.unicodeScalars { n = n &* 31 &+ u.value }
        let (a, b) = palette[Int(n % UInt32(palette.count))]
        let first = c.displayName.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
        return CategoryLook(glyph: first, from: Color(hex: a), to: Color(hex: b))
    }
}

struct Tile: View {
    let look: CategoryLook
    var size: CGFloat = 42

    var body: some View {
        Text(verbatim: look.glyph)
            .font(.system(size: size * 0.46, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(look.gradient, in: RoundedRectangle(cornerRadius: size * 0.33, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct IconTile: View {
    let systemName: String
    let colors: [Color]
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}

extension View {
    func card() -> some View { modifier(CardStyle()) }
}

/// Primary call to action with the brand gradient.
struct BrandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Theme.brandHorizontal, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Color(hex: 0xFF4F6D).opacity(0.35), radius: 16, y: 8)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// Selectable capsule used for currencies, accounts and quick categories.
struct ChipStyle: ButtonStyle {
    var selected = false
    var highlighted = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .foregroundStyle(highlighted ? Color.white : selected ? Color(uiColor: .systemBackground) : Color.primary)
            .background {
                if highlighted {
                    Capsule().fill(Theme.brandHorizontal)
                } else if selected {
                    Capsule().fill(Color.primary)
                } else {
                    Capsule().fill(Theme.fill)
                }
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

enum Symbol {
    static let down = "arrow.down"
    static let up = "arrow.up"
}
