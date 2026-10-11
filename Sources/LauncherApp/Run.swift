import AppKit
import LauncherCore
import Quartz

final class FilePreviewWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
}

/// One run of a chosen action: the panel session that started it, and its usage record.
/// It travels with the run, so a slow completion never reads another run's state.
struct Execution {
    let invocation: Int
    let usage: UsageEvent
}

/// From a selected row to an action: resolve it, run it, and show the outcome.
extension AppDelegate {
    @objc func executeSelected() {
        let started = PerformanceMetrics.now()
        defer { performance.record(.enterHandler, since: started) }
        guard let engine = router?.engine, let selected = selectedItem else { return }
        switch selected {
        case .answer(let answer):
            guard !answer.isError else { return }
            let result = ResolvedAction(actionID: answer.id, kind: .calculation, value: answer.value)
            let execution = Execution(invocation: panelState.invocation, usage: usageEvent(forTransientKind: .calculation))
            let ok = clipboard.copy(DisplayFormat.rounded(answer.value))
            finish(result, ok ? .init(status: "copied", hides: true) : .init(status: "copy-failed"), execution)
            return
        case .clipboard(_, let text):
            let result = ResolvedAction(actionID: "runtime.clipboard", kind: .clipboard, value: "")
            let execution = Execution(invocation: panelState.invocation, usage: usageEvent(forTransientKind: .clipboard))
            let ok = clipboard.copy(text)
            finish(result, ok ? .init(status: "copied", hides: true) : .init(status: "copy-failed"), execution)
            return
        case .dictation(let dictation): copyDictation(dictation.textFinal); return
        case .notice: return
        case .control(let control): execute(control); return
        case .theme: applyThemeSelection(); return
        case .stats, .larynx: return
        case .suggestion(let suggestion): acceptSuggestion(suggestion); return
        case .emojiRow: pickEmoji(paste: true); return
        case .action(let selectedAction):
            let action = panelState.mode?.action.kind == .laptopSearch ? selectedAction : (panelState.mode?.action ?? selectedAction)
            let execution = Execution(invocation: panelState.invocation, usage: usageEvent(for: action))
            execute(action, engine: engine, execution: execution)
        }
    }

    private func execute(_ action: LauncherAction, engine: ActionEngine, execution: Execution) {
        if executeNative(action, execution) { return }
        do {
            let resolved: ResolvedAction
            if panelState.mode != nil {
                resolved = try engine.resolveQueryMode(action: action, query: field.stringValue)
            } else if action.target.contains("{query}") {
                if let inline = try? engine.resolve(field.stringValue), inline.actionID == action.id { resolved = inline }
                else if action.emptyQueryTarget != nil { resolved = try engine.resolve(action: action, query: "") }
                else { enterQueryMode(); return }
            } else { resolved = try engine.resolve(action: action, query: "") }
            execute(resolved, execution)
        } catch { footer.message = String(describing: error) }
    }

    /// Runs actions that need no engine resolution. False sends the action to the engine.
    @discardableResult func executeNative(_ action: LauncherAction, _ execution: Execution? = nil) -> Bool {
        let result = ResolvedAction(actionID: action.id, kind: action.kind, value: action.target)
        let done: ActionRunner.Done = { [weak self] in self?.finish(result, $0, execution) }
        switch action.kind {
        case .webSearch: runner.open(action.target, browser: action.browser, done: done)
        case .laptopSearch: enterLaptopSearch(action.target)
        case .emoji: enterEmojiMode()
        case .error, .stats, .theme, .accent, .calculation, .clipboard, .dictation, .local: break
        case .terminal: runner.runTerminal(action.target, done: done)
        case .workspace:
            runner.openWorkspace(action.target, progress: { [weak self] message in
                guard let self, self.owns(execution) else { return }
                self.footer.message = message
            }, done: done)
        case .application: runner.openApplication(at: URL(fileURLWithPath: action.target), failure: "Could not open application.", done: done)
        case .file: finish(result, panelState.mode?.action.kind == .laptopSearch ? runner.openSourceFolder(of: action.target) : runner.openFile(action.target), execution)
        case .system:
            guard action.target == "system-settings", let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") else { break }
            runner.openApplication(at: url, failure: nil, done: done)
        case .shortcut: confirmShortcut(action, done: done)
        case .url, .app, .snippet: return false
        }
        return true
    }

    func execute(_ control: PanelControl) {
        switch control {
        case .enableClipboard: toggleClipboard()
        case .pauseClipboard: clipboard.setEnabled(false); refreshResults(); publishStatus()
        case .clearClipboard: clearClipboard()
        case .resetStats: confirmStatsReset()
        case .openShortcuts:
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                hide()
            }
        }
    }

    /// Runs an action that the engine resolved.
    func execute(_ result: ResolvedAction, _ execution: Execution? = nil) {
        let done: ActionRunner.Done = { [weak self] in self?.finish(result, $0, execution) }
        switch result.kind {
        case .snippet: finish(result, runner.copySnippet(result.value), execution)
        case .app: runner.openApp(bundleID: result.value, done: done)
        case .url: runner.open(result.value, browser: result.browser, done: done)
        case .terminal, .workspace, .application, .file, .shortcut, .system, .webSearch, .laptopSearch, .emoji, .calculation, .error, .clipboard, .dictation, .local, .theme, .accent, .stats:
            footer.message = "Unsupported action."
        }
    }

    /// Records an outcome, shows its message, and hides the panel when the action finished.
    /// The record always happens; the message and hide only reach the panel session that started the run.
    func finish(_ result: ResolvedAction, _ outcome: ActionRunner.Outcome, _ execution: Execution? = nil) {
        if let execution, outcome.hides || outcome.status == "completed" { remember(execution.usage) }
        if let status = outcome.status { record(result, outcome: status) }
        guard owns(execution) else { return }
        if let message = outcome.message { footer.message = message }
        if outcome.hides { hide() }
    }

    /// False when the panel was reopened after this run started.
    func owns(_ execution: Execution?) -> Bool {
        execution.map { $0.invocation == panelState.invocation } ?? true
    }

    func record(_ result: ResolvedAction, outcome: String) {
        lastActionID = result.actionID
        lastActionOutcome = outcome
        publishStatus()
    }

    /// Shortcuts can change files or contact services, so each run asks first.
    private func confirmShortcut(_ action: LauncherAction, done: @escaping ActionRunner.Done) {
        guard runner.runningShortcut == nil else {
            footer.message = runner.shortcutStopping ? "The last Shortcut is still stopping." : "A Shortcut is already running."
            return
        }
        let alert = NSAlert()
        alert.messageText = "Run \(action.name)?"
        alert.informativeText = "This runs your Apple Shortcut with its existing permissions. Shortcuts can change files or contact other services."
        alert.addButton(withTitle: "Run Shortcut"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.footer.message = "Running Shortcut…"
            self.runner.runShortcut(action.target, done: done)
        }
    }

    @objc func toggleClipboard() {
        if clipboard.enabled { clipboard.setEnabled(false); refreshResults(); publishStatus(); return }
        show()
        let alert = NSAlert()
        alert.messageText = "Enable clipboard history for this session?"
        alert.informativeText = "Copied text will be kept in this app's memory only: up to 50 items for 24 hours. Known password-manager and concealed entries are skipped, but other sensitive text may still be captured. Nothing is uploaded or saved to disk. Quit clears history. You can pause or clear it from the menu."
        alert.addButton(withTitle: "Enable"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn { self.clipboard.setEnabled(true) }
            self.refreshResults(); self.publishStatus()
        }
    }

    func copyFullPrecision() {
        guard panelState.mode == nil, case .answer(let answer)? = selectedItem, !answer.isError else { return }
        let execution = Execution(invocation: panelState.invocation, usage: usageEvent(forTransientKind: .calculation))
        let ok = clipboard.copy(answer.value)
        finish(ResolvedAction(actionID: answer.id, kind: .calculation, value: answer.value), ok ? .init(status: "copied-full", hides: true) : .init(status: "copy-failed"), execution)
    }

    /// ⌥↵: the raw text of a dictation, or the full precision of an answer.
    func copyAlternate() {
        if panelState.mode == nil, case .dictation(let dictation)? = selectedItem { copyDictation(dictation.textRaw); return }
        copyFullPrecision()
    }

    /// Copies a dictation and closes. The usage log records the kind only, never the text.
    func copyDictation(_ text: String) {
        let result = ResolvedAction(actionID: "runtime.dictation", kind: .dictation, value: "")
        let execution = Execution(invocation: panelState.invocation, usage: usageEvent(forTransientKind: .dictation))
        let ok = clipboard.copy(text)
        finish(result, ok ? .init(status: "copied", hides: true) : .init(status: "copy-failed"), execution)
    }

    @objc func clearClipboard() { clipboard.clear(); refreshResults(); publishStatus() }

    func revealSelected() {
        guard let action = selectedAction, action.kind == .file || action.kind == .application else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: action.target)])
        hide()
    }

    func previewSelected() {
        guard let action = selectedAction, action.kind == .file else { return }
        guard FileManager.default.fileExists(atPath: action.target) else { footer.message = "File is no longer available."; return }
        previewWindow?.close()
        let frame = NSRect(x: 0, y: 0, width: 780, height: 560)
        let window = FilePreviewWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.title = action.name
        guard let preview = QLPreviewView(frame: frame, style: .normal) else { footer.message = "Preview unavailable."; return }
        preview.autoresizingMask = [.width, .height]
        preview.shouldCloseWithWindow = true
        preview.previewItem = NSURL(fileURLWithPath: action.target)
        window.contentView = preview
        previewWindow = window
        window.center()
        hide()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
