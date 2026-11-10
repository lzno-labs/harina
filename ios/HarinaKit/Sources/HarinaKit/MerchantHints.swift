// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Well-known merchants in Costa Rica and the suggested category they usually belong to
/// (docs/design/apple-intelligence.md). Only used for a merchant the person never categorized:
/// once they pick a category for it, their history wins.
public enum MerchantHints {
    /// Normalized name fragments (whole words, in order) and the catalog keys to try, best first.
    /// More specific fragments go first ("uber eats" before "uber").
    static let table: [(fragment: String, keys: [String])] = [
        // Food delivery before rides.
        ("uber eats", ["food"]), ("rappi", ["food"]), ("pedidosya", ["food"]), ("pedidos ya", ["food"]),
        // Groceries.
        ("automercado", ["groceries"]), ("auto mercado", ["groceries"]), ("mas x menos", ["groceries"]),
        ("masxmenos", ["groceries"]), ("walmart", ["groceries"]), ("maxi pali", ["groceries"]), ("maxipali", ["groceries"]),
        ("pali", ["groceries"]), ("megasuper", ["groceries"]), ("perimercados", ["groceries"]), ("fresh market", ["groceries"]),
        ("pricesmart", ["groceries"]), ("supercompro", ["groceries"]), ("super compro", ["groceries"]),
        ("ampm", ["groceries"]), ("am pm", ["groceries"]), ("vindi", ["groceries"]), ("supermercado", ["groceries"]),
        // Coffee, then food.
        ("starbucks", ["coffee", "food"]), ("britt", ["coffee", "food"]), ("juan valdez", ["coffee", "food"]),
        ("musmanni", ["food"]), ("mcdonalds", ["food"]), ("mc donalds", ["food"]), ("burger king", ["food"]),
        ("kfc", ["food"]), ("pizza hut", ["food"]), ("dominos", ["food"]), ("papa johns", ["food"]), ("subway", ["food"]),
        ("taco bell", ["food"]), ("wendys", ["food"]), ("rostipollos", ["food"]), ("pops", ["food"]), ("spoon", ["food"]),
        ("soda", ["food"]), ("panaderia", ["food"]), ("restaurante", ["food"]), ("pizzeria", ["food"]),
        // Transport.
        ("uber", ["transport"]), ("didi", ["transport"]), ("indriver", ["transport"]), ("servicentro", ["transport"]),
        ("gasolinera", ["transport"]), ("puma energy", ["transport"]), ("parqueo", ["transport"]), ("parking", ["transport"]),
        ("peaje", ["transport"]), ("globalvia", ["transport"]), ("quickpass", ["transport"]), ("quick pass", ["transport"]),
        // Health.
        ("farmacia", ["health"]), ("fischel", ["health"]), ("la bomba", ["health"]), ("sucre", ["health"]),
        ("hospital", ["health"]), ("clinica", ["health"]), ("laboratorio", ["health"]), ("labin", ["health"]),
        ("echandi", ["health"]), ("odontologia", ["health"]),
        // Subscriptions, then entertainment.
        ("netflix", ["subscriptions", "entertainment"]), ("spotify", ["subscriptions", "entertainment"]),
        ("disney", ["subscriptions", "entertainment"]), ("hbo", ["subscriptions", "entertainment"]),
        ("youtube", ["subscriptions", "entertainment"]), ("apple com bill", ["subscriptions", "entertainment"]),
        ("icloud", ["subscriptions", "entertainment"]), ("amazon prime", ["subscriptions", "entertainment"]),
        ("openai", ["subscriptions", "other"]), ("chatgpt", ["subscriptions", "other"]), ("anthropic", ["subscriptions", "other"]),
        // Entertainment.
        ("cinemark", ["entertainment"]), ("cinepolis", ["entertainment"]), ("nova cinemas", ["entertainment"]),
        ("ccm cinemas", ["entertainment"]), ("steam", ["entertainment"]), ("playstation", ["entertainment"]),
        ("xbox", ["entertainment"]), ("nintendo", ["entertainment"]),
        // Utilities, then home.
        ("kolbi", ["utilities", "home"]), ("cnfl", ["utilities", "home"]),
        ("aya", ["utilities", "home"]), ("liberty", ["utilities", "home"]), ("claro", ["utilities", "home"]),
        ("cabletica", ["utilities", "home"]), ("telecable", ["utilities", "home"]),
        // Home.
        ("epa", ["home"]), ("el lagar", ["home"]), ("construplaza", ["home"]), ("cemaco", ["home"]),
        ("el colono", ["home"]), ("ferreteria", ["home"]), ("ikea", ["home"]),
        // Others that are only used when the person turned the category on.
        ("veterinaria", ["pets"]), ("airbnb", ["travel"]), ("booking com", ["travel"]), ("expedia", ["travel"]),
        ("avianca", ["travel"]), ("copa airlines", ["travel"]), ("sansa", ["travel"]), ("hotel", ["travel"]),
        ("smart fit", ["sports"]), ("smartfit", ["sports"]), ("gimnasio", ["sports"]), ("barberia", ["personal"]),
        ("peluqueria", ["personal"]), ("libreria", ["education"]), ("coursera", ["education"]), ("udemy", ["education"]),
        ("zara", ["clothing"]), ("bershka", ["clothing"]), ("pull bear", ["clothing"]), ("adidas", ["clothing"]), ("nike", ["clothing"]),
    ]

    /// The first active suggested category id for this merchant, or nil.
    public static func categoryId(for merchant: String?, active: Set<String>) -> String? {
        let words = MerchantKey.normalize(merchant).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        for (fragment, keys) in table where contains(words, fragment.split(separator: " ").map(String.init)) {
            if let id = keys.map({ "default-\($0)" }).first(where: active.contains) { return id }
            return nil
        }
        return nil
    }

    static func contains(_ words: [String], _ part: [String]) -> Bool {
        guard !part.isEmpty, part.count <= words.count else { return false }
        for i in 0...(words.count - part.count) where Array(words[i..<(i + part.count)]) == part { return true }
        return false
    }
}

public enum DecisionSource: String, Sendable { case model, hint, ai }

extension CategoryModel {
    /// The local decision, plus the well-known merchant list for a merchant the person never categorized.
    /// A hint acts (assigns on its own); the person's own history always wins over it.
    public func decideWithHints(_ calibration: Calibration, _ s: DecisionState, active: Set<String>) -> Decision {
        var d = decide(calibration, s)
        guard d.band != .act, !predict(s).knownMerchant,
              let id = MerchantHints.categoryId(for: s.merchant, active: active) else { return d }
        d.band = .act
        d.categoryId = id
        d.source = .hint
        d.ranked = [(id: id, p: 1)] + d.ranked.filter { $0.id != id }
        return d
    }
}
