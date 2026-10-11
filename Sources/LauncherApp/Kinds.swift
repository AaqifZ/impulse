import LauncherCore

/// How each kind of action looks in the list. Every switch lists every kind, so a new kind
/// does not compile until it has a symbol, a section, and footer hints.
extension ActionKind {
    /// The SF Symbol a row shows until (or in place of) a real icon.
    func symbol(target: String) -> String {
        switch self {
        case .url: return target.contains("{query}") ? "magnifyingglass" : "arrow.up.right"
        case .app, .application: return "app"
        case .terminal: return "terminal"
        case .workspace: return "rectangle.split.2x2"
        case .snippet: return "text.quote"
        case .file: return "doc"
        case .shortcut: return "command"
        case .system: return "gearshape"
        case .webSearch: return "magnifyingglass"
        case .laptopSearch: return "laptopcomputer"
        case .calculation: return "equal.square"
        case .error: return "exclamationmark.triangle"
        case .clipboard: return "doc.on.clipboard"
        case .dictation: return "waveform"
        case .local: return target.hasPrefix("clipboard") ? "doc.on.clipboard" : "gearshape"
        case .theme, .accent: return "circle"
        case .stats: return "chart.bar"
        case .emoji: return "face.smiling"
        }
    }

    /// Answers and the theme picker keep their section whatever the query is.
    var hasFixedSection: Bool { isAnswer || self == .theme || self == .accent || self == .stats }

    /// The header a result sits under when it is not the top hit or a favorite.
    func section(instrument: Bool) -> String {
        switch self {
        case .calculation, .error, .stats: return ""
        case .theme: return "Theme"
        case .accent: return instrument ? "Signal accent" : "Accent"
        case .app, .application: return "Applications"
        case .file: return "Files"
        case .webSearch, .laptopSearch: return "Search"
        case .emoji: return "Commands"
        case .shortcut, .local, .system: return "Commands"
        case .clipboard: return "Clipboard"
        case .dictation: return "Larynx"
        case .url, .terminal, .workspace, .snippet: return "Destinations"
        }
    }

    /// Footer hints while a row of this kind is selected.
    func hints(for action: LauncherAction, instrument: Bool) -> [(key: String, label: String)] {
        switch self {
        case .calculation:
            return DisplayFormat.rounded(action.target) == action.target ? [("↵", "Copy")] : [("↵", "Copy"), ("⌥↵", "Copy full")]
        case .snippet, .clipboard: return [("↵", "Copy")]
        case .dictation: return [("↵", "Copy"), ("⌥↵", "Copy raw")]
        case .error: return [("esc", "Close")]
        case .file: return [("↵", "Open"), ("⌘Y", "Preview"), ("⌘↵", "Reveal")]
        case .application: return [("↵", "Open"), ("⌘↵", "Reveal")]
        case .webSearch: return [("↵", "Search")]
        case .laptopSearch: return [("↵", "Search this Mac")]
        case .shortcut: return [("↵", "Run")]
        case .theme: return [("↑↓", "Preview"), ("↵", "Apply"), ("esc", "Revert")]
        case .accent: return instrument ? [("←→", "Accent"), ("↵", "Apply"), ("esc", "Revert")] : [("↵", "Apply"), ("esc", "Revert")]
        case .url: return action.target.contains("{query}") ? [("↵", "Open"), ("⇥", "Search")] : [("↵", "Open")]
        case .app, .terminal, .workspace, .system, .local: return [("↵", "Open")]
        case .emoji: return [("↵", "Open"), ("⇥", "Search")]
        case .stats: return [("esc", "Close")]
        }
    }
}
