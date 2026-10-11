import AppKit
import LauncherCore

/// The panel: layout, theme, rows, footer, and keyboard handling.
extension AppDelegate {
    func setupPanel() {
        panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: Self.chromeHeight + Self.maxListHeight), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Impulse"
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.dismiss = { [weak self] in self?.dismissSearchOrHide() }
        panel.shortcut = { [weak self] event in
            guard let self, event.modifierFlags.contains(.command) else { return false }
            if event.keyCode == 16 { self.previewSelected(); return true }
            if event.keyCode == 36 { self.inEmojiMode ? self.pickEmoji(paste: false) : self.revealSelected(); return true }
            return false
        }
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // The window keeps its full height; the visible card inside it grows and shrinks.
        // Transparent pixels below the card pass clicks through and cast no shadow.
        let container = NSView()
        container.wantsLayer = true
        panel.contentView = container
        let root = card
        root.wantsLayer = true
        root.layer?.masksToBounds = true
        root.layer?.cornerCurve = .continuous
        root.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)
        cardHeight = root.heightAnchor.constraint(equalToConstant: Self.chromeHeight)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            cardHeight,
        ])

        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active

        field.font = .systemFont(ofSize: 26, weight: .regular)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.setAccessibilityLabel("Destination or search")
        field.setAccessibilityIdentifier("launcher-input")
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.alignment = .right
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action")))
        table.headerView = nil
        table.rowHeight = 51
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.floatsGroupRows = false
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(executeSelected)
        table.setAccessibilityLabel("Destinations")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        modeChip.wantsLayer = true
        modeChip.isHidden = true
        modeChipLabel.translatesAutoresizingMaskIntoConstraints = false
        modeChip.addSubview(modeChipLabel)
        fieldLeadingToCard = field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24)
        fieldLeadingToChip = field.leadingAnchor.constraint(equalTo: modeChip.trailingAnchor, constant: 12)
        for view in [backdrop, modeChip, field, statusLabel, signalLine, scroll, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: root.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            modeChip.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            modeChip.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            modeChip.heightAnchor.constraint(equalToConstant: 26),
            modeChipLabel.leadingAnchor.constraint(equalTo: modeChip.leadingAnchor, constant: 9),
            modeChipLabel.trailingAnchor.constraint(equalTo: modeChip.trailingAnchor, constant: -9),
            modeChipLabel.centerYAnchor.constraint(equalTo: modeChip.centerYAnchor),
            fieldLeadingToCard,
            field.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            field.heightAnchor.constraint(equalToConstant: 34),
            field.trailingAnchor.constraint(lessThanOrEqualTo: statusLabel.leadingAnchor, constant: -12),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            statusLabel.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            signalLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            signalLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            signalLine.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 16),
            signalLine.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: signalLine.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            // Fixed height: the table never re-tiles when the card resizes.
            scroll.heightAnchor.constraint(equalToConstant: Self.maxListHeight),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        applyTheme()
        panel.center()
    }

    /// Repaints the chrome with the current theme. Layout does not change.
    func applyTheme() {
        guard panel != nil else { return }
        let root = card
        root.layer?.cornerRadius = theme.radius
        root.layer?.backgroundColor = theme.panelFill.cgColor
        root.layer?.borderWidth = 1
        root.layer?.borderColor = theme.panelBorder.cgColor
        backdrop.isHidden = !theme.usesMaterial
        field.textColor = theme.text
        field.font = .systemFont(ofSize: theme.compact ? 20 : 26, weight: .regular)
        placeholderText = nil
        if let mode = panelState.mode?.action {
            setPlaceholder("Search \(DisplayFormat.modeName(mode.name, aliases: mode.aliases))…")
        } else {
            setPlaceholder("Where to?")
        }
        (field.currentEditor() as? NSTextView)?.insertionPointColor = theme.instrument ? theme.accent : .controlAccentColor
        signalLine.apply(theme)
        footer.apply(theme)
        updateModeChip()
        updateStatusLabel()
        table.reloadData()
        panel.invalidateShadow()
    }

    /// True when the look is live and, if asked, written to settings.json.
    @discardableResult
    func setTheme(_ settings: AppearanceSettings, persist: Bool) -> Bool {
        appearanceSettings = settings
        theme = Theme.make(settings)
        applyTheme()
        guard persist else { return true }
        do { try settings.save(to: settingsURL) } catch { return false }
        return true
    }

    /// Query mode shows the destination as a chip in front of the input ("YOUTUBE ▸").
    func updateModeChip() {
        guard let mode = panelState.mode?.action else {
            modeChip.isHidden = true
            fieldLeadingToChip.isActive = false
            fieldLeadingToCard.isActive = true
            return
        }
        let name = mode.kind == .laptopSearch ? "This Mac" : DisplayFormat.modeName(mode.name, aliases: mode.aliases)
        let label = NSMutableAttributedString()
        // The chip leads with the destination's logo when one is loaded.
        if let key = iconProvider.representedKey(for: mode), let logo = iconProvider.cachedImage(for: key), !logo.isTemplate {
            let attachment = NSTextAttachment()
            attachment.image = logo
            attachment.bounds = NSRect(x: 0, y: theme.instrument ? -3 : -2, width: 14, height: 14)
            label.append(NSAttributedString(attachment: attachment))
            label.append(NSAttributedString(string: " "))
        }
        label.append(theme.instrument
            ? NSAttributedString(string: name.uppercased() + " ▸", attributes: [.font: theme.monoFont(12, .medium), .foregroundColor: theme.accentInk, .kern: 1])
            : NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: theme.text]))
        modeChipLabel.attributedStringValue = label
        modeChip.layer?.backgroundColor = (theme.instrument ? theme.accent : theme.chipFill).cgColor
        modeChip.layer?.cornerRadius = theme.instrument ? 5 : 9
        modeChip.isHidden = false
        fieldLeadingToCard.isActive = false
        fieldLeadingToChip.isActive = true
    }

    func setPlaceholder(_ text: String) {
        // The attributed placeholder clears placeholderString, so track the text separately.
        guard placeholderText != text else { return }
        placeholderText = text
        field.placeholderString = text
        field.placeholderAttributedString = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: theme.compact ? 20 : 26, weight: .regular),
            .foregroundColor: theme.compact ? theme.secondary.withAlphaComponent(0.65) : theme.secondary,
        ])
    }

    var selectedItem: PanelItem? {
        selectedResultIndex.map { panelState.items[$0] }
    }

    var selectedAction: LauncherAction? {
        guard case .action(let action)? = selectedItem else { return nil }
        return action
    }

    /// Single path for showing a new result list: table, selection, status label and footer.
    func presentResults(message: String? = nil) {
        // A background refresh of the same query keeps the user's choice; a new query starts at the top.
        let query = "\(panelState.mode?.action.id ?? "")\u{1F}\(field.stringValue)"
        let sameQuery = query == panelState.presentedQueryKey
        let kept = sameQuery ? panelState.selectedID : nil
        if !sameQuery { panelState.selectedID = nil; panelState.emojiColumn = 0 }
        panelState.presentedQueryKey = query
        presentingResults = true
        buildRows()
        table.reloadData()
        if let kept, let index = panelState.items.firstIndex(where: { $0.id == kept }),
           let row = rows.firstIndex(of: .item(index)), isSelectable(row) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            panelState.selectedID = kept
        } else {
            selectFirstItem()
        }
        presentingResults = false
        updateStatusLabel()
        refreshFooter()
        if let message, footer.message == nil { footer.message = message }
        resizeToFit()
    }

    static let chromeHeight: CGFloat = 22 + 34 + 16 + 1 + 6 + 6 + 42

    static let maxListHeight: CGFloat = 436

    /// Fits the card to its rows (at most about eight items). The window never resizes.
    func resizeToFit() {
        let spacing = table.intercellSpacing.height
        var list: CGFloat = 0
        for row in rows.indices { list += tableView(table, heightOfRow: row) + spacing }
        list = rows.isEmpty ? 0 : min(list + 4, Self.maxListHeight)
        let height = Self.chromeHeight + list
        guard abs(cardHeight.constant - height) > 0.5 else { return }
        cardHeight.constant = height
        // The shadow shape follows on the next pass, coalesced, outside the keystroke handler.
        guard !shadowPending else { return }
        shadowPending = true
        DispatchQueue.main.async { [weak self] in
            self?.shadowPending = false
            self?.panel.invalidateShadow()
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !presentingResults else { return }
        panelState.selectedID = selectedItem?.id
        previewSelectedTheme()
        refreshEmojiCells()
        refreshFooter()
    }

    /// Hints for the selected row, unless a persistent warning must stay visible.
    func refreshFooter() {
        footer.isWarning = false
        footer.setHints(currentHints())
        if configError != nil {
            footer.isWarning = true
            footer.message = "Config error. Using the last working version."
        } else if let hotkey, !hotkey.isRegistered {
            footer.isWarning = true
            footer.message = "Command–Space is unavailable. Open Impulse from the menu bar."
        } else if inEmojiMode, panelState.items.isEmpty {
            footer.message = "No emoji found. Try a simpler word."
        } else if panelState.items.isEmpty && panelState.mode == nil && !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            footer.message = "No destination found. Try g ⇥ for Google search."
        }
    }

    func currentHints() -> [(key: String, label: String)] {
        if panelState.mode?.action.kind == .laptopSearch { return [("↵", "Open folder"), ("⌘Y", "Preview"), ("esc", "Back")] }
        if inEmojiMode { return panelState.items.isEmpty ? [("esc", "Close")] : [("↵", "Paste"), ("⌘↵", "Copy"), ("esc", "Close")] }
        if panelState.mode != nil { return [("⌫", "Leave mode"), ("↵", "Search")] }
        guard let item = selectedItem ?? panelState.items.first else { return [] }
        switch item {
        case .action(let action): return action.kind.hints(for: action, instrument: theme.instrument)
        case .answer(let answer):
            if answer.isError { return [("esc", "Close")] }
            return DisplayFormat.rounded(answer.value) == answer.value ? [("↵", "Copy")] : [("↵", "Copy"), ("⌥↵", "Copy full")]
        case .clipboard: return [("↵", "Copy")]
        case .dictation: return [("↵", "Copy"), ("⌥↵", "Copy raw")]
        case .notice: return [("esc", "Close")]
        case .control: return [("↵", "Open")]
        case .theme(let option):
            if case .accent = option, theme.instrument { return [("←→", "Accent"), ("↵", "Apply"), ("esc", "Revert")] }
            return [("↑↓", "Preview"), ("↵", "Apply"), ("esc", "Revert")]
        case .stats: return [("esc", "Close")]
        case .larynx: return [("lx", "Dictations"), ("esc", "Close")]
        case .suggestion: return [("↵", "Add alias"), ("esc", "Close")]
        case .emojiRow: return [("↵", "Paste"), ("⌘↵", "Copy"), ("esc", "Close")]
        }
    }

    func updateStatusLabel() {
        let text: String
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        if inEmojiMode {
            text = selectedEmoji?.name ?? ""
        } else if panelState.mode != nil || query.isEmpty {
            text = ""
        } else if case .theme = panelState.presentation {
            text = "Appearance"
        } else if case .stats(let stats)? = panelState.items.first {
            text = "Last \(stats.days) days"
        } else if case .larynx? = panelState.items.first {
            text = "Last \(LarynxStats.days) days"
        } else if case .answer(let answer)? = panelState.items.first {
            switch answer.category {
            case .currency: text = "Currency"
            case .conversion: text = "Conversion"
            case .calculation: text = "Calculation"
            }
        } else {
            text = panelState.items.count == 1 ? "1 result" : "\(panelState.items.count) results"
        }
        statusLabel.attributedStringValue = theme.labelText(text, size: 11)
    }

    /// Groups results under headers in order of first appearance; the top hit stays first.
    func buildRows() {
        rows = []
        if inEmojiMode {
            // Grid lines sit under their group's header; search results have none.
            var current: String?
            for (index, item) in panelState.items.enumerated() {
                guard case .emojiRow(let line) = item else { continue }
                if line.section != current, !line.section.isEmpty { rows.append(.header(line.section)) }
                current = line.section
                rows.append(.item(index))
            }
            return
        }
        guard panelState.mode == nil else { rows = panelState.items.indices.map(DisplayRow.item); return }
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        var order: [String] = []
        var grouped: [String: [Int]] = [:]
        for index in panelState.items.indices {
            let section = section(for: panelState.items[index], at: index, query: query)
            if grouped[section] == nil { order.append(section) }
            grouped[section, default: []].append(index)
        }
        for section in order {
            if !section.isEmpty { rows.append(.header(section)) }
            rows += grouped[section, default: []].map(DisplayRow.item)
        }
    }

    func section(for item: PanelItem, at index: Int, query: String) -> String {
        switch item {
        case .answer, .stats, .larynx: return ""
        case .theme(let option):
            if case .accent = option { return theme.instrument ? "Signal accent" : "Accent" }
            return "Theme"
        case .suggestion: return "Suggestions"
        case .dictation, .notice: return "Larynx"
        default: break
        }
        if case .stats = panelState.presentation { return "Most used" }
        if query.isEmpty, case .standard(let favoriteCount) = panelState.presentation {
            return index < favoriteCount ? "Favorites" : "Destinations"
        }
        if index == 0 { return "Top hit" }
        switch item {
        case .action(let action): return action.kind.section(instrument: theme.instrument)
        case .clipboard: return "Clipboard"
        case .control: return "Commands"
        case .answer, .theme, .stats, .larynx, .suggestion, .emojiRow, .dictation, .notice: return ""
        }
    }

    var selectedResultIndex: Int? {
        guard rows.indices.contains(table.selectedRow), case .item(let index) = rows[table.selectedRow] else { return nil }
        return panelState.items.indices.contains(index) ? index : nil
    }

    /// Items are selectable; headers and the stats card are not.
    func isSelectable(_ row: Int) -> Bool {
        guard rows.indices.contains(row), case .item(let index) = rows[row], panelState.items.indices.contains(index) else { return false }
        switch panelState.items[index] {
        case .stats, .larynx: return false
        case .action, .answer, .clipboard, .dictation, .notice, .control, .theme, .suggestion, .emojiRow: return true
        }
    }

    func isHeader(_ row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func selectFirstItem() {
        guard let row = rows.indices.first(where: isSelectable) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if case .item(let index) = rows[row] { panelState.selectedID = panelState.items[index].id }
        // Scrolling forces synchronous row layout; only do it when the list is not at the top.
        if table.visibleRect.minY > 0 { table.scrollRowToVisible(0) }
    }

    /// NSTableView drops its reuse queue when the panel hides, so keep a small free-list.
    /// A row is free when its row view has left the table; detach it before reuse.
    func reusableRow(in tableView: NSTableView) -> ResultRowView {
        if let pooled = tableView.makeView(withIdentifier: ResultRowView.reuseIdentifier, owner: self) as? ResultRowView { return pooled }
        if let free = rowPool.first(where: { $0.superview == nil || $0.superview?.superview == nil }) {
            free.removeFromSuperview()
            return free
        }
        let row = ResultRowView(frame: .zero)
        if rowPool.count < 32 { rowPool.append(row) }
        return row
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return 50 }
        switch rows[row] {
        case .header: return 28
        case .item(let index):
            guard panelState.items.indices.contains(index) else { return 50 }
            switch panelState.items[index] {
            case .stats: return StatsCardView.height
            case .larynx(let stats): return LarynxCardView.height(for: stats)
            case .emojiRow: return 54
            case .answer: return 132
            default: return theme.compact ? 40 : 50
            }
        }
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard rows.indices.contains(row), case .header = rows[row] else { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        isSelectable(row)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(withIdentifier: ThemedRowView.reuseIdentifier, owner: self) as? ThemedRowView ?? ThemedRowView()
        view.identifier = ThemedRowView.reuseIdentifier
        view.theme = theme
        if rows.indices.contains(row), case .item(let index) = rows[row], panelState.items.indices.contains(index),
           case .emojiRow = panelState.items[index] { view.drawsSelection = false } else { view.drawsSelection = true }
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        if case .header(let title) = rows[row] {
            let header = tableView.makeView(withIdentifier: SectionHeaderView.reuseIdentifier, owner: self) as? SectionHeaderView ?? SectionHeaderView(frame: .zero)
            header.configure(title, theme: theme)
            return header
        }
        guard case .item(let index) = rows[row], panelState.items.indices.contains(index) else { return nil }
        let item = panelState.items[index]
        if case .emojiRow(let line) = item {
            let view = tableView.makeView(withIdentifier: EmojiRowView.reuseIdentifier, owner: self) as? EmojiRowView ?? EmojiRowView(frame: .zero)
            view.configure(line, selectedColumn: row == table.selectedRow ? panelState.emojiColumn : nil, theme: theme)
            // A click pastes that emoji, as ↵ would.
            view.onClick = { [weak self, weak tableView, weak view] column in
                guard let self, let tableView, let view else { return }
                let current = tableView.row(for: view)
                guard current >= 0 else { return }
                tableView.selectRowIndexes(IndexSet(integer: current), byExtendingSelection: false)
                self.panelState.emojiColumn = column
                self.pickEmoji(paste: true)
            }
            return view
        }
        if case .stats(let stats) = item {
            let card = tableView.makeView(withIdentifier: StatsCardView.reuseIdentifier, owner: self) as? StatsCardView ?? StatsCardView(frame: .zero)
            card.configure(stats, theme: theme)
            return card
        }
        if case .larynx(let stats) = item {
            let card = tableView.makeView(withIdentifier: LarynxCardView.reuseIdentifier, owner: self) as? LarynxCardView ?? LarynxCardView(frame: .zero)
            card.configure(stats, theme: theme)
            return card
        }
        if case .answer(let value) = item {
            let answer = tableView.makeView(withIdentifier: AnswerRowView.reuseIdentifier, owner: self) as? AnswerRowView ?? AnswerRowView(frame: .zero)
            answer.configure(value, theme: theme)
            return answer
        }
        let cell = reusableRow(in: tableView)
        if case .theme(let option) = item {
            let key = "theme:" + option.id
            let name: String
            switch option {
            case .look(_, let value), .accent(let value, _): name = value
            }
            cell.configure(name: name, aliases: [], detail: themeDetail(for: option), fallbackSymbol: "circle", iconKey: key,
                           theme: theme, trailing: themeNote(for: option), isKey: false)
            cell.applyLoadedIcon(themeSwatch(for: option), for: key)
            cell.setSelected(table.selectedRow == row)
            return cell
        }
        if case .clipboard(_, let text) = item {
            let title = String(text.replacingOccurrences(of: "\n", with: " ").prefix(90))
            cell.configure(name: title, aliases: [], detail: "Clipboard history · Enter to copy", fallbackSymbol: "doc.on.clipboard",
                           iconKey: nil, theme: theme, trailing: "", isKey: false)
            cell.setSelected(table.selectedRow == row)
            return cell
        }
        if case .dictation(let dictation) = item {
            let title = String(dictation.textFinal.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(200))
            cell.configure(name: title, aliases: [], detail: "Larynx · Enter to copy", fallbackSymbol: "waveform",
                           iconKey: nil, theme: theme, trailing: DictationHistory.relativeTime(dictation.createdAt), isKey: false)
            cell.setSelected(table.selectedRow == row)
            return cell
        }
        if case .notice(let text) = item {
            cell.configure(name: text, aliases: [], detail: "Larynx", fallbackSymbol: "waveform",
                           iconKey: nil, theme: theme, trailing: "", isKey: false)
            cell.setSelected(table.selectedRow == row)
            return cell
        }
        if case .control(let control) = item {
            let name = control == .openShortcuts ? (shortcutError ?? control.name) : control.name
            let symbol = control == .resetStats ? "trash" : (control == .openShortcuts ? "command" : "doc.on.clipboard")
            cell.configure(name: name, aliases: [], detail: "Impulse", fallbackSymbol: symbol, iconKey: nil,
                           theme: theme, trailing: "", isKey: false)
            cell.setSelected(table.selectedRow == row)
            return cell
        }
        if case .suggestion(let suggestion) = item {
            // The icon is the action that gains the alias; the keycap is what you will type.
            let target = suggestion.action
            let name = DisplayFormat.cleanName(target.name, aliases: target.aliases)
            let detail = "\(suggestion.uses) uses at \(String(format: "%.1f", suggestion.keysPerUse)) keys each · saves \(suggestion.keysSaved) keys in 28 days"
            cell.configure(name: "Add \(suggestion.alias) for \(name)", aliases: [], detail: detail, fallbackSymbol: target.kind.symbol(target: target.target),
                           iconKey: iconProvider.representedKey(for: target), theme: theme, trailing: suggestion.alias, isKey: true)
            cell.setSelected(table.selectedRow == row)
            applyIcon(of: target, to: cell)
            return cell
        }
        guard case .action(let action) = item else { return nil }
        // A web search row shows the logo of the site it searches.
        let iconAction = router?.configuredSearch(for: action) ?? action
        let representedKey = iconProvider.representedKey(for: iconAction)
        let note = trailingNote(for: action)
        cell.configure(
            name: action.name,
            aliases: action.aliases,
            detail: detail(for: action),
            fallbackSymbol: action.kind.symbol(target: action.target),
            iconKey: representedKey,
            theme: theme,
            trailing: note,
            isKey: note == nil,
            keepsNote: statsCount(for: action.id) != nil
        )
        cell.setSelected(table.selectedRow == row)
        applyIcon(of: iconAction, to: cell)
        return cell
    }

    /// The cached icon now, a file-type icon, or the real icon when it loads.
    func applyIcon(of action: LauncherAction, to cell: ResultRowView) {
        guard let key = iconProvider.representedKey(for: action) else { return }
        if let cached = iconProvider.cachedImage(for: key) {
            cell.applyLoadedIcon(cached, for: key)
        } else if action.kind == .file {
            cell.applyLoadedIcon(IconProvider.typeIcon(forPath: action.target), for: key)
        } else {
            iconProvider.loadIcon(for: action) { [weak cell] completedKey, image in
                guard let image else { return }
                cell?.applyLoadedIcon(image, for: completedKey)
            }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch NSStringFromSelector(commandSelector) {
        case "moveDown:": select(delta: 1); return true
        case "moveUp:": select(delta: -1); return true
        case "insertTab:": enterQueryMode(); return true
        case "insertNewline:": executeSelected(); return true
        case "insertNewlineIgnoringFieldEditor:": copyAlternate(); return true
        case "moveLeft:": return moveEmoji(-1) || cycleAccent(-1)
        case "moveRight:": return moveEmoji(1) || cycleAccent(1)
        case "cancelOperation:":
            dismissSearchOrHide()
            return true
        case "deleteBackward:":
            if panelState.mode != nil && field.stringValue.isEmpty { panelState.mode = nil; refreshResults(); return true }
            return false
        default: return false
        }
    }

    /// Moves between items and skips section headers.
    func select(delta: Int) {
        var row = table.selectedRow
        repeat {
            row += delta
            guard rows.indices.contains(row) else { return }
        } while !isSelectable(row)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(delta < 0 && row > 0 ? row - 1 : row)
    }

    func detail(for action: LauncherAction) -> String {
        switch action.kind {
        case .webSearch: return field.stringValue
        case .laptopSearch: return "Find related files and folders on this Mac"
        case .emoji: return "Emoji picker · also Control-Space"
        case .terminal: return "Terminal · runs in a new window"
        case .workspace: return "Workspace · new desktop"
        case .application, .app:
            let folder = (action.target as NSString).deletingLastPathComponent
            return folder.isEmpty ? "Application" : "Application · " + (folder as NSString).abbreviatingWithTildeInPath
        case .file: return (panelState.mode?.action.kind == .laptopSearch ? "Open source folder · " : "") + (action.target as NSString).abbreviatingWithTildeInPath
        case .calculation, .error: return "Calculation"
        case .clipboard: return "Clipboard history · Enter to copy"
        case .dictation: return "Larynx · Enter to copy"
        case .snippet: return "Snippet · copies text"
        case .shortcut: return "Shortcut · asks before it runs"
        case .local: return "Impulse"
        case .theme, .accent, .stats: return ""
        case .url, .system:
            let host = Self.displayHost(action.target)
            if action.target.contains("{query}") { return host.map { "Search · " + $0 } ?? "Search" }
            return host ?? "Open destination"
        }
    }

    static func displayHost(_ target: String) -> String? {
        guard let host = URL(string: target.replacingOccurrences(of: "{query}", with: ""))?.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Plain mono note in place of an alias keycap. Nil keeps the alias; "" shows nothing.
    func trailingNote(for action: LauncherAction) -> String? {
        // While `stats` is open, each row shows how often it was used.
        if let count = statsCount(for: action.id) { return count.formatted() }
        switch action.kind {
        case .application, .app, .shortcut, .webSearch, .laptopSearch, .emoji, .calculation, .error, .clipboard, .dictation, .local, .stats: return ""
        case .file:
            let values = try? URL(fileURLWithPath: action.target).resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            if values?.isDirectory == true { return "Folder" }
            guard let date = values?.contentModificationDate else { return "" }
            return Self.age(since: date)
        case .url, .terminal, .workspace, .snippet, .system, .theme, .accent: return nil
        }
    }

    func statsCount(for actionID: String) -> Int? {
        guard case .stats(let counts) = panelState.presentation else { return nil }
        return counts[actionID]
    }

    static func age(since date: Date, now: Date = Date()) -> String {
        let days = Int(now.timeIntervalSince(date) / 86_400)
        if Calendar.current.isDate(date, inSameDayAs: now) { return "Today" }
        if days < 7 { return "\(max(days, 1))d" }
        if days < 60 { return "\(days / 7)w" }
        if days < 365 { return "\(days / 30)mo" }
        return "\(days / 365)y"
    }
}
