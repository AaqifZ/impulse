import AppKit
import LauncherCore

/// Usage recording and the `stats` view. The log stays on this Mac, in config/runtime/usage/.
extension AppDelegate {
    /// Loads recent months in the background; events recorded meanwhile are kept.
    func loadUsage() {
        usageLoadGeneration += 1
        let generation = usageLoadGeneration
        usageLog.loadAsync { [weak self] loaded in
            self?.acceptLoadedUsage(loaded, generation: generation)
        }
    }

    func acceptLoadedUsage(_ loaded: [UsageEvent], generation: Int) {
        guard usageLoadGeneration == generation else { return }
        // The read was queued before this invocation recorded new events.
        usageEvents = loaded + usageEvents
        refreshRanking()
    }

    func recordOpen() {
        openedAt = PerformanceMetrics.now()
        remember(.open(at: Date()))
    }

    /// The usage record for the action chosen now, and how it was reached. `finish` logs it only if the run finishes.
    func usageEvent(for action: LauncherAction) -> UsageEvent {
        let text = field.stringValue
        let typed: String
        let keys: Int
        if let mode = panelState.mode, mode.action.kind != .laptopSearch {
            // Query mode: the keys before ⇥, plus ⇥. The search words never count.
            typed = mode.typedPrefix
            keys = mode.typedPrefix.count + 1
        } else if action.target.contains("{query}"), let first = text.split(separator: " ").first, text.contains(" "),
                  action.aliases.contains(where: { $0.caseInsensitiveCompare(first) == .orderedSame }) {
            // An inline search ("y cats"): the alias and the space.
            typed = String(first)
            keys = first.count + 1
        } else {
            typed = text
            keys = text.count
        }
        let ms = Int((PerformanceMetrics.now() - openedAt) / 1_000_000)
        return .action(action, at: Date(), keys: keys, ms: ms, via: UsageEvent.route(typed: typed, action: action))
    }

    func usageEvent(forTransientKind kind: ActionKind) -> UsageEvent {
        let keys = field.stringValue.count
        let ms = Int((PerformanceMetrics.now() - openedAt) / 1_000_000)
        return .transient(kind: kind, at: Date(), keys: keys, ms: ms, via: keys == 0 ? .list : .name)
    }

    /// The stats card, alias suggestions, then the most used actions that can still open.
    /// Suggestions come first so they are seen; with them, four rows fit the list without scrolling.
    func statsResults() -> [PanelItem] {
        var lengths: [String: Int] = [:]
        for action in actions where action.kind == .snippet { lengths[action.id] = action.target.count }
        let stats = UsageStats.compute(usageEvents, snippetLengths: lengths, topCount: 12)
        let list = LauncherConfig(version: 1, actions: actions).catalog(adding: nativeActions)
        let catalog = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let suggestions = aliasSuggestions(catalog: list)
        let top = stats.top.compactMap { entry in catalog[entry.id].map { ($0, entry.count) } }.prefix(suggestions.isEmpty ? 5 : 4 - suggestions.count)
        let counts = Dictionary(top.map { ($0.0.id, $0.1) }, uniquingKeysWith: { first, _ in first })
        panelState.presentation = .stats(counts: counts)
        return [.stats(stats)] + suggestions.map(PanelItem.suggestion) + top.map { .action($0.0) }
    }

    /// Up to two. A discovered app is offered only when its bundle ID can be read, since that is what the config stores.
    func aliasSuggestions(catalog: [LauncherAction]) -> [AliasSuggestion] {
        Array(AliasSuggester.suggest(usageEvents, catalog: catalog, limit: 6)
            .filter { $0.action.kind != .application || $0.action.configuredApp(alias: $0.alias) != nil }
            .prefix(2))
    }

    /// Writes the alias to actions.json under the config lock; the file as it was becomes the rollback point.
    /// A discovered app joins the config under its own ID, so its history carries over.
    func acceptSuggestion(_ suggestion: AliasSuggestion) {
        let target = suggestion.action
        let name = DisplayFormat.cleanName(target.name, aliases: target.aliases)
        do {
            let saved = try store.update {
                try $0.addingAlias(suggestion.alias, to: target.id, orAppending: target.configuredApp(alias: suggestion.alias))
            }
            acceptConfig(.success(saved))
        } catch {
            footer.message = "Could not add the alias. actions.json is unchanged."
            return
        }
        footer.message = "Added \(suggestion.alias) for \(name). Type \(suggestion.alias) next time."
    }

    /// Deleting the log cannot be undone, so it asks first.
    func confirmStatsReset() {
        let alert = NSAlert()
        alert.messageText = "Delete your usage history?"
        alert.informativeText = "This removes every stats record on this Mac. Stats start again from zero."
        alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do { try self.resetUsage() } catch {
                self.footer.message = "Could not delete the usage history. Check config/runtime/usage."
                return
            }
            self.footer.message = "Usage history deleted."
        }
    }

    func resetUsage() throws {
        try usageLog.reset()
        usageLoadGeneration += 1
        usageEvents = []
        refreshRanking()
    }

    func remember(_ event: UsageEvent) {
        usageEvents.append(event)
        // Two months is all the view reads; the file keeps everything.
        if usageEvents.count > 20_000 { usageEvents.removeFirst(usageEvents.count - 20_000) }
        usageLog.append(event)
        if event.ev == .action { refreshRanking() }
    }

    /// Feeds recent use to the search order.
    func refreshRanking() {
        router?.usage = UsageRanking.weights(usageEvents)
    }
}
