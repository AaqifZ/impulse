import Foundation

/// A short alias for an action you reach the long way.
/// It comes from key counts in the usage log, which never holds the typed text.
public struct AliasSuggestion: Equatable, Sendable {
    /// The action as the catalog holds it. A discovered app keeps its runtime ID.
    public let action: LauncherAction
    public let alias: String
    public let uses: Int
    public let keysPerUse: Double

    public var id: String { "runtime.suggest." + action.id }
    /// Keys the alias costs each time: the alias, plus ⇥ for a search.
    public var cost: Int { alias.count + (action.target.contains("{query}") ? 1 : 0) }
    public var keysSavedPerUse: Double { keysPerUse - Double(cost) }
    /// Keys the alias would have saved over the window.
    public var keysSaved: Int { Int((Double(uses) * keysSavedPerUse).rounded()) }
}

public enum AliasSuggester {
    /// Fewer uses than this is not a habit yet.
    public static let minimumUses = 5
    /// An alias must save at least a key each time, and this many keys over the window.
    public static let minimumKeysSaved = 20

    /// Up to `limit` suggestions, most keys saved first. Each alias is free: no other action,
    /// name or command word uses it.
    public static func suggest(
        _ events: [UsageEvent],
        catalog: [LauncherAction],
        now: Date = Date(),
        calendar: Calendar = .current,
        days: Int = 28,
        limit: Int = 3
    ) -> [AliasSuggestion] {
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }
        var uses: [String: (count: Int, keys: Int)] = [:]
        for event in events where event.ev == .action && event.t >= start && event.t <= now {
            guard let id = event.id, let keys = event.keys else { continue }
            uses[id, default: (0, 0)].count += 1
            uses[id, default: (0, 0)].keys += keys
        }
        let byID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var taken = QueryRouter.commandWords
        for action in catalog {
            taken.formUnion(action.aliases.map(LauncherText.normalizeWords))
            taken.insert(LauncherText.normalizeWords(action.name))
        }
        // Most typing first, so the busiest action gets the first pick of a free alias.
        let habits = uses.compactMap { id, use -> (LauncherAction, Int, Double)? in
            guard use.count >= minimumUses, let action = byID[id], isSuggestable(action) else { return nil }
            return (action, use.count, Double(use.keys) / Double(use.count))
        }
        .sorted { Double($0.1) * $0.2 != Double($1.1) * $1.2 ? Double($0.1) * $0.2 > Double($1.1) * $1.2 : $0.0.id < $1.0.id }

        var suggestions: [AliasSuggestion] = []
        for (action, count, keysPerUse) in habits {
            guard let alias = candidates(for: action).first(where: { !taken.contains($0) }) else { continue }
            let suggestion = AliasSuggestion(action: action, alias: alias, uses: count, keysPerUse: keysPerUse)
            guard suggestion.keysSavedPerUse >= 1, suggestion.keysSaved >= minimumKeysSaved else { continue }
            taken.insert(alias)
            suggestions.append(suggestion)
        }
        return Array(suggestions.sorted { $0.keysSaved != $1.keysSaved ? $0.keysSaved > $1.keysSaved : $0.action.id < $1.action.id }.prefix(limit))
    }

    /// Kinds whose typed keys name the destination. Search words, sums and file names are content, not habit.
    /// An action that already has a short alias is skipped: the alias is not the problem.
    static func isSuggestable(_ action: LauncherAction) -> Bool {
        switch action.kind {
        case .url, .app, .application, .terminal, .workspace, .snippet, .shortcut, .system: break
        case .file, .webSearch, .laptopSearch, .emoji, .calculation, .error, .clipboard, .dictation, .local, .theme, .accent, .stats: return false
        }
        return !action.aliases.contains { LauncherText.normalizeWords($0).count <= 2 }
    }

    /// Two letters first, from the name: its start, its initials, then its first letter with each later one.
    /// Three letters only when every two-letter choice is taken.
    public static func candidates(for action: LauncherAction) -> [String] {
        let name = DisplayFormat.cleanName(action.name, aliases: action.aliases)
        // "Today's Date" is two words, not three.
        let words = LauncherText.normalize(name).lowercased().filter { $0 != "'" && $0 != "’" }
            .split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
            .map(String.init)
        guard let first = words.first, let lead = first.first else { return [] }
        let initials = String(words.compactMap(\.first))
        var list: [String] = [String(first.prefix(2)), String(initials.prefix(2))]
        list += first.dropFirst().map { String(lead) + String($0) }
        list += words.dropFirst().flatMap { $0.map { String(lead) + String($0) } }
        list += [String(first.prefix(3)), String(initials.prefix(3))]
        var seen = Set<String>()
        return list.filter { $0.count >= 2 && Double($0) == nil && !commonWords.contains($0) && seen.insert($0).inserted }
    }

    /// Short English words. As an alias, one reads like prose and catches the start of ordinary phrases.
    static let commonWords: Set<String> = [
        "am", "an", "as", "at", "be", "by", "do", "go", "he", "hi", "if", "in", "is", "it", "me", "my",
        "no", "of", "ok", "on", "or", "so", "to", "up", "us", "we", "yo", "and", "the", "for", "you",
    ]
}

public extension LauncherAction {
    /// The config action for a discovered app: the same ID and name, opened by bundle ID.
    /// Nil for any other kind, or when the bundle has no ID.
    func configuredApp(alias: String) -> LauncherAction? {
        guard kind == .application, let bundleID = Bundle(path: target)?.bundleIdentifier else { return nil }
        return LauncherAction(id: id, name: name, aliases: [alias], kind: .app, target: bundleID)
    }
}

public extension LauncherConfig {
    /// Configured actions, then discovered ones. A configured action replaces a discovered one with its ID,
    /// so an app that gained an alias shows once and keeps its usage history.
    func catalog(adding discovered: [LauncherAction]) -> [LauncherAction] {
        let configured = Set(actions.map(\.id))
        return actions + discovered.filter { !configured.contains($0.id) }
    }

    /// Adds `alias` to the action with this ID. When no action has the ID, `fallback` is appended.
    func addingAlias(_ alias: String, to id: String, orAppending fallback: LauncherAction? = nil) throws -> LauncherConfig {
        if let index = actions.firstIndex(where: { $0.id == id }) {
            let old = actions[index]
            var updated = actions
            updated[index] = LauncherAction(
                id: old.id, name: old.name, aliases: old.aliases + [alias], kind: old.kind,
                target: old.target, browser: old.browser, emptyQueryTarget: old.emptyQueryTarget
            )
            return LauncherConfig(version: version, actions: updated)
        }
        guard let fallback, fallback.id == id else { throw LauncherError.invalidAction("\(id) is not in the configuration") }
        return LauncherConfig(version: version, actions: actions + [fallback])
    }

    /// The one file layout Impulse writes: two-space indent, keys in a fixed order, aliases on one line.
    /// The same config always gives the same bytes, so a change shows as a small diff.
    func canonicalJSON() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        func quoted(_ text: String) -> String {
            (try? encoder.encode(text)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        }
        let blocks = actions.map { action -> String in
            var lines = [
                "\"id\": \(quoted(action.id))",
                "\"name\": \(quoted(action.name))",
                "\"aliases\": [\(action.aliases.map(quoted).joined(separator: ", "))]",
                "\"kind\": \(quoted(action.kind.rawValue))",
                "\"target\": \(quoted(action.target))",
            ]
            if let browser = action.browser { lines.append("\"browser\": \(quoted(browser))") }
            if let fallback = action.emptyQueryTarget { lines.append("\"emptyQueryTarget\": \(quoted(fallback))") }
            return "    {\n" + lines.map { "      " + $0 }.joined(separator: ",\n") + "\n    }"
        }
        let list = blocks.isEmpty ? "[]" : "[\n" + blocks.joined(separator: ",\n") + "\n  ]"
        return Data("{\n  \"version\": \(version),\n  \"actions\": \(list)\n}\n".utf8)
    }
}
