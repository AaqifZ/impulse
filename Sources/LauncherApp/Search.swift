import AppKit
import LauncherCore

/// From typed text to results: routing, catalog refresh, and the slower file and currency search.
extension AppDelegate {
    func controlTextDidChange(_ obj: Notification) { refreshResults() }

    func refreshResults() {
        let started = PerformanceMetrics.now()
        defer { performance.record(.resultsHandler, since: started) }
        guard panel != nil else { return }
        panelState.queryGeneration += 1
        queryWork?.cancel()
        if case .theme = panelState.presentation,
           panelState.mode != nil || !QueryRouter.themeWords.contains(field.stringValue.trimmingCharacters(in: .whitespaces).lowercased()) {
            revertThemePreview()
        }
        if let mode = panelState.mode?.action {
            setPlaceholder("Search \(DisplayFormat.modeName(mode.name, aliases: mode.aliases))…")
            panelState.items = mode.kind == .emoji ? emojiItems(field.stringValue) : (mode.kind == .laptopSearch ? [] : [.action(mode)])
            panelState.presentation = .standard(favoriteCount: 0)
        } else {
            setPlaceholder("Where to?")
            if field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let favorites = ["y", "g", "maps", "gcal", "slack", "gm"]
                let top = favorites.compactMap { alias in actions.first { $0.hasAlias(alias) } }
                panelState.items = (top + actions.filter { action in !top.contains { $0.id == action.id } }).map(PanelItem.action)
                panelState.presentation = .standard(favoriteCount: top.count)
            } else {
                panelState.items = searchResults(field.stringValue)
            }
        }
        updateModeChip()
        presentResults()
        footer.latencyMilliseconds = Double(PerformanceMetrics.now() - started) / 1_000_000
        if panelState.mode?.action.kind == .laptopSearch { scheduleLaptopSearch(field.stringValue, generation: panelState.queryGeneration) }
        else if panelState.mode == nil { scheduleExtendedSearch(field.stringValue, generation: panelState.queryGeneration) }
    }

    func enterQueryMode() {
        guard panelState.mode == nil, case .action(let action)? = selectedItem else { return }
        // A web or laptop search row carries the search words, which are never logged.
        let typedPrefix = action.kind == .webSearch || action.kind == .laptopSearch ? "" : field.stringValue
        if action.kind == .laptopSearch { enterLaptopSearch(field.stringValue); return }
        if action.kind == .emoji { enterEmojiMode(); return }
        if action.kind == .webSearch {
            guard let configured = router?.configuredSearch(for: action) else { return }
            panelState.mode = QueryMode(action: configured, typedPrefix: typedPrefix)
            refreshResults()
            panel.makeFirstResponder(field)
            return
        }
        guard action.target.contains("{query}") else { return }
        panelState.mode = QueryMode(action: action, typedPrefix: typedPrefix)
        field.stringValue = ""
        refreshResults()
        panel.makeFirstResponder(field)
    }

    func rebuildRouter() {
        router = QueryRouter(configured: actions, discovered: nativeActions + [Self.emojiPicker])
        refreshRanking()
        iconProvider.preload(actions + nativeActions)
    }

    @objc func refreshCatalog() {
        guard !catalogRefreshing else { return }
        catalogRefreshing = true
        lastCatalogRefresh = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Captures can leave out this Mac's apps, system items, and Shortcuts.
            let isolated = StateCapture.directory != nil && ProcessInfo.processInfo.environment["IMPULSE_CAPTURE_NO_DISCOVERY"] == "1"
            let apps = isolated ? [] : Discovery.apps()
            let system = isolated ? [] : Discovery.systemActions()
            var shortcuts: [LauncherAction] = []
            var failure: String?
            if !isolated {
                do { shortcuts = try Discovery.shortcuts() }
                catch { failure = "Shortcuts unavailable. Open Apple's Shortcuts app and try refresh." }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.nativeActions = apps + system + shortcuts
                self.shortcutError = failure
                self.catalogRefreshing = false
                self.rebuildRouter()
                if self.panel.isVisible { self.refreshResults() }
                self.publishStatus()
            }
        }
    }

    func searchResults(_ input: String) -> [PanelItem] {
        switch router?.route(input, dictations: dictations.isAvailable) ?? .results([]) {
        case .results(let list):
            panelState.presentation = .standard(favoriteCount: 0)
            return list.map {
                switch $0 {
                case .action(let action): return .action(action)
                case .answer(let answer): return .answer(answer)
                }
            }
        case .clipboard(let term):
            panelState.presentation = .standard(favoriteCount: 0)
            var list = clipboard.matching(term).map { PanelItem.clipboard(id: "runtime.clipboard.\($0.id)", text: $0.text) }
            if !clipboard.enabled {
                list.insert(.control(.enableClipboard), at: 0)
            }
            list.append(.control(.clearClipboard))
            if clipboard.enabled { list.append(.control(.pauseClipboard)) }
            return list
        case .dictations(let term):
            panelState.presentation = .standard(favoriteCount: 0)
            return dictationItems(term)
        case .larynx:
            panelState.presentation = .standard(favoriteCount: 0)
            return larynxResults()
        case .shortcuts:
            panelState.presentation = .standard(favoriteCount: 0)
            let list = nativeActions.filter { $0.kind == .shortcut }
            return list.isEmpty ? [.control(.openShortcuts)] : list.map(PanelItem.action)
        case .system:
            panelState.presentation = .standard(favoriteCount: 0)
            return Discovery.systemActions().map(PanelItem.action)
        case .theme: return themeResults()
        case .stats: return statsResults()
        case .statsReset:
            panelState.presentation = .standard(favoriteCount: 0)
            return [.control(.resetStats)]
        }
    }

    /// Recent Larynx dictations, or one notice row when the history cannot be read.
    func dictationItems(_ term: String) -> [PanelItem] {
        do {
            let list = try dictations.recent(matching: term)
            if list.isEmpty { return [.notice(term.isEmpty ? "No Larynx dictations yet" : "No dictations match")] }
            return list.map(PanelItem.dictation)
        } catch let failure as DictationHistory.Failure {
            return [.notice(failure.description)]
        } catch {
            return [.notice("Larynx history is unreadable")]
        }
    }

    func enterLaptopSearch(_ query: String) {
        panelState.mode = QueryMode(
            action: LauncherAction(id: "runtime.search.laptop", name: "Files", aliases: [], kind: .laptopSearch, target: ""),
            typedPrefix: ""
        )
        field.stringValue = query
        refreshResults()
        panel.makeFirstResponder(field)
    }

    func scheduleLaptopSearch(_ input: String, generation: Int) {
        guard input.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else {
            footer.message = "Type at least 3 characters."
            return
        }
        footer.message = "Searching this Mac…"
        let search = laptopFileSearch
        let work = DispatchWorkItem { [weak self] in
            let files = search(input)
            DispatchQueue.main.async {
                guard let self, self.panelState.queryGeneration == generation,
                      self.panelState.mode?.action.kind == .laptopSearch, self.field.stringValue == input else { return }
                self.panelState.items = files.map(PanelItem.action)
                self.presentResults(message: files.isEmpty ? "No indexed matches. Try fewer words." : nil)
            }
        }
        queryWork = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    func scheduleExtendedSearch(_ input: String, generation: Int) {
        guard panelState.mode == nil,
              QueryRouter.wantsExtendedSearch(input, firstResult: panelState.items.first?.routedResult, dictations: dictations.isAvailable) else { return }
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = query.lowercased()
        let initial = panelState.items
        if initial.isEmpty { footer.message = "Searching…" }
        let cache = configURL.deletingLastPathComponent().appendingPathComponent("runtime/exchange-rates.json")
        let discovery = fileSearchRoot.map { Discovery(homeDirectory: $0) } ?? Discovery()
        let work = DispatchWorkItem { [weak self] in
            let currency = CurrencyConverter.convert(query, cacheURL: cache)
            let isDefaultSearch = initial.first?.id == "runtime.search.google"
            let files = currency == nil && !isDefaultSearch ? discovery.files(matching: lower.hasPrefix("files ") ? String(query.dropFirst(6)) : query, limit: 20) : []
            DispatchQueue.main.async {
                guard let self, self.panelState.queryGeneration == generation, self.panelState.mode == nil, self.field.stringValue == input else { return }
                if isDefaultSearch && currency == nil { return }
                if let currency {
                    self.panelState.items = [.answer(LauncherAnswer(
                        id: "runtime.currency",
                        value: currency.value,
                        detail: currency.detail,
                        isError: currency.isError,
                        category: .currency
                    ))]
                } else {
                    var seen = Set(initial.compactMap { item -> String? in
                        guard case .action(let action) = item else { return nil }
                        return action.target
                    })
                    self.panelState.items = initial + files.filter { seen.insert($0.target).inserted }.map(PanelItem.action)
                }
                self.presentResults(message: self.panelState.items.isEmpty ? "No indexed matches. Try files <name>, or g ⇥ for Google." : nil)
            }
        }
        queryWork = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.18, execute: work)
    }
}
