import AppKit
import LauncherCore

final class PalettePanel: NSPanel {
    var dismiss: (() -> Void)?
    var shortcut: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown && event.keyCode == 53 {
            dismiss?()
            return
        }
        if event.type == .keyDown, shortcut?(event) == true { return }
        super.sendEvent(event)
    }
    override func cancelOperation(_ sender: Any?) { dismiss?() }
}

final class ResultsTable: NSTableView {
    override var acceptsFirstResponder: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var panel: PalettePanel!
    var field = NSTextField()
    var statusLabel = NSTextField(labelWithString: "")
    var footer = FooterView()
    var signalLine = SignalLineView()
    var backdrop = NSVisualEffectView()
    var appearanceSettings = AppearanceSettings.standard
    var theme = Theme.signal(accent: "volt")
    var presentingResults = false
    var rows: [DisplayRow] = []
    var placeholderText: String?
    var rowPool: [ResultRowView] = []
    let card = NSView()
    var cardHeight: NSLayoutConstraint!
    var shadowPending = false
    let modeChip = NSView()
    let modeChipLabel = NSTextField(labelWithString: "")
    var fieldLeadingToCard: NSLayoutConstraint!
    var fieldLeadingToChip: NSLayoutConstraint!
    var panelState = PanelState()
    var table = ResultsTable()
    var statusItem: NSStatusItem!
    var router: QueryRouter?
    var actions: [LauncherAction] = []
    var activeRevision = ""
    var configError: String?
    var timer: Timer?
    var configWatcher: ConfigWatcher?
    var hotkey: GlobalShortcut?
    var emojiHotkey: GlobalShortcut?
    /// Emoji imported from Raycast, most used first (config/emoji-seed.json).
    var emojiSeed: [String] = []
    /// Replaces the Hammerspoon paste in self-tests.
    var pasteOverride: (() -> Bool)?
    var outsideClickMonitor: Any?
    let clipboard: ClipboardHistory
    /// Larynx dictation history, opened read-only on first use. Self-tests swap in a fixture.
    var dictations = DictationHistory()
    lazy var iconProvider = IconProvider(
        iconsDirectory: configURL.deletingLastPathComponent().appendingPathComponent("icons", isDirectory: true)
    )
    var nativeActions: [LauncherAction] = []
    var catalogRefreshing = false
    var lastCatalogRefresh = Date.distantPast
    var shortcutError: String?
    var queryWork: DispatchWorkItem?
    var laptopFileSearch: (String) -> [LauncherAction] = { Discovery.files(matching: $0, limit: 30) }
    /// Limits file search to one folder (design captures); nil searches the home folder.
    var fileSearchRoot: URL?
    var previewWindow: NSWindow?
    var applicationObserver: NSObjectProtocol?
    let runner = ActionRunner()
    lazy var usageLog = UsageLog(directory: configURL.deletingLastPathComponent().appendingPathComponent("runtime/usage", isDirectory: true))
    var usageEvents: [UsageEvent] = []
    var openedAt: UInt64 = 0
    var lastActionID: String?
    var lastActionOutcome: String?
    var usageLoadGeneration = 0
    let performance = PerformanceMetrics()
    var lastMetricsFlush = Date.distantPast
    var lastWindowEvent = "starting"
    let configURL: URL = {
        // AAQIF_CONFIG is the legacy name, still read when IMPULSE_CONFIG is unset.
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["IMPULSE_CONFIG"] ?? environment["AAQIF_CONFIG"] { return URL(fileURLWithPath: path) }
        return Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("config/actions.json")
    }()
    var store: ConfigStore { ConfigStore(url: configURL) }
    var statusURL: URL { configURL.deletingLastPathComponent().appendingPathComponent("runtime/status.json") }
    var settingsURL: URL { configURL.deletingLastPathComponent().appendingPathComponent("settings.json") }

    override init() {
        clipboard = ClipboardHistory()
        super.init()
    }

    init(clipboard: ClipboardHistory) {
        self.clipboard = clipboard
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        appearanceSettings = AppearanceSettings.load(from: settingsURL)
        theme = Theme.make(appearanceSettings)
        setupMenu()
        setupPanel()
        emojiSeed = EmojiCatalog.loadSeed(from: configURL.deletingLastPathComponent().appendingPathComponent("emoji-seed.json"))
        reloadConfig()
        configWatcher = ConfigWatcher(url: configURL) { [weak self] result in
            self?.acceptConfig(result)
        }
        configWatcher?.start()
        configWatcher?.requestReload()
        let captureDirectory = StateCapture.directory
        if captureDirectory == nil {
            hotkey = GlobalShortcut { [weak self] in self?.toggle() }
            emojiHotkey = GlobalShortcut(modifiers: [.control]) { [weak self] in self?.toggleEmoji() }
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                guard let self, self.panel.isVisible else { return }
                self.hide()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastMetricsFlush) >= 30 {
                self.lastMetricsFlush = Date()
                self.performance.flush(to: self.configURL.deletingLastPathComponent().appendingPathComponent("runtime/timings.json"))
            }
            self.clipboard.tick(frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
            if Date().timeIntervalSince(self.lastCatalogRefresh) > 60 { self.refreshCatalog() }
        }
        refreshCatalog()
        loadUsage()
        applicationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.clipboard.applicationChanged() }
        // Launch quietly: a launch (login, rebuild, restart) must never take the keyboard. The hotkey shows the panel.
        if let captureDirectory {
            show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { StateCapture.run(self, into: captureDirectory) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !panel.isVisible { show() }
        else { panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(field) }
        return true
    }

    func setupMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Impulse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (title, selector, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = PulseMark.image(size: 18, color: nil)
        statusItem.button?.image?.accessibilityDescription = "Impulse"
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Launcher  ⌘Space", action: #selector(show), keyEquivalent: "")
        open.target = self; menu.addItem(open)
        let reload = NSMenuItem(title: "Reload Configuration", action: #selector(manualReload), keyEquivalent: "")
        reload.target = self; menu.addItem(reload)
        let catalog = NSMenuItem(title: "Refresh Apps & Shortcuts", action: #selector(refreshCatalog), keyEquivalent: "")
        catalog.target = self; menu.addItem(catalog)
        let clips = NSMenuItem(title: "Enable / Pause Clipboard History…", action: #selector(toggleClipboard), keyEquivalent: "")
        clips.target = self; menu.addItem(clips)
        let clear = NSMenuItem(title: "Clear Clipboard History", action: #selector(clearClipboard), keyEquivalent: "")
        clear.target = self; menu.addItem(clear)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Impulse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc func manualReload() {
        if let configWatcher { configWatcher.requestReload() }
        else { reloadConfig() }
    }

    func reloadConfig() {
        acceptConfig(Result { try store.snapshot() })
    }

    func acceptConfig(_ result: Result<ConfigWatcher.Snapshot, Error>) {
        do {
            let snapshot = try result.get()
            let revision = snapshot.revision
            guard revision != activeRevision || router == nil else {
                if configError != nil { configError = nil; refreshResults(); publishStatus() }
                return
            }
            let config = snapshot.config
            actions = config.actions
            rebuildRouter()
            activeRevision = revision
            configError = nil
            if let current = panelState.mode, current.action.kind != .laptopSearch {
                panelState.mode = actions.first(where: { $0.id == current.action.id }).map {
                    QueryMode(action: $0, typedPrefix: current.typedPrefix)
                }
            }
            refreshResults()
            publishStatus()
        } catch {
            // Do not put malformed private URL/snippet content into runtime status.
            let message = "invalid-or-unreadable-configuration"
            if configError != message { configError = message; refreshResults(); publishStatus() }
        }
    }

    func publishStatus() {
        var value: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "activeRevision": activeRevision, "actionCount": actions.count, "visible": panel?.isVisible ?? false, "configPath": configURL.path, "updatedAt": ISO8601DateFormatter().string(from: Date()), "shortcut": "Command-Space"]
        value["configError"] = configError
        value["shortcutRegistered"] = hotkey?.isRegistered ?? false
        value["emojiShortcutRegistered"] = emojiHotkey?.isRegistered ?? false
        value["invocationCount"] = panelState.invocation
        value["lastWindowEvent"] = lastWindowEvent
        value["lastActionID"] = lastActionID
        value["lastActionOutcome"] = lastActionOutcome
        value["discoveredAppCount"] = nativeActions.filter { $0.kind == .application }.count
        value["shortcutCount"] = nativeActions.filter { $0.kind == .shortcut }.count
        value["shortcutDiscoveryError"] = shortcutError
        value["clipboardEnabled"] = clipboard.enabled
        value["clipboardCount"] = clipboard.entries.count
        do {
            try FileManager.default.createDirectory(at: statusURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: statusURL, options: .atomic)
        } catch { NSLog("Could not write launcher status: %@", error.localizedDescription) }
    }

    @objc func show() {
        let started = PerformanceMetrics.now()
        defer { performance.record(.openHandler, since: started) }
        revertThemePreview()
        panelState.beginInvocation()
        field.stringValue = ""
        recordOpen()
        refreshResults()
        if let screen = NSScreen.main {
            // Anchor the top edge about a fifth of the way down; height then grows downward.
            let frame = screen.visibleFrame
            let top = frame.maxY - frame.height * 0.2
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: top - panel.frame.height))
        }
        lastWindowEvent = "shown"
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        (field.currentEditor() as? NSTextView)?.insertionPointColor = theme.instrument ? theme.accent : .controlAccentColor
        publishStatus()
    }

    func toggle() { panel.isVisible ? hide() : show() }
    func hide() {
        // Stop pending search work; a finished search must not repaint a hidden panel.
        queryWork?.cancel()
        panelState.queryGeneration += 1
        revertThemePreview()
        lastWindowEvent = "dismissed"
        panel.orderOut(nil)
        publishStatus()
    }
    func dismissSearchOrHide() {
        if case .theme = panelState.presentation { hide() }
        else if panelState.mode?.action.kind == .laptopSearch { panelState.mode = nil; refreshResults() }
        else { hide() }
    }
    // Explicit dismissal avoids transient application activation stealing the panel
    // during global invocation. Escape, the shortcut, and successful actions close it.
    func windowDidResignKey(_ notification: Notification) { publishStatus() }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        configWatcher?.stop()
        queryWork?.cancel()
        previewWindow?.close()
        runner.stopShortcut()
        if let applicationObserver { NSWorkspace.shared.notificationCenter.removeObserver(applicationObserver) }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        try? FileManager.default.removeItem(at: statusURL)
    }
}

if CommandLine.arguments.contains("--self-test-clipboard") {
    ClipboardHistory.runChecks()
    exit(0)
}
if CommandLine.arguments.contains("--self-test-integration") {
    do {
        try IntegrationChecks.run()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("FAIL integration checks: \(error)\n".utf8))
        exit(1)
    }
}
if CommandLine.arguments.contains("--self-test-icons") {
    do {
        try IconProvider.runChecks()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("FAIL icon checks: \(error)\n".utf8))
        exit(1)
    }
}
if CommandLine.arguments.contains("--benchmark-ui") {
    do { try PerformanceChecks.run(); exit(0) }
    catch { FileHandle.standardError.write(Data("FAIL performance checks: \(error)\n".utf8)); exit(1) }
}
if CommandLine.arguments.contains("--self-test-config-watcher") {
    do { try ConfigWatcher.runChecks(); exit(0) }
    catch { FileHandle.standardError.write(Data("FAIL config watcher: \(error)\n".utf8)); exit(1) }
}
if CommandLine.arguments.contains("--self-test-capture") {
    do { try StateCapture.runChecks(); exit(0) }
    catch { FileHandle.standardError.write(Data("FAIL capture checks: \(error)\n".utf8)); exit(1) }
}
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
