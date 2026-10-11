import Foundation

public extension LauncherConfig {
    func validated() throws -> LauncherConfig {
        guard version == 1 else { throw LauncherError.unsupportedVersion(version) }

        var ids = Set<String>()
        var aliases = Set<String>()

        for action in actions {
            let id = action.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = action.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let target = action.target.trimmingCharacters(in: .whitespacesAndNewlines)
            // Resolution uses the stored text, so it must be the text that was checked.
            // Snippet bodies keep their whitespace on purpose.
            let padded = id != action.id || name != action.name || action.browser.map { $0 != $0.trimmingCharacters(in: .whitespacesAndNewlines) } == true
                || (action.kind != .snippet && target != action.target)
            guard !padded else { throw LauncherError.invalidAction("\(id) has spaces around a value") }
            guard !id.isEmpty else { throw LauncherError.invalidAction("id cannot be empty") }
            guard !name.isEmpty else { throw LauncherError.invalidAction("\(id) has an empty name") }
            guard !target.isEmpty else { throw LauncherError.invalidAction("\(id) has an empty target") }

            let normalizedID = LauncherText.normalize(id)
            guard ids.insert(normalizedID).inserted else { throw LauncherError.duplicateID(id) }

            guard !action.aliases.isEmpty else {
                throw LauncherError.invalidAction("\(id) must have at least one alias")
            }
            for alias in action.aliases {
                let normalizedAlias = LauncherText.normalizeWords(alias)
                guard !normalizedAlias.isEmpty else {
                    throw LauncherError.invalidAction("\(id) has an empty alias")
                }
                guard aliases.insert(normalizedAlias).inserted else {
                    throw LauncherError.duplicateAlias(alias)
                }
            }

            if let fallback = action.emptyQueryTarget {
                guard action.kind == .url, target.contains("{query}"), !fallback.contains("{query}") else {
                    throw LauncherError.invalidAction("\(id) has an invalid empty-search destination")
                }
                try Self.validateURL(fallback)
            }
            switch action.kind {
            case .url:
                try Self.validateURL(target)
                if let browser = action.browser, !Self.isBundleIdentifier(browser) {
                    throw LauncherError.invalidAction("\(id) has an invalid browser bundle identifier")
                }
            case .app:
                guard action.browser == nil else {
                    throw LauncherError.invalidAction("\(id) may only specify browser for a URL")
                }
                guard Self.isBundleIdentifier(target) else {
                    throw LauncherError.invalidAction("\(id) has an invalid app bundle identifier")
                }
            case .terminal:
                guard action.browser == nil, target.hasPrefix("/"),
                      URL(fileURLWithPath: target).pathExtension == "command",
                      !target.contains("\n"), !target.contains("\r"), !target.contains("{query}") else {
                    throw LauncherError.invalidAction("\(id) must name an absolute .command file, without a query or browser")
                }
            case .workspace:
                guard action.browser == nil, Self.isWorkspaceURL(action.target) else {
                    throw LauncherError.invalidAction("\(id) must be an app URL such as hammerspoon://name, without a query or browser")
                }
            case .snippet:
                guard action.browser == nil else {
                    throw LauncherError.invalidAction("\(id) may only specify browser for a URL")
                }
                try SnippetRenderer.validate(target)
            case .application, .file, .shortcut, .system, .webSearch, .laptopSearch, .emoji, .calculation, .error, .clipboard, .dictation, .local, .theme, .accent, .stats:
                throw LauncherError.unsupportedKind(action.kind.rawValue)
            }
        }
        return self
    }

    /// A workspace target is a custom-scheme URL that another app handles, for example
    /// `hammerspoon://my-layout`. Web, file, and script schemes are refused.
    static func isWorkspaceURL(_ target: String) -> Bool {
        guard !target.contains(where: { $0.isWhitespace || $0 == "{" || $0 == "}" }),
              let url = URL(string: target), let scheme = url.scheme?.lowercased(),
              target.lowercased().hasPrefix(scheme + "://"), url.host?.isEmpty == false,
              scheme.range(of: #"^[a-z][a-z0-9+.-]*$"#, options: .regularExpression) != nil else { return false }
        return !["http", "https", "file", "javascript", "data", "about", "ftp"].contains(scheme)
    }

    private static func validateURL(_ target: String) throws {
        let marker = "launcherquery"
        let occurrences = target.components(separatedBy: "{query}").count - 1
        guard occurrences <= 1 else { throw LauncherError.invalidURLTemplate(target) }

        let rendered = target.replacingOccurrences(of: "{query}", with: marker)
        guard !rendered.contains("{") && !rendered.contains("}") else {
            throw LauncherError.invalidURLTemplate(target)
        }
        guard let components = URLComponents(string: rendered),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty else {
            throw LauncherError.invalidURLTemplate(target)
        }
        guard scheme == "https" || scheme == "http" else {
            throw LauncherError.unsupportedURLScheme(scheme)
        }
        if occurrences == 1 {
            guard let schemeDelimiter = target.range(of: "://") else {
                throw LauncherError.invalidURLTemplate(target)
            }
            let suffix = target[schemeDelimiter.upperBound...]
            let authorityEnd = suffix.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? target.endIndex
            let authority = target[..<authorityEnd]
            guard !authority.contains("{query}") else {
                throw LauncherError.invalidURLTemplate(target)
            }
        }
    }

    private static func isBundleIdentifier(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}

public extension LauncherAction {
    /// True when an alias matches with the same rules validation and search use.
    func hasAlias(_ alias: String) -> Bool {
        let wanted = LauncherText.normalizeWords(alias)
        return aliases.contains { LauncherText.normalizeWords($0) == wanted }
    }
}

enum LauncherText {
    /// Drops invisible format characters. WhatsApp's name starts with a left-to-right mark.
    static func visible(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter { $0.properties.generalCategory != .format }))
    }

    static func normalize(_ value: String) -> String {
        visible(value).trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func words(_ value: String) -> [Substring] {
        value.split(whereSeparator: { $0.isWhitespace })
    }

    static func normalizeWords(_ value: String) -> String {
        words(normalize(value)).joined(separator: " ")
    }
}
