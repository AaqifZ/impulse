import AppKit
import LauncherCore

/// One line of the emoji grid. The table shows lines; the panel tracks the column.
struct EmojiRow: Equatable {
    static let columns = 8
    let id: String
    let section: String
    let emojis: [Emoji]
}

/// The emoji picker: Control-Space, or `emoji` in the launcher. ↵ pastes into the app you were in, ⌘↵ copies.
extension AppDelegate {
    static let emojiPicker = LauncherAction(id: "runtime.emoji", name: "Emoji", aliases: ["emoji"], kind: .emoji, target: "emoji")

    var inEmojiMode: Bool { panelState.mode?.action.kind == .emoji }

    /// Control-Space: opens the picker, or closes it when it is already open.
    func toggleEmoji() {
        if panel.isVisible && inEmojiMode { hide(); return }
        if !panel.isVisible { show() }
        enterEmojiMode()
    }

    func enterEmojiMode() {
        panelState.mode = QueryMode(action: Self.emojiPicker, typedPrefix: "")
        panelState.emojiColumn = 0
        field.stringValue = ""
        refreshResults()
        panel.makeFirstResponder(field)
    }

    /// No query: frequently used, then every group. A query: one list, best match first.
    func emojiItems(_ query: String) -> [PanelItem] {
        let used = EmojiCatalog.usage(from: router?.usage ?? [:])
        var sections: [(String, [Emoji])] = []
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            let frequent = EmojiCatalog.frequent(usage: used, seed: emojiSeed)
            if !frequent.isEmpty { sections.append(("Frequently used", frequent)) }
            for group in EmojiCatalog.groups { sections.append((group, EmojiCatalog.all.filter { $0.group == group })) }
        } else {
            sections.append(("", EmojiCatalog.search(query, usage: EmojiCatalog.combined(usage: used, seed: emojiSeed))))
        }
        var items: [PanelItem] = []
        for (number, (section, emojis)) in sections.enumerated() {
            for start in stride(from: 0, to: emojis.count, by: EmojiRow.columns) {
                let line = Array(emojis[start..<min(start + EmojiRow.columns, emojis.count)])
                items.append(.emojiRow(EmojiRow(id: "emoji.row.\(number).\(start)", section: section, emojis: line)))
            }
        }
        return items
    }

    var selectedEmoji: Emoji? {
        guard case .emojiRow(let row)? = selectedItem, !row.emojis.isEmpty else { return nil }
        return row.emojis[min(panelState.emojiColumn, row.emojis.count - 1)]
    }

    /// ←→ walk the grid and wrap to the next or previous line. False outside the picker.
    func moveEmoji(_ delta: Int) -> Bool {
        guard inEmojiMode, case .emojiRow(let row)? = selectedItem else { return false }
        let column = min(panelState.emojiColumn, row.emojis.count - 1) + delta
        if row.emojis.indices.contains(column) {
            panelState.emojiColumn = column
            refreshEmojiCells()
            return true
        }
        let before = table.selectedRow
        select(delta: delta)
        guard table.selectedRow != before, case .emojiRow(let next)? = selectedItem else { return true }
        panelState.emojiColumn = delta < 0 ? next.emojis.count - 1 : 0
        refreshEmojiCells()
        return true
    }

    /// Redraws the highlighted cell and names the emoji in the status label.
    func refreshEmojiCells() {
        guard inEmojiMode else { return }
        let visible = table.rows(in: table.visibleRect)
        for row in visible.location..<(visible.location + visible.length) {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? EmojiRowView)?
                .selectedColumn = row == table.selectedRow ? panelState.emojiColumn : nil
        }
        updateStatusLabel()
    }

    /// Copies the emoji and logs the pick. To paste, Hammerspoon presses ⌘V in the app that had focus;
    /// without Hammerspoon the emoji stays on the clipboard.
    func pickEmoji(paste: Bool) {
        guard let emoji = selectedEmoji else { return }
        guard clipboard.copy(emoji.symbol) else { footer.message = "Could not copy the emoji."; return }
        let keys = field.stringValue.count
        let ms = Int((PerformanceMetrics.now() - openedAt) / 1_000_000)
        let pick = LauncherAction(id: EmojiCatalog.usageID(emoji.symbol), name: emoji.name, aliases: [], kind: .emoji, target: emoji.symbol)
        remember(.action(pick, at: Date(), keys: keys, ms: ms, via: keys == 0 ? .list : .name))
        record(ResolvedAction(actionID: Self.emojiPicker.id, kind: .emoji, value: ""), outcome: paste ? "paste-requested" : "copied")
        hide()
        guard paste else { return }
        // Let the app that had focus take the keyboard back first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            _ = self.pasteOverride?() ?? self.runner.requestPaste()
        }
    }
}

/// Eight emoji in a line; the selected one sits on the theme's selection tile.
final class EmojiRowView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("launcher-emoji-row")
    private var emojis: [Emoji] = []
    private var theme = Theme.signal(accent: "volt")
    var onClick: ((Int) -> Void)?
    var selectedColumn: Int? { didSet { if selectedColumn != oldValue { needsDisplay = true } } }

    func configure(_ row: EmojiRow, selectedColumn: Int?, theme: Theme) {
        emojis = row.emojis
        self.theme = theme
        self.selectedColumn = selectedColumn
        identifier = Self.reuseIdentifier
        setAccessibilityLabel(row.emojis.map(\.name).joined(separator: ", "))
        needsDisplay = true
    }

    private var cellWidth: CGFloat { (bounds.width - 16) / CGFloat(EmojiRow.columns) }

    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30)]
        for (column, emoji) in emojis.enumerated() {
            let cell = NSRect(x: 8 + CGFloat(column) * cellWidth, y: 0, width: cellWidth, height: bounds.height).insetBy(dx: 3, dy: 3)
            if column == selectedColumn.map({ min($0, emojis.count - 1) }) {
                let path = NSBezierPath(roundedRect: cell, xRadius: theme.rowRadius, yRadius: theme.rowRadius)
                theme.selectionFill.setFill(); path.fill()
                (theme.instrument ? theme.accent : theme.selectionBorder).setStroke(); path.lineWidth = 1.5; path.stroke()
            }
            let glyph = NSAttributedString(string: emoji.symbol, attributes: attributes)
            let size = glyph.size()
            glyph.draw(at: NSPoint(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x - 8
        let column = Int(x / cellWidth)
        guard emojis.indices.contains(column) else { return }
        onClick?(column)
    }
}
