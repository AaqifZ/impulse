import Foundation

public struct LauncherConfig: Codable, Equatable, Sendable {
    public let version: Int
    public let actions: [LauncherAction]

    public init(version: Int, actions: [LauncherAction]) {
        self.version = version
        self.actions = actions
    }
}

/// Every kind of action Impulse knows. Raw values are the strings stored in configuration.
public enum ActionKind: String, Codable, Sendable, CaseIterable {
    // Configuration kinds: users write these in actions.json.
    case url, app, terminal, workspace, snippet
    // Discovery kinds: Impulse finds these on the Mac.
    case application, file, shortcut, system
    // Runtime search actions.
    case webSearch = "web-search", laptopSearch = "laptop-search", emoji
    // Legacy display kinds remain decodable for existing usage history.
    case calculation, error, clipboard, local, theme, accent, stats
    // A copied Larynx dictation. The usage log records the kind, never the text.
    case dictation

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let kind = ActionKind(rawValue: raw) else { throw LauncherError.unsupportedKind(raw) }
        self = kind
    }

    /// Kinds that actions.json may contain.
    public var isConfigurable: Bool {
        switch self {
        case .url, .app, .terminal, .workspace, .snippet: return true
        default: return false
        }
    }

    /// An app, found on the Mac or named by bundle ID.
    public var isApp: Bool { self == .application || self == .app }

    /// A calculator or converter answer, shown as an answer card.
    public var isAnswer: Bool { self == .calculation || self == .error }
}

public struct LauncherAction: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let aliases: [String]
    public let kind: ActionKind
    public let target: String
    public let browser: String?
    public let emptyQueryTarget: String?

    public init(
        id: String,
        name: String,
        aliases: [String],
        kind: ActionKind,
        target: String,
        browser: String? = nil,
        emptyQueryTarget: String? = nil
    ) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.kind = kind
        self.target = target
        self.browser = browser
        self.emptyQueryTarget = emptyQueryTarget
    }
}

/// A transient answer shown by the launcher. It is display data, not a saved action.
public struct LauncherAnswer: Equatable, Sendable {
    public enum Category: Equatable, Sendable {
        case calculation
        case conversion
        case currency
    }

    public let id: String
    public let value: String
    public let detail: String
    public let isError: Bool
    public let category: Category

    public init(id: String, value: String, detail: String, isError: Bool, category: Category) {
        self.id = id
        self.value = value
        self.detail = detail
        self.isError = isError
        self.category = category
    }
}

/// The pure router returns executable actions or transient answers.
public enum QueryResult: Equatable, Sendable {
    case action(LauncherAction)
    case answer(LauncherAnswer)

    public var action: LauncherAction? {
        guard case .action(let action) = self else { return nil }
        return action
    }
}

public struct ResolvedAction: Codable, Equatable, Sendable {
    public let actionID: String
    public let kind: ActionKind
    public let value: String
    public let browser: String?
    public let cursorOffset: Int?

    public init(
        actionID: String,
        kind: ActionKind,
        value: String,
        browser: String? = nil,
        cursorOffset: Int? = nil
    ) {
        self.actionID = actionID
        self.kind = kind
        self.value = value
        self.browser = browser
        self.cursorOffset = cursorOffset
    }
}

public enum LauncherError: Error, Equatable, LocalizedError, Sendable {
    case malformedConfiguration(String)
    case unsupportedVersion(Int)
    case invalidAction(String)
    case duplicateID(String)
    case duplicateAlias(String)
    case unsupportedKind(String)
    case invalidURLTemplate(String)
    case unsupportedURLScheme(String)
    case invalidSnippetTemplate(String)
    case noMatch(String)
    case missingQuery(String)
    case unexpectedQuery(String)
    case rollbackUnavailable
    case lockFailed(String)

    public var errorDescription: String? {
        switch self {
        case .malformedConfiguration(let detail): return "Malformed configuration: \(detail)"
        case .unsupportedVersion(let version): return "Unsupported configuration version: \(version)"
        case .invalidAction(let detail): return "Invalid action: \(detail)"
        case .duplicateID(let id): return "Duplicate action id: \(id)"
        case .duplicateAlias(let alias): return "Duplicate alias: \(alias)"
        case .unsupportedKind(let kind): return "Unsupported action kind: \(kind)"
        case .invalidURLTemplate(let target): return "Invalid URL template: \(target)"
        case .unsupportedURLScheme(let scheme): return "Unsupported URL scheme: \(scheme)"
        case .invalidSnippetTemplate(let detail): return "Invalid snippet template: \(detail)"
        case .noMatch(let input): return "No action matches: \(input)"
        case .missingQuery(let id): return "Action requires a query: \(id)"
        case .unexpectedQuery(let id): return "Action does not accept a query: \(id)"
        case .rollbackUnavailable: return "No previous valid configuration is available"
        case .lockFailed(let detail): return "Could not lock configuration: \(detail)"
        }
    }
}
