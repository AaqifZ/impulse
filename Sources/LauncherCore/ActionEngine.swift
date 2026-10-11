import Foundation

public struct ActionEngine: Sendable {
    public let config: LauncherConfig
    /// Recent use per action ID (see `UsageRanking`). Among matches of the same strength, more use ranks first.
    public var usage: [String: Double] = [:]
    private let now: @Sendable () -> Date
    private let timeZone: TimeZone

    public init(
        config: LauncherConfig,
        now: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .current
    ) {
        self.config = config
        self.now = now
        self.timeZone = timeZone
    }

    /// Typed web addresses open in the browser of the `g` search action, or the default browser.
    var directURLBrowser: String? {
        config.actions.first { $0.kind == .url && $0.hasAlias("g") }?.browser
    }

    public func search(_ input: String) -> [LauncherAction] {
        let query = LauncherText.normalizeWords(input)
        guard !query.isEmpty else { return config.actions }

        var scored: [(score: Int, index: Int, action: LauncherAction)] = []
        for (index, action) in config.actions.enumerated() {
            if let actionScore = score(action, for: query) {
                scored.append((score: actionScore, index: index, action: action))
            }
        }
        var results = scored.sorted { lhs, rhs in
            let lhsTier = Self.tier(lhs.score), rhsTier = Self.tier(rhs.score)
            if lhsTier != rhsTier { return lhsTier < rhsTier }
            let lhsUse = usage[lhs.action.id] ?? 0, rhsUse = usage[rhs.action.id] ?? 0
            if lhsUse != rhsUse { return lhsUse > rhsUse }
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            // App prefixes should prefer the main app over longer installer/helper names.
            if lhs.score >= 10 {
                let leftIsApp = lhs.action.kind.isApp
                let rightIsApp = rhs.action.kind.isApp
                if leftIsApp != rightIsApp { return leftIsApp }
                if leftIsApp && lhs.action.name.count != rhs.action.name.count {
                    return lhs.action.name.count < rhs.action.name.count
                }
            }
            return lhs.index < rhs.index
        }
        .map(\.action)
        let hasExactAlias = config.actions.contains { action in
            action.aliases.contains { LauncherText.normalizeWords($0) == query }
        }
        if !hasExactAlias, let direct = DirectURL.action(for: input, browser: directURLBrowser) {
            results.insert(direct, at: 0)
        }
        return results
    }

    public func resolve(_ input: String) throws -> ResolvedAction {
        let inputWords = LauncherText.words(input)
        guard !inputWords.isEmpty else { throw LauncherError.noMatch(input) }
        let normalizedWords = inputWords.map { LauncherText.normalize(String($0)) }

        var candidates: [(wordCount: Int, aliasLength: Int, index: Int, action: LauncherAction)] = []
        for (index, action) in config.actions.enumerated() {
            for alias in action.aliases {
                let aliasWords = LauncherText.words(alias).map { LauncherText.normalize(String($0)) }
                guard aliasWords.count <= normalizedWords.count,
                      Array(normalizedWords.prefix(aliasWords.count)) == aliasWords else { continue }
                candidates.append((aliasWords.count, alias.count, index, action))
            }
        }

        if let selected = candidates.sorted(by: {
            if $0.wordCount != $1.wordCount { return $0.wordCount > $1.wordCount }
            if $0.aliasLength != $1.aliasLength { return $0.aliasLength > $1.aliasLength }
            return $0.index < $1.index
        }).first {
            let query = inputWords.dropFirst(selected.wordCount).joined(separator: " ")
            return try resolve(action: selected.action, query: query)
        }

        let whole = LauncherText.normalizeWords(input)
        if let action = config.actions.first(where: {
            LauncherText.normalizeWords($0.id) == whole || LauncherText.normalizeWords($0.name) == whole
        }) {
            return try resolve(action: action, query: "")
        }
        if let direct = DirectURL.action(for: input, browser: directURLBrowser) {
            return ResolvedAction(
                actionID: direct.id,
                kind: direct.kind,
                value: direct.target,
                browser: direct.browser
            )
        }
        throw LauncherError.noMatch(input)
    }

    public func resolve(action: LauncherAction, query: String) throws -> ResolvedAction {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let canonicalAction = config.actions.first(where: { $0.id == action.id }) {
            return try resolveCanonical(action: canonicalAction, query: trimmedQuery)
        }
        if action.id == DirectURL.actionID,
           trimmedQuery.isEmpty,
           let direct = DirectURL.action(for: action.target, browser: directURLBrowser) {
            return ResolvedAction(
                actionID: direct.id,
                kind: direct.kind,
                value: direct.target,
                browser: direct.browser
            )
        }
        throw LauncherError.noMatch(action.id)
    }

    public func resolveQueryMode(action: LauncherAction, query: String) throws -> ResolvedAction {
        return try resolve(action: action, query: query)
    }

    private func resolveCanonical(action: LauncherAction, query trimmedQuery: String) throws -> ResolvedAction {
        switch action.kind {
        case .url:
            let needsQuery = action.target.contains("{query}")
            if needsQuery && trimmedQuery.isEmpty {
                guard let homepage = action.emptyQueryTarget else { throw LauncherError.missingQuery(action.id) }
                return ResolvedAction(actionID: action.id, kind: action.kind, value: homepage, browser: action.browser)
            }
            if !needsQuery && !trimmedQuery.isEmpty { throw LauncherError.unexpectedQuery(action.id) }
            let value = needsQuery
                ? action.target.replacingOccurrences(of: "{query}", with: Self.percentEncode(trimmedQuery))
                : action.target
            return ResolvedAction(actionID: action.id, kind: action.kind, value: value, browser: action.browser)
        case .app, .terminal, .workspace:
            if !trimmedQuery.isEmpty { throw LauncherError.unexpectedQuery(action.id) }
            return ResolvedAction(actionID: action.id, kind: action.kind, value: action.target)
        case .application, .file, .shortcut, .system:
            // Runtime providers only; persistent configuration validation rejects these kinds.
            if !trimmedQuery.isEmpty { throw LauncherError.unexpectedQuery(action.id) }
            return ResolvedAction(actionID: action.id, kind: action.kind, value: action.target)
        case .snippet:
            if !trimmedQuery.isEmpty { throw LauncherError.unexpectedQuery(action.id) }
            let result = try SnippetRenderer.render(action.target, now: now(), timeZone: timeZone)
            return ResolvedAction(
                actionID: action.id,
                kind: action.kind,
                value: result.value,
                cursorOffset: result.cursorOffset
            )
        case .webSearch, .laptopSearch, .emoji, .calculation, .error, .clipboard, .dictation, .local, .theme, .accent, .stats:
            throw LauncherError.unsupportedKind(action.kind.rawValue)
        }
    }

    private func score(_ action: LauncherAction, for query: String) -> Int? {
        let aliases = action.aliases.map(LauncherText.normalizeWords)
        let name = LauncherText.normalizeWords(action.name)
        if aliases.contains(query) { return 0 }
        if name == query { return 1 }
        let queryWords = LauncherText.words(query).map(String.init)
        let inlineAliasLengths = aliases.compactMap { alias -> Int? in
            let aliasWords = LauncherText.words(alias).map(String.init)
            guard aliasWords.count < queryWords.count,
                  Array(queryWords.prefix(aliasWords.count)) == aliasWords else { return nil }
            return aliasWords.count
        }
        if let longest = inlineAliasLengths.max() { return 5 - min(4, longest) }
        if aliases.contains(where: { $0.hasPrefix(query) }) { return 10 }
        if name.hasPrefix(query) { return 20 }
        // "whats app" finds WhatsApp.
        let compactQuery = query.filter { !$0.isWhitespace }
        if ([name] + aliases).contains(where: { $0.filter { !$0.isWhitespace }.hasPrefix(compactQuery) }) { return 25 }
        if aliases.contains(where: { $0.contains(query) }) { return 30 }
        if name.contains(query) { return 40 }
        let terms = queryWords
        let haystacks = [name] + aliases
        if haystacks.contains(where: { Self.containsInOrder(terms, in: $0) }) { return 50 }
        if haystacks.contains(where: { Self.isSubsequence(query, of: $0) }) { return 60 }
        return nil
    }

    /// Exact matches keep their order. Prefix matches form one tier and contains matches another,
    /// so use decides inside each: "c" puts a much-used ChatGPT above a never-used Chess.
    private static func tier(_ score: Int) -> Int {
        switch score {
        case 10...25: return 10
        case 30...40: return 30
        default: return score
        }
    }

    private static func containsInOrder(_ terms: [String], in text: String) -> Bool {
        var remaining = text[...]
        for term in terms {
            guard let range = remaining.range(of: term) else { return false }
            remaining = remaining[range.upperBound...]
        }
        return true
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var iterator = haystack.makeIterator()
        for character in needle where !character.isWhitespace {
            var found = false
            while let candidate = iterator.next() {
                if character == candidate {
                    found = true
                    break
                }
            }
            if !found { return false }
        }
        return true
    }

    public static func percentEncode(_ query: String) -> String {
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
        return query.utf8.map { byte in
            unreserved.contains(byte) ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }.joined()
    }
}
