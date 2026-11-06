// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Identifiers for the "pick a category" notification (docs/design/siri-y-notificaciones.md).
public enum NotificationIds {
    public static let categoryPrefix = "pick."
    public static let actionPrefix = "cat:"
    public static let other = "other"
    public static let review = "review"
    public static let movementKey = "movementId"
    public static let maxButtons = 3

    /// One notification category per combination of up to three category ids, since action titles
    /// are fixed when a category is registered.
    public static func category(for categoryIds: [String]) -> String {
        categoryPrefix + categoryIds.prefix(maxButtons).joined(separator: "|")
    }

    public static func action(for categoryId: String) -> String { actionPrefix + categoryId }

    /// The category id behind an action identifier, or nil for "other", the default tap and dismissals.
    public static func categoryId(fromAction action: String) -> String? {
        guard action.hasPrefix(actionPrefix) else { return nil }
        let id = String(action.dropFirst(actionPrefix.count))
        return id.isEmpty ? nil : id
    }

    /// Keeps the most recently used notification categories (newest last), at most `limit`.
    public static func trimmed(_ identifiers: [String], keeping limit: Int = 30) -> [String] {
        Array(identifiers.suffix(limit))
    }
}
