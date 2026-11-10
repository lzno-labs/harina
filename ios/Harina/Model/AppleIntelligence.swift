// SPDX-License-Identifier: MPL-2.0
import Foundation
import HarinaKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Intelligence on the iPhone (Foundation Models framework), only for payments the person's
/// history does not cover (docs/design/apple-intelligence.md).
/// Runs on the device: nothing leaves the phone. Without Apple Intelligence it simply returns nil.
enum AppleIntelligence {
    enum Status { case available, notEligible, turnedOff, notReady, unsupportedOS }

    static var status: Status {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return .notEligible
                case .appleIntelligenceNotEnabled: return .turnedOff
                default: return .notReady
                }
            }
        }
        #endif
        return .unsupportedOS
    }

    struct Guess: Sendable {
        var name: String
        var sure: Bool
    }

    /// Most seconds a payment waits for an answer before it is saved the usual way.
    static let timeout: Double = 8

    /// The category Apple Intelligence picks for a payment, by name from the person's own list, or nil.
    @MainActor
    static func guess(merchant: String?, amount: String, categories: [CategoryItem],
                      examples: [(merchant: String, category: String)]) async -> (id: String, sure: Bool)? {
        let merchant = (merchant ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !merchant.isEmpty, categories.count >= 2, status == .available else { return nil }
        let names = categories.map(\.displayName)
        let prompt = Self.prompt(merchant: merchant, amount: amount, names: names, examples: examples)
        guard let g = await run(prompt) else { return nil }
        let key = MerchantKey.normalize(g.name)
        guard let c = categories.first(where: { MerchantKey.normalize($0.displayName) == key }) else { return nil }
        return (c.id, g.sure)
    }

    static let instructions = """
    You sort card payments made in Costa Rica into the person's own spending categories. \
    Answer with the exact name of one category from the list. If the merchant name is not enough \
    to know, answer "ninguna". Set sure to true only when the merchant clearly belongs to that category.
    """

    static func prompt(merchant: String, amount: String, names: [String],
                       examples: [(merchant: String, category: String)]) -> String {
        var text = "Categories:\n" + names.map { "- \($0)" }.joined(separator: "\n")
        if !examples.isEmpty {
            text += "\n\nEarlier payments of this person (merchant: category):\n"
                + examples.map { "\($0.merchant): \($0.category)" }.joined(separator: "\n")
        }
        text += "\n\nNew payment. Merchant: \"\(merchant)\". Amount: \(amount). Which category?"
        return text
    }

    private static func run(_ prompt: String) async -> Guess? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return await withTaskGroup(of: Guess?.self) { group in
                group.addTask {
                    let session = LanguageModelSession(instructions: instructions)
                    guard let r = try? await session.respond(to: prompt, generating: CategoryGuess.self,
                                                             options: GenerationOptions(sampling: .greedy)) else { return nil }
                    return Guess(name: r.content.category, sure: r.content.sure)
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct CategoryGuess {
    @Guide(description: "Exact name of one category from the list, or ninguna")
    var category: String
    @Guide(description: "true only when the merchant clearly belongs to that category")
    var sure: Bool
}
#endif
