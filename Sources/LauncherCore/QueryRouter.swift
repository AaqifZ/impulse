import Foundation

/// Decides what a typed query shows. It owns the action engine and has no UI state.
/// The app fills in the routes that need app services (clipboard, Shortcuts, theme).
public struct QueryRouter: Sendable {
    public enum Route: Equatable, Sendable {
        /// Show these results.
        case results([QueryResult])
        /// Clipboard history, filtered by this term.
        case clipboard(term: String)
        /// The Shortcuts found on this Mac.
        case shortcuts
        /// System destinations (Home, Downloads, System Settings).
        case system
        /// Larynx dictations, filtered by these words (`lx`).
        case dictations(term: String)
        /// The Larynx dashboard (`larynx`).
        case larynx
        /// The theme picker.
        case theme
        /// Usage stats for the last 28 days.
        case stats
        /// The row that deletes the usage log.
        case statsReset
    }

    /// Words that open the theme picker.
    public static let themeWords: Set<String> = ["theme", "themes", "appearance"]
    /// Words the router answers before any alias. An alias equal to one would never run.
    public static let commandWords: Set<String> = themeWords.union(["clipboard", "clip", "shortcuts", "system", "stats", "stats reset", "files", "lx", "larynx"])
    /// The most results a query shows before the file search adds more.
    public static let resultLimit = 40

    public private(set) var engine: ActionEngine
    public let configured: [LauncherAction]
    private let fileExists: @Sendable (String) -> Bool

    public init(
        configured: [LauncherAction],
        discovered: [LauncherAction] = [],
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.configured = configured
        self.engine = ActionEngine(config: LauncherConfig(version: 1, actions: LauncherConfig(version: 1, actions: configured).catalog(adding: discovered)))
        self.fileExists = fileExists
    }

    /// Recent use per action ID. It reorders matches; it never adds or removes one.
    public var usage: [String: Double] {
        get { engine.usage }
        set { engine.usage = newValue }
    }

    /// `dictations` is false when no Larynx history exists; `lx` and `larynx` then search as usual.
    public func route(_ input: String, dictations: Bool = true) -> Route {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = query.lowercased()
        if lower == "clipboard" || lower == "clip" || lower.hasPrefix("clip ") {
            return .clipboard(term: lower.hasPrefix("clip ") ? String(query.dropFirst(5)) : "")
        }
        if dictations, lower == "larynx" { return .larynx }
        if dictations, let term = Self.dictationTerm(query) { return .dictations(term: term) }
        if lower == "shortcuts" { return .shortcuts }
        if lower == "system" { return .system }
        if Self.themeWords.contains(lower) { return .theme }
        if lower == "stats" { return .stats }
        if lower == "stats reset" { return .statsReset }
        // "files <name>" goes straight to the file search.
        if lower.hasPrefix("files ") { return .results([]) }
        let matches = Array(engine.search(query).prefix(Self.resultLimit))
        if engine.config.actions.contains(where: { $0.hasAlias(query) }) {
            return .results(matches.map(QueryResult.action))
        }
        // A bare number is also an app prefix (for example, 1Password).
        // Keep matches visible; arithmetic and conversions still take priority.
        if Double(query) != nil && !matches.isEmpty { return .results(matches.map(QueryResult.action)) }
        if let calc = Calculator.evaluate(query) {
            let category: LauncherAnswer.Category = calc.detail.contains("→") ? .conversion : .calculation
            return .results([.answer(LauncherAnswer(
                id: "runtime.calculation",
                value: calc.value,
                detail: calc.detail,
                isError: calc.isError,
                category: category
            ))])
        }
        if query.hasPrefix("/") || query.hasPrefix("~/") {
            let path = (query as NSString).expandingTildeInPath
            if fileExists(path) {
                return .results([.action(LauncherAction(id: "runtime.file.direct", name: URL(fileURLWithPath: path).lastPathComponent, aliases: [], kind: .file, target: path))])
            }
        }
        // Explicit commands and recognizable destination prefixes keep their normal flow.
        let normalized = Self.compact(query)
        if (try? engine.resolve(query)) != nil || matches.contains(where: {
            Self.compact($0.name).hasPrefix(normalized) ||
            $0.aliases.contains { Self.compact($0).hasPrefix(normalized) }
        }) { return .results(matches.map(QueryResult.action)) }
        return .results(defaultSearches(query).map(QueryResult.action))
    }

    /// The filter words after `lx` (or `larynx` with words), or nil when the input is not a dictation query.
    public static func dictationTerm(_ query: String) -> String? {
        let words = query.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let first = words.first, ["lx", "larynx"].contains(first.lowercased()) else { return nil }
        return words.count > 1 ? words[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    /// Search Google, Search Google Drive, and Search Files, for a query nothing matched.
    public func defaultSearches(_ query: String) -> [LauncherAction] {
        let encoded = ActionEngine.percentEncode(query)
        let google = configuredSearch(alias: "g")
        let drive = configuredSearch(alias: "gdrive")
        return [
            LauncherAction(id: "runtime.search.google", name: "Search Google", aliases: [], kind: .webSearch, target: (google?.target ?? "https://www.google.com/search?q={query}").replacingOccurrences(of: "{query}", with: encoded), browser: google?.browser),
            LauncherAction(id: "runtime.search.drive", name: "Search Google Drive", aliases: [], kind: .webSearch, target: (drive?.target ?? "https://drive.google.com/drive/u/0/search?q={query}").replacingOccurrences(of: "{query}", with: encoded), browser: drive?.browser),
            LauncherAction(id: "runtime.search.laptop", name: "Search Files", aliases: [], kind: .laptopSearch, target: query),
        ]
    }

    /// The configured URL action behind a "Search Google" or "Search Google Drive" row.
    public func configuredSearch(for action: LauncherAction) -> LauncherAction? {
        guard action.kind == .webSearch else { return nil }
        return configuredSearch(alias: action.id == "runtime.search.google" ? "g" : "gdrive")
    }

    private func configuredSearch(alias: String) -> LauncherAction? {
        configured.first { $0.kind == .url && $0.hasAlias(alias) && $0.target.contains("{query}") }
    }

    /// Folded text with no spaces or invisible characters, so "whats app" is a prefix of "WhatsApp".
    private static func compact(_ value: String) -> String {
        LauncherText.normalize(value).filter { !$0.isWhitespace }
    }

    /// True when the slower currency and file search should run after the first results.
    public static func wantsExtendedSearch(_ input: String, firstResult: QueryResult?, dictations: Bool = true) -> Bool {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = query.lowercased()
        guard query.count >= 3, !lower.hasPrefix("clip"), lower != "shortcuts", lower != "system",
              !lower.hasPrefix("stats"), !themeWords.contains(lower), !dictations || dictationTerm(query) == nil else { return false }
        if case .answer = firstResult { return false }
        let firstAction = firstResult?.action
        // A known search alias owns its arguments; never send those to file search.
        if firstAction?.target.contains("{query}") == true || firstAction?.id == "runtime.open-url" { return false }
        return true
    }
}
