import AppKit
import Darwin
import LauncherCore
import SQLite3

enum IntegrationChecks {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false
        var value: Bool { lock.withLock { stored } }
        func set() { lock.withLock { stored = true } }
    }

    static func run() throws {
        _ = NSApplication.shared
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("impulse-integration-\(UUID().uuidString)", isDirectory: true)
        let temporaryConfig = temporaryRoot.appendingPathComponent("config/actions.json")
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let previousConfig = ProcessInfo.processInfo.environment["IMPULSE_CONFIG"]
        setenv("IMPULSE_CONFIG", temporaryConfig.path, 1)
        defer {
            if let previousConfig { setenv("IMPULSE_CONFIG", previousConfig, 1) }
            else { unsetenv("IMPULSE_CONFIG") }
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let history = ClipboardHistory(pasteboard: board)
        let app = AppDelegate(clipboard: history)
        app.laptopFileSearch = { query in
            [LauncherAction(id: "fixture.party", name: query, aliases: [], kind: .file, target: temporaryRoot.appendingPathComponent("Party Recap.mov").path)]
        }
        try check(app.configURL.standardizedFileURL == temporaryConfig.standardizedFileURL, "temporary status configuration")
        try check(app.statusURL.path.hasPrefix(temporaryRoot.path + "/"), "temporary status destination")
        try shortcutLifecycle(in: temporaryRoot)
        app.setupPanel()
        defer {
            app.queryWork?.cancel()
            app.panel.orderOut(nil)
            app.panel.close()
        }

        app.actions = syntheticActions
        app.nativeActions = [
            LauncherAction(
                id: "check.application",
                name: "Synthetic Application",
                aliases: ["syntheticapp"],
                kind: .application,
                target: "/private/tmp/Synthetic.app"
            )
        ]
        app.nativeActions += [
            LauncherAction(id: "check.installer", name: "1Password Installer", aliases: ["1password installer"], kind: .application, target: "/Applications/1Password Installer.app"),
            LauncherAction(id: "check.password", name: "1Password", aliases: ["1password"], kind: .application, target: "/Applications/1Password.app"),
            LauncherAction(id: "check.safari", name: "Safari", aliases: ["safari"], kind: .application, target: "/Applications/Safari.app")
        ]
        app.rebuildRouter()
        for query in ["1", "1p", "1password"] {
            try check(app.searchResults(query).first?.id == "check.password", "app priority for \(query)")
        }
        try check(app.searchResults("saf").first?.id == "check.safari", "Safari prefix")
        try check(app.searchResults("1password installer").first?.id == "check.installer", "explicit installer")
        guard case .answer(let quickAnswer)? = app.searchResults("1 + 2").first else { throw Failure(description: "arithmetic answer type") }
        try check(quickAnswer.value == "3", "arithmetic preserved")

        try check(app.searchResults("check").first?.id == "check.search", "saved alias priority")
        try check(app.searchResults("2+2").first?.id == "check.exact", "exact alias before calculator")
        try check(app.searchResults("syntheticapp").first?.id == "check.application", "application routing")

        guard case .answer(let arithmetic)? = app.searchResults("2 * (3 + 4)").first else { throw Failure(description: "arithmetic routing type") }
        try check(arithmetic.value == "14" && arithmetic.category == .calculation, "arithmetic routing")
        guard case .answer(let units)? = app.searchResults("10 km in miles").first else { throw Failure(description: "unit routing type") }
        try check(units.value.hasSuffix(" mi") && units.category == .conversion, "unit routing")

        for query in ["the thing about robots", "robotics party"] {
            let options = app.searchResults(query)
            try check(options.map(\.id) == ["runtime.search.google", "runtime.search.drive", "runtime.search.laptop"], "three search options for \(query)")
            let actions = options.compactMap { item -> LauncherAction? in
                guard case .action(let action) = item else { return nil }
                return action
            }
            try check(actions[0].target == "https://www.google.com/search?q=\(ActionEngine.percentEncode(query))", "Google retains whole query")
            try check(actions[1].target == "https://drive.google.com/drive/u/0/search?q=\(ActionEngine.percentEncode(query))", "Drive retains whole query")
            try check(actions[2].target == query, "laptop retains whole query")
        }
        let encoded = app.router!.defaultSearches("robots & parties / café?")
        try check(encoded[0].target.hasSuffix("robots%20%26%20parties%20%2F%20caf%C3%A9%3F"), "search encoding")
        app.enterLaptopSearch("robotics party")
        try check(app.panelState.mode?.action.kind == .laptopSearch && app.field.stringValue == "robotics party", "laptop mode preserves phrase")
        let deadline = Date().addingTimeInterval(2)
        while app.panelState.items.isEmpty && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        try check(app.panelState.items.first?.id == "fixture.party", "asynchronous laptop result reaches table")
        let previousWork = app.queryWork
        app.dismissSearchOrHide()
        try check(app.panelState.mode == nil && app.panelState.items.count == 3 && previousWork?.isCancelled == true, "Escape returns to options and cancels stale search")
        try check(ActionRunner.sourceFolder(for: temporaryRoot.path) == temporaryRoot, "directory opens itself")
        try check(ActionRunner.sourceFolder(for: temporaryConfig.path) == temporaryConfig.deletingLastPathComponent(), "file opens containing folder")

        // Removing the configured action that owns query mode clears its stale chip and row.
        app.panelState.mode = QueryMode(action: syntheticActions[0], typedPrefix: "check")
        app.activeRevision = "with-search"
        app.acceptConfig(.success((LauncherConfig(version: 1, actions: [syntheticActions[1]]), "without-search")))
        try check(app.panelState.mode == nil, "config removal clears query mode")
        app.acceptConfig(.success((LauncherConfig(version: 1, actions: syntheticActions), "restored-search")))

        try checkClipboardControls(app: app, history: history, board: board)
        try checkStaleSuppressionState(app: app)
        try checkAliasSuggestions(app: app)
        try checkEmojiPicker(app: app, board: board)
        try checkDictations(app: app, board: board, root: temporaryRoot)
        try checkLarynxDashboard(app: app, board: board, root: temporaryRoot)

        print("PASS integration checks, including default searches and laptop mode; no general clipboard, file search, network, or Shortcuts used")
    }

    /// Stats offers an alias for an action typed the long way; ↵ writes it to the file and the offer goes away.
    private static func checkAliasSuggestions(app: AppDelegate) throws {
        let notes = LauncherAction(id: "check.notes", name: "Longform Notes", aliases: ["longform"], kind: .url, target: "https://example.invalid/notes")
        try LauncherConfig(version: 1, actions: syntheticActions + [notes]).canonicalJSON().write(to: app.configURL, options: .atomic)
        app.panelState.mode = nil
        app.reloadConfig()
        let now = Date()
        guard let synthetic = app.nativeActions.first(where: { $0.id == "check.application" }) else { throw Failure(description: "synthetic app present") }
        app.usageEvents = (0..<10).flatMap { index in
            [UsageEvent.action(notes, at: now.addingTimeInterval(Double(-index * 60)), keys: 8, ms: 900, via: .name),
             UsageEvent.action(synthetic, at: now.addingTimeInterval(Double(-index * 60)), keys: 12, ms: 900, via: .name)]
        }
        app.field.stringValue = "stats"
        app.refreshResults()
        let offers = app.panelState.items.compactMap { item -> AliasSuggestion? in
            guard case .suggestion(let suggestion) = item else { return nil }
            return suggestion
        }
        try check(offers.map(\.action.id) == ["check.notes"] && offers.first?.alias == "lo", "stats suggests lo for Longform Notes")
        try check(app.rows.contains(.header("Suggestions")), "suggestions sit under their own header")
        // The synthetic app has no bundle on disk, so there is no bundle ID to write.
        try check(!offers.contains { $0.action.id == "check.application" }, "an app without a readable bundle ID is not offered")
        app.acceptSuggestion(offers[0])
        try check(app.footer.message?.hasPrefix("Added lo for Longform Notes") == true, "the footer confirms the alias")
        let written = try ConfigStore(url: app.configURL).load()
        try check(written.actions.first { $0.id == "check.notes" }?.aliases == ["longform", "lo"], "Return writes the alias to actions.json")
        let rollback = app.configURL.deletingPathExtension().appendingPathExtension("previous.json")
        try check((try? ConfigStore.validate(url: rollback))?.actions.last?.aliases == ["longform"], "the file before the alias is the rollback point")
        try check(app.searchResults("lo").first?.id == "check.notes", "the new alias works at once")
        app.field.stringValue = "stats"
        app.refreshResults()
        try check(!app.panelState.items.contains { if case .suggestion = $0 { return true }; return false }, "an accepted suggestion goes away")
        app.field.stringValue = ""
        app.usageEvents = []
        try LauncherConfig(version: 1, actions: syntheticActions).canonicalJSON().write(to: app.configURL, options: .atomic)
        app.reloadConfig()
    }

    /// Control-Space opens the grid; typing filters it; arrows move; ↵ copies, logs the pick, closes, and asks for a paste.
    private static func checkEmojiPicker(app: AppDelegate, board: NSPasteboard) throws {
        app.panelState.mode = nil
        app.usageEvents = []
        app.refreshRanking()
        app.emojiSeed = ["🦾", "🤖", "👀"]
        try check(app.searchResults("emoji").first?.id == AppDelegate.emojiPicker.id, "emoji is a launcher command")
        app.toggleEmoji()
        try check(app.panel.isVisible && app.inEmojiMode, "Control-Space opens the picker")
        try check(app.rows.first == .header("Frequently used"), "frequently used comes first")
        try check(app.selectedEmoji?.symbol == "🦾", "the imported favorite is selected")
        try check(app.moveEmoji(1) && app.selectedEmoji?.symbol == "🤖", "right moves along the line")
        try check(app.moveEmoji(-1) && app.selectedEmoji?.symbol == "🦾", "left moves back")
        app.field.stringValue = "fire"
        app.refreshResults()
        try check(app.selectedEmoji?.symbol == "🔥" && app.panelState.emojiColumn == 0, "typing filters and starts at the best match")
        try check(app.statusLabel.attributedStringValue.string.lowercased().contains("fire"), "the status label names the emoji")
        var pasted = 0
        app.pasteOverride = { pasted += 1; return true }
        defer { app.pasteOverride = nil }
        app.executeSelected()
        try check(board.string(forType: .string) == "🔥", "Return copies the emoji")
        try check(!app.panel.isVisible, "Return closes the picker")
        try check(app.usageEvents.last?.id == "emoji.🔥" && app.usageEvents.last?.kind == .emoji, "the pick is logged")
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        try check(pasted == 1, "Return asks for one paste")
        app.toggleEmoji()
        try check(app.selectedEmoji?.symbol == "🔥", "a pick today outranks the imported list")
        app.field.stringValue = "zzqxv"
        app.refreshResults()
        try check(app.panelState.items.isEmpty && app.footer.message?.hasPrefix("No emoji found") == true, "no match says so")
        app.toggleEmoji()
        try check(!app.panel.isVisible, "Control-Space again closes the picker")
        app.field.stringValue = ""
        app.emojiSeed = []
        app.usageEvents = []
        app.refreshRanking()
    }

    private static let syntheticActions = [
        LauncherAction(
            id: "check.search",
            name: "Synthetic Search",
            aliases: ["check"],
            kind: .url,
            target: "https://example.invalid/?q={query}",
            browser: "com.example.browser"
        ),
        LauncherAction(
            id: "check.exact",
            name: "Exact Calculator-Like Alias",
            aliases: ["2+2"],
            kind: .url,
            target: "https://example.invalid/exact",
            browser: "com.example.browser"
        ),
    ]

    private static func checkClipboardControls(
        app: AppDelegate,
        history: ClipboardHistory,
        board: NSPasteboard
    ) throws {
        let disabled = app.searchResults("clipboard")
        try check(disabled.contains(.control(.enableClipboard)), "clipboard enable control")
        try check(disabled.contains(.control(.clearClipboard)), "clipboard clear control")
        try check(!disabled.contains(.control(.pauseClipboard)), "pause hidden while disabled")

        history.setEnabled(true)
        board.clearContents()
        board.setString("isolated integration value", forType: .string)
        history.tick(frontmostBundleID: nil)
        let enabled = app.searchResults("clip integration")
        guard case .clipboard = enabled.first else { throw Failure(description: "clipboard search routing") }
        try check(enabled.contains(.control(.pauseClipboard)), "clipboard pause control")
        try check(!enabled.contains(.control(.enableClipboard)), "enable hidden while active")

        let copiedText = "isolated executeNative copy"
        app.panelState.items = [.clipboard(id: "runtime.clipboard.integration", text: copiedText)]
        app.panelState.mode = nil
        app.panelState.presentedQueryKey = nil
        app.presentResults()
        app.executeSelected()
        try check(board.string(forType: .string) == copiedText, "native copy uses injected pasteboard")
        try check(app.lastActionOutcome == "copied", "native copy outcome")

        guard case .answer(let errorAnswer)? = app.searchResults("1 / 0").first else {
            throw Failure(description: "calculation error answer type")
        }
        try check(errorAnswer.isError, "calculation error is display-only")
        app.panelState.items = [.answer(errorAnswer)]
        app.panelState.presentedQueryKey = nil
        app.presentResults()
        let beforeErrorCopy = board.string(forType: .string)
        let beforeErrorUsage = app.usageEvents.count
        app.executeSelected()
        try check(board.string(forType: .string) == beforeErrorCopy && app.usageEvents.count == beforeErrorUsage,
                  "error answer cannot execute, copy, or log usage")

        let conversion = LauncherAnswer(id: "runtime.calculation", value: "6.21371192237 mi", detail: "10 km → 6.21371192237 mi", isError: false, category: .conversion)
        app.panelState.items = [.answer(conversion)]
        app.panelState.presentedQueryKey = nil
        app.presentResults()
        app.executeSelected()
        try check(board.string(forType: .string) == "6.21 mi", "Return copies the rounded answer")
        app.panelState.items = [.answer(conversion)]
        app.panelState.mode = nil
        app.panelState.presentedQueryKey = nil
        app.presentResults()
        app.copyFullPrecision()
        try check(board.string(forType: .string) == "6.21371192237 mi", "Option-Return copies full precision")
        try check(app.lastActionOutcome == "copied-full", "full precision outcome")

        // Usage: a finished action is logged; search words never are.
        let loggedBefore = app.usageEvents.count
        app.field.stringValue = "10 km in miles"
        app.copyFullPrecision()
        try check(app.usageEvents.count == loggedBefore + 1, "finished action logged")
        try check(app.usageEvents.last?.id == "calculation" && app.usageEvents.last?.keys == 14, "calculation logged by kind with its keys")
        let lofi = LauncherAction(id: "check.youtube", name: "YouTube Search", aliases: ["y"], kind: .url, target: "https://www.youtube.com/results?search_query={query}")
        app.panelState.mode = QueryMode(action: lofi, typedPrefix: "y")
        app.field.stringValue = "lofi beats"
        app.finish(ResolvedAction(actionID: "check.youtube", kind: .url, value: "x"), .init(status: "opened", hides: true),
                   Execution(invocation: app.panelState.invocation, usage: app.usageEvent(for: lofi)))
        let lofiEvent = app.usageEvents.last
        try check(lofiEvent?.id == "check.youtube" && lofiEvent?.keys == 2 && lofiEvent?.via == .alias, "query mode logs the alias keys only")
        app.finish(ResolvedAction(actionID: "check.youtube", kind: .url, value: "x"), .init(status: "open-failed", message: "x"),
                   Execution(invocation: app.panelState.invocation, usage: app.usageEvent(for: lofi)))
        try check(app.usageEvents.last == lofiEvent, "failed actions are not logged")
        // Two runs in flight: each logs its own record, in the order they finish.
        let slow = Execution(invocation: app.panelState.invocation, usage: app.usageEvent(for: lofi))
        let syntheticApp = app.nativeActions[0]
        let fast = Execution(invocation: app.panelState.invocation, usage: app.usageEvent(for: syntheticApp))
        app.finish(ResolvedAction(actionID: syntheticApp.id, kind: .application, value: "x"), .init(status: "opened", hides: true), fast)
        app.finish(ResolvedAction(actionID: "check.youtube", kind: .url, value: "x"), .init(status: "opened", hides: true), slow)
        try check(app.usageEvents.suffix(2).map(\.id) == [syntheticApp.id, "check.youtube"], "overlapping runs keep their own usage records")
        // A run from an earlier panel session logs its use but leaves the new panel alone.
        app.show()
        let stale = Execution(invocation: app.panelState.invocation, usage: app.usageEvent(for: syntheticApp))
        app.show()
        let countBeforeStale = app.usageEvents.filter { $0.ev == .action }.count
        app.finish(ResolvedAction(actionID: syntheticApp.id, kind: .application, value: "x"), .init(status: "opened", message: "stale", hides: true), stale)
        try check(app.panel.isVisible && app.footer.message != "stale", "an old completion cannot hide or message a reopened panel")
        try check(app.usageEvents.filter { $0.ev == .action }.count == countBeforeStale + 1, "an old completion still logs its use")
        let usageBeforeStaleLoad = app.usageEvents
        app.usageLoadGeneration += 1
        app.acceptLoadedUsage([.open(at: Date.distantPast)], generation: app.usageLoadGeneration - 1)
        try check(app.usageEvents == usageBeforeStaleLoad, "a pre-reset usage load cannot restore cleared history")
        // Stats labels never leak into the blank screen.
        app.field.stringValue = "stats"
        app.refreshResults()
        guard case .stats = app.panelState.presentation else { throw Failure(description: "stats screen sets its counts") }
        app.show()
        guard case .standard = app.panelState.presentation else { throw Failure(description: "stats presentation cleared") }
        try check(!app.rows.contains(.header("Most used")), "reopening after stats shows plain destinations")
        // A refresh of the same query keeps the selection; a new query starts at the top.
        app.field.stringValue = "1p"
        app.refreshResults()
        let second = app.rows.indices.filter(app.isSelectable)[1]
        app.table.selectRowIndexes(IndexSet(integer: second), byExtendingSelection: false)
        let chosen = app.selectedAction?.id
        let inserted = LauncherAction(id: "check.inserted", name: "Inserted", aliases: [], kind: .application, target: "/private/tmp/Inserted.app")
        app.panelState.items.insert(.action(inserted), at: 0)
        app.presentResults()
        try check(app.selectedAction?.id == chosen, "same-query insertion keeps the selected identity")
        app.field.stringValue = "empty-transition"
        app.panelState.items = []
        app.presentResults()
        try check(app.panelState.selectedID == nil, "a new empty query clears the old selection")
        let oldChoice = app.nativeActions.first { $0.id == chosen } ?? inserted
        app.panelState.items = [.action(inserted), .action(oldChoice)]
        app.presentResults()
        try check(app.selectedAction?.id == inserted.id, "results after a new empty query select their top item")
        app.field.stringValue = "saf"
        app.refreshResults()
        try check(app.selectedAction?.id == "check.safari", "a new query selects the top result")
        app.field.stringValue = ""
        app.hide()
        app.panelState.mode = nil
        let logged = app.usageLog.load()
        try check(logged.count >= 2, "usage reaches the log file")
        let raw = try FileManager.default.contentsOfDirectory(at: app.usageLog.directory, includingPropertiesForKeys: nil)
            .map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        try check(!raw.contains("lofi") && !raw.contains("miles"), "search words never reach the log")
        try checkUsageLoadBoundaries(app: app)
        let statsRows = app.searchResults("stats")
        guard case .stats = statsRows.first, case .stats = app.panelState.presentation else { throw Failure(description: "stats shows its card first") }
        try check(app.searchResults("stats reset").first == .control(.resetStats), "stats reset row")
        guard case .standard = app.panelState.presentation else { throw Failure(description: "stats reset clears stats presentation") }

        // Theme picker: preview, revert, apply and persist.
        app.field.stringValue = "theme"
        app.refreshResults()
        try check(app.panelState.items.count == 4 && app.panelState.items.allSatisfy { if case .theme = $0 { return true }; return false }, "theme picker rows")
        guard case .theme(let original) = app.panelState.presentation else { throw Failure(description: "picker remembers the original look") }
        try check(original == .standard, "picker remembers the original look")
        let glassRow = app.rows.firstIndex(of: .item(1))!
        app.table.selectRowIndexes(IndexSet(integer: glassRow), byExtendingSelection: false)
        try check(app.theme.id == "glass", "selection previews Glass")
        try check(app.panelState.selectedID == "runtime.theme.glass", "preview keeps the selected row")
        app.table.selectRowIndexes(IndexSet(integer: app.rows.firstIndex(of: .item(2))!), byExtendingSelection: false)
        try check(app.theme.id == "raycast" && app.theme.compact, "selection previews Raycast")
        try check(app.tableView(app.table, heightOfRow: app.rows.firstIndex(of: .item(0))!) == 40, "Raycast rows are one line")
        try check(FooterView.keyParts("⌘K") == ["⌘", "K"] && FooterView.keyParts("esc") == ["esc"] && FooterView.keyParts("⌘") == ["⌘"], "Raycast splits modifier keys")
        app.dismissSearchOrHide()
        try check(app.theme.id == "signal", "escape reverts the preview")
        guard case .standard = app.panelState.presentation else { throw Failure(description: "theme preview state cleared") }
        try check(!FileManager.default.fileExists(atPath: app.settingsURL.path), "preview never writes settings")
        app.field.stringValue = "theme"
        app.refreshResults()
        app.table.selectRowIndexes(IndexSet(integer: app.rows.firstIndex(of: .item(1))!), byExtendingSelection: false)
        app.executeSelected()
        try check(AppearanceSettings.load(from: app.settingsURL).theme == "glass", "Return saves the theme")
        app.field.stringValue = "theme"
        app.refreshResults()
        app.table.selectRowIndexes(IndexSet(integer: app.rows.firstIndex(of: .item(0))!), byExtendingSelection: false)
        app.field.stringValue = "saf"
        app.refreshResults()
        try check(app.theme.id == "glass", "typing away from the picker reverts to the saved theme")
        app.setTheme(.standard, persist: true)
        // A failed write must never say "saved".
        try FileManager.default.removeItem(at: app.settingsURL)
        try FileManager.default.createDirectory(at: app.settingsURL, withIntermediateDirectories: false)
        app.field.stringValue = "theme"
        app.refreshResults()
        app.table.selectRowIndexes(IndexSet(integer: app.rows.firstIndex(of: .item(1))!), byExtendingSelection: false)
        app.executeSelected()
        try check(app.footer.message?.hasPrefix("Could not save") == true, "failed theme save is reported, not announced as saved")
        try FileManager.default.removeItem(at: app.settingsURL)
        app.setTheme(.standard, persist: true)

        app.execute(.pauseClipboard)
        try check(!history.enabled, "native clipboard pause disabled history")

        app.execute(.clearClipboard)
        try check(history.entries.isEmpty, "native clipboard clear removed entries")
        try check(FileManager.default.fileExists(atPath: app.statusURL.path), "status written only to temporary runtime")
        try check(app.searchResults("clip integration").allSatisfy { if case .clipboard = $0 { return false }; return true }, "clipboard clear")
    }

    private static func checkUsageLoadBoundaries(app: AppDelegate) throws {
        try app.resetUsage()
        let historical = UsageEvent.action(syntheticActions[1], at: Date(), keys: 1, ms: 10, via: .alias)
        app.usageLog.append(historical)
        _ = app.usageLog.load() // Wait until the seed reaches disk.
        app.usageEvents = []
        app.loadUsage()
        _ = app.usageLog.load() // The read finished; its main-thread delivery is still queued.
        try app.resetUsage()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        try check(app.usageEvents.isEmpty && app.router?.usage.isEmpty == true, "reset rejects a queued startup load")

        // A storage failure after the startup boundary must not discard the in-memory open.
        try FileManager.default.createDirectory(at: app.usageLog.directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("blocks-directory".utf8).write(to: app.usageLog.directory)
        app.usageEvents = []
        app.loadUsage()
        app.recordOpen()
        _ = app.usageLog.load() // Wait for the failed append, then deliver the earlier read.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        try check(app.usageEvents.count == 1 && app.usageEvents.first?.ev == .open, "failed startup append stays in memory once")
        try app.resetUsage()
    }

    private static func checkStaleSuppressionState(app: AppDelegate) throws {
        let oldWork = DispatchWorkItem {}
        app.queryWork = oldWork
        let oldStarted = DispatchSemaphore(value: 0)
        let releaseOld = DispatchSemaphore(value: 0)
        app.laptopFileSearch = { query in
            if query == "old" {
                oldStarted.signal()
                _ = releaseOld.wait(timeout: .now() + 2)
            }
            return [LauncherAction(id: "fixture." + query, name: query, aliases: [], kind: .file, target: "/tmp/" + query)]
        }
        app.enterLaptopSearch("old")
        guard let staleWork = app.queryWork else { throw Failure(description: "old async search scheduled") }
        let staleFinished = LockedFlag()
        staleWork.notify(queue: .main) { staleFinished.set() }
        let startDeadline = Date().addingTimeInterval(2)
        var startObserved = false
        while !startObserved && Date() < startDeadline {
            startObserved = oldStarted.wait(timeout: .now()) == .success
            if startObserved { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        try check(startObserved, "old async provider started")
        try check(oldWork.isCancelled, "prior query cancellation")
        app.field.stringValue = "new"
        app.refreshResults()
        let newDeadline = Date().addingTimeInterval(2)
        while app.panelState.items.first?.id != "fixture.new" && Date() < newDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        try check(app.panelState.items.first?.id == "fixture.new", "new async result arrives")
        releaseOld.signal()
        let staleDeadline = Date().addingTimeInterval(2)
        while !staleFinished.value && Date() < staleDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        try check(staleFinished.value, "old async provider completed")
        try check(app.panelState.items.first?.id == "fixture.new", "late old result cannot replace the new result")
    }

    /// A Shortcut that outlives its limit keeps the one-at-a-time slot until it really exits,
    /// and reports exactly one outcome. A stand-in tool ignores the first stop request briefly.
    static func shortcutLifecycle(in folder: URL) throws {
        let tool = folder.appendingPathComponent("fake-shortcuts")
        try "#!/bin/sh\ntrap 'sleep 1; exit 143' TERM\nsleep 5 & wait\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let runner = ActionRunner()
        runner.shortcutsTool = tool
        runner.shortcutLimit = 1.5
        var outcomes: [ActionRunner.Outcome] = []
        runner.runShortcut("probe") { outcomes.append($0) }
        func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        // A new script's first run can be slow; wait for the timeout itself, not a fixed time.
        let timeoutDeadline = Date().addingTimeInterval(5)
        while outcomes.isEmpty && Date() < timeoutDeadline { spin(0.02) }
        try check(outcomes.map(\.status) == ["shortcut-timeout"], "timeout reports once")
        try check(runner.runningShortcut != nil && runner.shortcutStopping, "the slot stays held while the Shortcut stops")
        let deadline = Date().addingTimeInterval(4)
        while runner.runningShortcut != nil && Date() < deadline { spin(0.05) }
        try check(runner.runningShortcut == nil && !runner.shortcutStopping, "the slot frees when the process exits")
        try check(outcomes.count == 1, "the exit after a timeout adds no second outcome")
    }

    /// True for rows that only Larynx commands show.
    private static func isLarynxItem(_ item: PanelItem) -> Bool {
        switch item {
        case .dictation, .larynx, .notice: return true
        default: return false
        }
    }

    /// `lx` on a fixture history: rows, filter, ↵ and ⌥↵ copies, a usage line without text, and ordinary search when the file is missing.
    private static func checkDictations(app: AppDelegate, board: NSPasteboard, root: URL) throws {
        let url = root.appendingPathComponent("larynx-history.db")
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else { throw Failure(description: "dictation fixture") }
        defer { sqlite3_close(db) }
        var sql = """
            PRAGMA journal_mode=WAL;
            CREATE TABLE dictations(id TEXT PRIMARY KEY, created_at REAL NOT NULL, text_raw TEXT NOT NULL, text_final TEXT NOT NULL,
              style TEXT NOT NULL, model TEXT NOT NULL, cleanup TEXT NOT NULL, duration_s REAL NOT NULL, landed TEXT NOT NULL,
              transcribe_ms REAL, clean_ms REAL);
            CREATE INDEX dictations_created ON dictations(created_at);
            BEGIN;
            """
        // 3,000 rows: a heavy month. Two known rows sit on top.
        let now = Date().timeIntervalSince1970
        for index in 0..<3_000 {
            sql += "INSERT INTO dictations VALUES('n\(index)', \(now - 600 - Double(index) * 60), 'filler raw \(index)', 'Filler dictation number \(index) about the weekly plan', 'plain', 'm', 'none', 2, 'clipboard', NULL, NULL);"
        }
        sql += """
            INSERT INTO dictations VALUES('old', \(now - 300), 'launch demo raw um', 'Launch demo\nsecond line', 'plain', 'm', 'none', 2, 'clipboard', NULL, NULL);
            INSERT INTO dictations VALUES('new', \(now - 30), 'integration raw', 'Integration final text', 'plain', 'm', 'none', 2, 'clipboard', NULL, NULL);
            COMMIT;
            """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure(description: "dictation fixture rows") }

        let saved = app.dictations
        defer { app.dictations = saved }
        app.dictations = DictationHistory(path: url)
        let listed = app.searchResults("lx")
        try check(listed.count == DictationHistory.limit, "lx shows at most 50 rows")
        guard case .dictation(let newest)? = listed.first else { throw Failure(description: "lx row type") }
        try check(newest.id == "new", "lx is newest first")
        let filtered = app.searchResults("larynx LAUNCH demo")
        guard filtered.count == 1, case .dictation(let match) = filtered[0] else { throw Failure(description: "lx filter") }
        try check(match.id == "old", "lx filter finds the match")

        // Timing: the query the panel runs on each keystroke.
        var samples: [Double] = []
        for input in Array(repeating: ["lx", "lx weekly plan", "lx zzz"], count: 100).joined() {
            let start = PerformanceMetrics.now()
            _ = app.searchResults(input)
            samples.append(Double(PerformanceMetrics.now() - start) / 1_000_000)
        }
        samples.sort()
        let median = samples[samples.count / 2], p95 = samples[samples.count * 95 / 100]
        try check(p95 < 25, "lx query stays well under the search budget")

        let copiedBefore = app.usageEvents.count
        app.panelState.mode = nil
        app.panelState.items = [.dictation(match)]
        app.panelState.presentedQueryKey = nil
        app.presentResults()
        app.field.stringValue = "lx launch demo"
        app.executeSelected()
        try check(board.string(forType: .string) == "Launch demo\nsecond line", "↵ copies the full final text")
        try check(app.lastActionOutcome == "copied", "dictation copy outcome")
        try check(app.usageEvents.count == copiedBefore + 1, "one usage line per copy")
        let line = String(decoding: try JSONEncoder().encode(app.usageEvents.last!), as: UTF8.self)
        try check(app.usageEvents.last?.id == "dictation" && app.usageEvents.last?.kind == .dictation, "usage logs the kind")
        try check(!line.lowercased().contains("launch demo") && !line.contains("second line"), "usage line holds no dictation text")

        app.panelState.items = [.dictation(match)]
        app.panelState.presentedQueryKey = nil
        app.presentResults()
        app.copyAlternate()
        try check(board.string(forType: .string) == "launch demo raw um", "⌥↵ copies the raw text")

        app.dictations = DictationHistory(path: root.appendingPathComponent("no-larynx/history.db"))
        let missing = app.searchResults("lx")
        try check(!missing.contains(where: isLarynxItem), "without Larynx, lx is an ordinary search")
        try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("no-larynx").path), "missing history is not created")
        print(String(format: "PASS lx dictations: 3,002-row fixture, query median %.3f ms, p95 %.3f ms", median, p95))
    }

    /// `larynx` on fixture histories: one card, its numbers, a notice for old files, ordinary search when missing, a harmless ↵, bytes unchanged.
    private static func checkLarynxDashboard(app: AppDelegate, board: NSPasteboard, root: URL) throws {
        let saved = app.dictations
        defer { app.dictations = saved }
        let url = try LarynxFixture.full.write()
        let before = try Data(contentsOf: url)
        app.dictations = DictationHistory(path: url)
        let items = app.searchResults("larynx")
        guard items.count == 1, case .larynx(let stats) = items[0] else { throw Failure(description: "larynx shows one dashboard card") }
        try check(stats.daily.count == 28 && stats.daily[18] == 0 && stats.daily.last == 640, "28-day strip with a gap, today last")
        try check(stats.currentStreak == 9 && stats.longestStreak == 14, "streaks")
        try check(stats.apps.count == 5 && stats.apps.last?.name == .other, "top four apps and Other")
        try check(AppNames.label(stats.apps[0]) != "com.anthropic.claudefordesktop" || NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") == nil,
                  "installed apps show their name")
        try check(AppNames.name("com.example.not-installed") == "com.example.not-installed", "an unknown ID shows itself")
        let list = app.searchResults("lx")
        guard case .dictation? = list.first else { throw Failure(description: "lx still lists dictations") }

        // The card is not selectable; ↵ copies nothing and logs nothing.
        let pasteBefore = board.string(forType: .string)
        let eventsBefore = app.usageEvents.count
        app.field.stringValue = "larynx"
        app.refreshResults()
        try check(app.selectedItem == nil && app.currentHints().map(\.key) == ["lx", "esc"], "card hints, nothing selected")
        app.executeSelected()
        try check(board.string(forType: .string) == pasteBefore && app.usageEvents.count == eventsBefore, "↵ on the card does nothing")
        try check(LarynxCardView.height(for: stats) + 4 <= AppDelegate.maxListHeight, "the card fits the list without scrolling")

        var samples: [Double] = []
        for _ in 0..<200 {
            let start = PerformanceMetrics.now()
            _ = app.searchResults("larynx")
            samples.append(Double(PerformanceMetrics.now() - start) / 1_000_000)
        }
        samples.sort()
        let median = samples[samples.count / 2], p95 = samples[samples.count * 95 / 100]
        try check(p95 < 25, "larynx query stays well under the search budget")
        let after = try Data(contentsOf: url)
        try check(after == before, "dashboard reads leave the file unchanged")

        for fixture in [LarynxFixture.empty, .today, .huge, .unknown] {
            app.dictations = DictationHistory(path: try fixture.write())
            guard case .larynx(let value)? = app.searchResults("larynx").first else { throw Failure(description: "larynx \(fixture) card") }
            try check(LarynxCardView.height(for: value) + 4 <= AppDelegate.maxListHeight, "\(fixture) fits")
        }
        app.dictations = DictationHistory(path: try LarynxFixture.old.write())
        try check(app.searchResults("larynx") == [.notice("No Larynx stats yet")], "an older history shows one notice")
        app.dictations = DictationHistory(path: root.appendingPathComponent("no-larynx-2/history.db"))
        try check(!app.searchResults("larynx").contains(where: isLarynxItem), "without Larynx, larynx is an ordinary search")
        try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("no-larynx-2").path), "missing history is not created")
        print(String(format: "PASS larynx dashboard: fixtures full/empty/today/huge/unknown/old, query median %.3f ms, p95 %.3f ms", median, p95))
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else { throw Failure(description: label) }
    }
}
