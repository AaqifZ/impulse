import Foundation

/// One emoji with the words that find it. The data is bundled; nothing is fetched.
public struct Emoji: Equatable, Sendable {
    public let symbol: String
    public let name: String
    public let group: String
    public let keywords: [String]
    public let supportsSkinTones: Bool
}

public enum EmojiCatalog {
    /// Every emoji in Unicode order, parsed once.
    public static let all: [Emoji] = EmojiData.raw.split(separator: "\n").compactMap { line in
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 5, let group = Int(fields[1]), EmojiData.groups.indices.contains(group) else { return nil }
        return Emoji(symbol: fields[0], name: fields[3], group: EmojiData.groups[group],
                     keywords: fields[4].split(separator: "|").map(String.init), supportsSkinTones: fields[2] == "1")
    }
    public static let groups = EmojiData.groups

    /// Words split once, for search: the name's words and the keywords' words.
    private static let index: [(name: String, nameWords: [String], words: Set<String>, keywords: Set<String>)] = all.map { emoji in
        let name = emoji.name.lowercased()
        let nameWords = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let keywordWords = emoji.keywords.flatMap { $0.split(separator: " ").map(String.init) }
        return (name, nameWords, Set(nameWords + keywordWords), Set(emoji.keywords))
    }

    /// Best first: the exact name, then a whole name word or keyword ("lol" finds 😂 before 🍭),
    /// then a name that starts with the query, then a name word that starts with it, then every query
    /// word starting some word, then the name containing the query.
    /// More use ranks first inside each step; Unicode order breaks the remaining ties.
    public static func search(_ query: String, usage: [String: Double] = [:], limit: Int = 400) -> [Emoji] {
        let text = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return all }
        let terms = text.split(separator: " ").map(String.init)
        var scored: [(tier: Int, use: Double, index: Int)] = []
        for (position, entry) in index.enumerated() {
            let tier: Int
            if entry.name == text { tier = 0 }
            else if entry.nameWords.contains(text) || entry.keywords.contains(text) { tier = 1 }
            else if entry.name.hasPrefix(text) { tier = 2 }
            else if terms.count == 1 && entry.nameWords.contains(where: { $0.hasPrefix(text) }) { tier = 3 }
            else if terms.allSatisfy({ term in entry.words.contains { $0.hasPrefix(term) } }) { tier = 4 }
            else if entry.name.contains(text) { tier = 5 }
            else { continue }
            scored.append((tier, usage[all[position].symbol] ?? 0, position))
        }
        scored.sort { $0.tier != $1.tier ? $0.tier < $1.tier : ($0.use != $1.use ? $0.use > $1.use : $0.index < $1.index) }
        return scored.prefix(limit).map { all[$0.index] }
    }

    /// The most used emoji, most first. Each use counts like any action: 1 today, half a week later.
    /// An imported list adds a smaller weight that fades in rank order, so real use soon takes over.
    public static func frequent(usage: [String: Double], seed: [String] = [], limit: Int = 16) -> [Emoji] {
        let weights = combined(usage: usage, seed: seed)
        let bySymbol = Dictionary(all.map { ($0.symbol, $0) }, uniquingKeysWith: { first, _ in first })
        return weights.filter { $0.value > 0 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit).compactMap { bySymbol[$0.key] }
    }

    /// Use per symbol plus the imported seed: from 0.5 for the first seed emoji down toward 0.
    public static func combined(usage: [String: Double], seed: [String]) -> [String: Double] {
        var weights = usage
        for (rank, symbol) in seed.enumerated() {
            weights[symbol, default: 0] += 0.5 * Double(seed.count - rank) / Double(max(seed.count, 1))
        }
        return weights
    }

    /// The usage-log ID for an emoji pick.
    public static func usageID(_ symbol: String) -> String { "emoji." + symbol }

    /// Use per symbol, read from per-action weights (`UsageRanking`).
    public static func usage(from weights: [String: Double]) -> [String: Double] {
        var result: [String: Double] = [:]
        for (id, weight) in weights where id.hasPrefix("emoji.") { result[String(id.dropFirst(6))] = weight }
        return result
    }

    /// The imported list in config/emoji-seed.json: `{"symbols": [...]}`, most used first. Missing or bad gives none.
    public static func loadSeed(from url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let symbols = object["symbols"] as? [String] else { return [] }
        return symbols
    }
}
