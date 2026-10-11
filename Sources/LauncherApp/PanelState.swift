import Foundation
import LauncherCore

enum PanelControl: Equatable {
    case enableClipboard
    case pauseClipboard
    case clearClipboard
    case openShortcuts
    case resetStats

    var id: String {
        switch self {
        case .enableClipboard: return "runtime.clip.enable"
        case .pauseClipboard: return "runtime.clip.pause"
        case .clearClipboard: return "runtime.clip.clear"
        case .openShortcuts: return "runtime.shortcuts.empty"
        case .resetStats: return "runtime.stats.reset"
        }
    }

    var name: String {
        switch self {
        case .enableClipboard: return "Enable Clipboard History…"
        case .pauseClipboard: return "Pause Clipboard History"
        case .clearClipboard: return "Clear Clipboard History"
        case .openShortcuts: return "No Shortcuts found. Open Shortcuts to create one"
        case .resetStats: return "Delete usage history"
        }
    }
}

enum ThemeOption: Equatable {
    case look(id: String, name: String)
    case accent(name: String, value: String)

    var id: String {
        switch self {
        case .look(let id, _): return "runtime.theme." + id
        case .accent: return "runtime.theme.accent"
        }
    }
}

enum PanelItem: Equatable {
    case action(LauncherAction)
    case answer(LauncherAnswer)
    case clipboard(id: String, text: String)
    /// A Larynx dictation. ↵ copies the final text, ⌥↵ the raw text.
    case dictation(Dictation)
    /// A line of information. Enter does nothing.
    case notice(String)
    case control(PanelControl)
    case theme(ThemeOption)
    case stats(UsageStats)
    /// The `larynx` dashboard card. Not selectable; Enter does nothing.
    case larynx(LarynxStats)
    case suggestion(AliasSuggestion)
    case emojiRow(EmojiRow)

    var id: String {
        switch self {
        case .action(let action): return action.id
        case .answer(let answer): return answer.id
        case .clipboard(let id, _): return id
        case .dictation(let dictation): return "runtime.dictation." + dictation.id
        case .notice: return "runtime.notice"
        case .control(let control): return control.id
        case .theme(let option): return option.id
        case .stats: return "runtime.stats"
        case .larynx: return "runtime.larynx"
        case .suggestion(let suggestion): return suggestion.id
        case .emojiRow(let row): return row.id
        }
    }

    var routedResult: QueryResult? {
        switch self {
        case .action(let action): return .action(action)
        case .answer(let answer): return .answer(answer)
        case .clipboard, .dictation, .notice, .control, .theme, .stats, .larynx, .suggestion, .emojiRow: return nil
        }
    }
}

struct QueryMode: Equatable {
    let action: LauncherAction
    let typedPrefix: String
}

enum PanelPresentation: Equatable {
    case standard(favoriteCount: Int)
    case stats(counts: [String: Int])
    case theme(original: AppearanceSettings)
}

struct PanelState: Equatable {
    var invocation = 0
    var queryGeneration = 0
    var mode: QueryMode?
    var items: [PanelItem] = []
    var selectedID: String?
    /// The highlighted emoji in the selected grid line.
    var emojiColumn = 0
    var presentedQueryKey: String?
    var presentation: PanelPresentation = .standard(favoriteCount: 0)

    mutating func beginInvocation() {
        invocation += 1
        mode = nil
        selectedID = nil
        presentedQueryKey = nil
        emojiColumn = 0
        presentation = .standard(favoriteCount: 0)
    }
}
