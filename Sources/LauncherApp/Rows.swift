import AppKit
import LauncherCore

/// The table shows section headers between items. `item` holds an index into `PanelState.items`.
enum DisplayRow: Equatable {
    case header(String)
    case item(Int)
}

/// Rounded selection drawn by the theme instead of the system highlight.
final class ThemedRowView: NSTableRowView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("launcher-row")
    var theme = Theme.signal(accent: "volt")
    /// False for emoji lines: the selected cell draws its own tile.
    var drawsSelection = true

    override var isSelected: Bool {
        didSet { subviews.compactMap { $0 as? ResultRowView }.forEach { $0.setSelected(isSelected) } }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard drawsSelection else { return }
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: theme.rowRadius, yRadius: theme.rowRadius)
        theme.selectionFill.setFill()
        path.fill()
        theme.selectionBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

final class SectionHeaderView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("launcher-section-header")
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ title: String, theme: Theme) {
        label.attributedStringValue = theme.labelText(title)
        setAccessibilityLabel(title)
    }
}

final class ResultRowView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("launcher-result-row")
    private static var symbols: [String: NSImage] = [:]

    let iconImageView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let tile = NSView()
    private let aliasKey = KeycapView("", theme: Theme.signal(accent: "volt"))
    private let enterKey = KeycapView("↵", theme: Theme.signal(accent: "volt"), emphasized: true)
    private let note = NSTextField(labelWithString: "")
    private(set) var representedIconKey: String?
    private var theme = Theme.signal(accent: "volt")
    private var trailingText = ""
    private var trailingIsKey = true
    private var tileVisible = true
    /// Keep the note beside ↵ when selected (use counts in `stats`).
    private var keepsNote = false
    private var selected = false

    // Frame layout (no constraints): rows are rebuilt on every keystroke.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.shadowOffset = .zero
        dot.layer?.shadowRadius = 4
        dot.layer?.shadowOpacity = 1
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 7
        tile.layer?.borderWidth = 1
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.lineBreakMode = .byTruncatingMiddle
        note.lineBreakMode = .byTruncatingTail
        for view in [dot, tile, iconImageView, titleLabel, detailLabel, aliasKey, enterKey, note] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let height = bounds.height
        dot.frame = NSRect(x: 10, y: (height - 6) / 2, width: 6, height: 6)
        tile.frame = NSRect(x: 26, y: (height - 28) / 2, width: 28, height: 28)
        let icon: CGFloat = tileVisible ? 16 : 28
        iconImageView.frame = NSRect(x: tile.frame.midX - icon / 2, y: tile.frame.midY - icon / 2, width: icon, height: icon)
        var right = bounds.width - 14
        // Right to left: the ↵ key, then an alias key or a note.
        for trailingView in [enterKey, aliasKey, note] as [NSView] where !trailingView.isHidden {
            let natural = trailingView === note
                ? ceil(note.attributedStringValue.size().width) + 8
                : (trailingView as? KeycapView)?.preferredWidth ?? 20
            let width = min(natural, 170)
            trailingView.frame = NSRect(x: right - width, y: (height - 20) / 2, width: width, height: 20)
            right -= width + 12
        }
        if theme.compact {
            // One line: a bare 20-point icon, the title, then the detail in grey.
            tile.frame = NSRect(x: 16, y: (height - 24) / 2, width: 24, height: 24)
            iconImageView.frame = NSRect(x: 18, y: (height - 20) / 2, width: 20, height: 20)
            let textX: CGFloat = 50
            let available = max(0, right - textX)
            let titleWidth = min(ceil(titleLabel.attributedStringValue.size().width) + 4, available)
            titleLabel.frame = NSRect(x: textX, y: (height - 18) / 2, width: titleWidth, height: 18)
            let detailX = textX + titleWidth + 8
            detailLabel.frame = NSRect(x: detailX, y: (height - 18) / 2, width: max(0, right - detailX), height: 18)
            return
        }
        let textX: CGFloat = 66
        let textWidth = max(0, right - textX)
        titleLabel.frame = NSRect(x: textX, y: height / 2 - 1, width: textWidth, height: 18)
        detailLabel.frame = NSRect(x: textX, y: height / 2 - 18, width: textWidth, height: 16)
    }

    /// `trailing` is an alias keycap (`isKey`) or a plain mono note such as a file age.
    func configure(
        name: String,
        aliases: [String],
        detail: String,
        fallbackSymbol: String,
        iconKey: String?,
        theme: Theme = Theme.signal(accent: "volt"),
        trailing text: String? = nil,
        isKey: Bool = true,
        keepsNote: Bool = false
    ) {
        self.theme = theme
        representedIconKey = iconKey
        titleLabel.stringValue = DisplayFormat.cleanName(name, aliases: aliases)
        detailLabel.stringValue = detail
        detailLabel.toolTip = detail
        detailLabel.textColor = theme.secondary
        titleLabel.font = .systemFont(ofSize: 14, weight: theme.compact ? .regular : .medium)
        detailLabel.font = .systemFont(ofSize: theme.compact ? 14 : 12)
        trailingText = text ?? (aliases.first ?? "")
        trailingIsKey = isKey
        self.keepsNote = keepsNote
        iconImageView.image = Self.symbol(fallbackSymbol)
        iconImageView.contentTintColor = theme.symbol
        showTile(true)
        tile.layer?.cornerRadius = theme.instrument ? 7 : 8
        setAccessibilityLabel("\(name), \(aliases.joined(separator: ", "))")
        render()
    }

    private static var darkness: [String: Bool] = [:]

    /// Average luminance of the opaque pixels, sampled once per icon at 8×8.
    static func isDark(_ image: NSImage, key: String) -> Bool {
        if let known = darkness[key] { return known }
        var dark = false
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: 8, height: 8))
            NSGraphicsContext.restoreGraphicsState()
            var total: CGFloat = 0, count: CGFloat = 0
            for x in 0..<8 { for y in 0..<8 {
                guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.5 else { continue }
                total += 0.299 * color.redComponent + 0.587 * color.greenComponent + 0.114 * color.blueComponent
                count += 1
            } }
            dark = count > 0 && total / count < 0.25
        }
        darkness[key] = dark
        return dark
    }

    private static func symbol(_ name: String) -> NSImage? {
        if let cached = symbols[name] { return cached }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        symbols[name] = image
        return image
    }

    @discardableResult
    func applyLoadedIcon(_ image: NSImage, for key: String) -> Bool {
        guard representedIconKey == key else { return false }
        iconImageView.image = image
        // A letter tile (template) takes the theme's symbol color; real icons keep theirs.
        iconImageView.contentTintColor = image.isTemplate ? theme.rowTitle : nil
        // App and file icons carry their own shape; website glyphs sit in a tile.
        showTile(key.hasPrefix("website:"))
        // A dark glyph (for example GitHub's) vanishes on a dark tile; give it a light one.
        if key.hasPrefix("website:"), theme.instrument, !image.isTemplate, Self.isDark(image, key: key) {
            tile.layer?.backgroundColor = NSColor(hex: 0xE6E9EC).cgColor
        }
        return true
    }

    func setSelected(_ value: Bool) {
        guard value != selected else { return }
        selected = value
        render()
    }

    private func showTile(_ visible: Bool) {
        tileVisible = visible
        tile.layer?.backgroundColor = (visible ? theme.tileFill : .clear).cgColor
        tile.layer?.borderColor = (visible ? theme.tileBorder : .clear).cgColor
        needsLayout = true
    }

    private func render() {
        titleLabel.textColor = selected ? theme.text : theme.rowTitle
        dot.isHidden = !(selected && theme.instrument)
        dot.layer?.backgroundColor = theme.accent.cgColor
        dot.layer?.shadowColor = theme.accent.cgColor
        // Raycast keeps the alias on the selected row and names Return in the footer instead.
        let showText = (!selected || theme.compact) && !trailingText.isEmpty
        enterKey.isHidden = !selected || theme.compact
        aliasKey.isHidden = !(showText && trailingIsKey)
        note.isHidden = !((showText || (selected && keepsNote && !trailingText.isEmpty)) && !trailingIsKey)
        if selected { enterKey.update("↵", theme: theme, emphasized: true) }
        if !aliasKey.isHidden { aliasKey.update(trailingText, theme: theme) }
        if !note.isHidden { note.attributedStringValue = theme.labelText(trailingText, size: 11) }
        needsLayout = true
    }
}

/// The answer to a calculation, conversion or currency query: one large value, then the working.
final class AnswerRowView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("launcher-answer-row")
    private let valueLabel = NSTextField(labelWithString: "")
    private let unitLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let copyKey = KeycapView("↵", theme: Theme.signal(accent: "volt"), emphasized: true)
    private let copyLabel = NSTextField(labelWithString: "")
    private let fullKey = KeycapView("⌥↵", theme: Theme.signal(accent: "volt"))
    private let fullLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        valueLabel.lineBreakMode = .byTruncatingTail
        detailLabel.lineBreakMode = .byTruncatingTail
        for view in [valueLabel, unitLabel, detailLabel, copyKey, copyLabel, fullKey, fullLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ answer: LauncherAnswer, theme: Theme) {
        let isError = answer.isError
        let shown = DisplayFormat.rounded(answer.value)
        let parts = DisplayFormat.valueAndUnit(shown)
        valueLabel.stringValue = isError ? "Error" : parts.value
        valueLabel.font = .systemFont(ofSize: isError ? 34 : 56, weight: .medium)
        valueLabel.textColor = isError ? theme.warning : theme.text
        unitLabel.attributedStringValue = theme.instrument
            ? NSAttributedString(string: parts.unit.uppercased(), attributes: [.font: theme.monoFont(20), .foregroundColor: theme.accent])
            : NSAttributedString(string: parts.unit, attributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: theme.secondary])
        unitLabel.isHidden = isError || parts.unit.isEmpty
        let detail = DisplayFormat.roundedAll(answer.detail)
        detailLabel.attributedStringValue = theme.instrument
            ? NSAttributedString(string: detail.uppercased(), attributes: [.font: theme.monoFont(11), .foregroundColor: theme.secondary, .kern: 0.4])
            : NSAttributedString(string: detail, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: theme.secondary])
        let canCopyFull = !isError && shown != answer.value
        copyKey.isHidden = isError
        copyLabel.isHidden = isError
        fullKey.isHidden = !canCopyFull
        fullLabel.isHidden = !canCopyFull
        copyKey.update("↵", theme: theme, emphasized: true)
        fullKey.update("⌥↵", theme: theme)
        copyLabel.attributedStringValue = theme.labelText("Copy " + shown, color: theme.instrument ? theme.accent : theme.text, size: 11)
        fullLabel.attributedStringValue = theme.labelText("Copy " + DisplayFormat.valueAndUnit(answer.value).value, color: theme.secondary, size: 11)
        setAccessibilityLabel("\(shown). \(detail)")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width, height = bounds.height
        // Right column: copy hints, right-aligned.
        let rightEdge = width - 14
        func place(_ key: KeycapView, _ label: NSTextField, y: CGFloat) -> CGFloat {
            let labelWidth = min(ceil(label.attributedStringValue.size().width) + 6, 200)
            label.frame = NSRect(x: rightEdge - labelWidth, y: y, width: labelWidth, height: 16)
            key.frame = NSRect(x: label.frame.minX - 8 - key.preferredWidth, y: y - 2, width: key.preferredWidth, height: 20)
            return key.frame.minX
        }
        var hintsLeft = rightEdge
        if !copyKey.isHidden { hintsLeft = min(hintsLeft, place(copyKey, copyLabel, y: height / 2 + 6)) }
        if !fullKey.isHidden { hintsLeft = min(hintsLeft, place(fullKey, fullLabel, y: height / 2 - 22)) }
        // Left column: value, unit on its baseline, working underneath.
        let left: CGFloat = 26
        let valueSize = valueLabel.attributedStringValue.size()
        let valueWidth = min(ceil(valueSize.width) + 4, hintsLeft - left - 80)
        valueLabel.frame = NSRect(x: left, y: height / 2 - 6, width: valueWidth, height: ceil(valueSize.height))
        let unitSize = unitLabel.attributedStringValue.size()
        unitLabel.frame = NSRect(x: valueLabel.frame.maxX + 8, y: valueLabel.frame.minY + 10, width: ceil(unitSize.width) + 4, height: ceil(unitSize.height))
        detailLabel.frame = NSRect(x: left, y: height / 2 - 34, width: max(0, hintsLeft - left - 16), height: 16)
    }
}

/// The `stats` card: three headline numbers over a 28-day chart, drawn in one pass.
final class StatsCardView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("launcher-stats-card")
    static let height: CGFloat = 138
    private var stats: UsageStats?
    private var theme = Theme.signal(accent: "volt")
    private static let dayFormat: DateFormatter = {
        let format = DateFormatter()
        format.setLocalizedDateFormatFromTemplate("MMM d")
        return format
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func configure(_ stats: UsageStats, theme: Theme) {
        self.stats = stats
        self.theme = theme
        setAccessibilityLabel("\(stats.actions) actions in \(stats.days) days, about \(UsageStats.duration(stats.secondsSaved)) saved")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let stats else { return }
        let left: CGFloat = 26, right = bounds.width - 26
        let perDay = Double(stats.actions) / Double(stats.days)
        let metrics: [(label: String, value: String, note: String, accent: Bool)] = [
            ("Actions", stats.actions.formatted(), "\(Int(perDay.rounded())) a day · \(Int((Double(stats.opens) / Double(stats.days)).rounded())) opens a day", false),
            ("Time saved · est", UsageStats.duration(stats.secondsSaved), "≈ \(String(format: "%.1f", stats.secondsSaved / 60 / Double(stats.days))) min a day", true),
            ("Keys per action", stats.keysPerAction.map { String(format: "%.1f", $0) } ?? "–",
             stats.medianMs.map { "open to ↵ in " + String(format: "%.1f", Double($0) / 1000) + " s" } ?? "no actions yet", false),
        ]
        let column = (right - left) / CGFloat(metrics.count)
        for (index, metric) in metrics.enumerated() {
            let x = left + CGFloat(index) * column
            theme.labelText(metric.label, size: 10).draw(at: NSPoint(x: x, y: 10))
            NSAttributedString(string: metric.value, attributes: [
                .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
                .foregroundColor: metric.accent ? theme.accent : theme.text,
            ]).draw(at: NSPoint(x: x - 1, y: 24))
            NSAttributedString(string: metric.note, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: theme.secondary,
            ]).draw(at: NSPoint(x: x, y: 60))
        }
        // One bar per day, oldest on the left; today in the accent.
        let gap: CGFloat = 3, top: CGFloat = 84, base: CGFloat = 112
        let width = (right - left - gap * CGFloat(stats.days - 1)) / CGFloat(stats.days)
        let peak = max(1, stats.daily.max() ?? 1)
        for (index, count) in stats.daily.enumerated() {
            let height = max(2, (base - top) * CGFloat(count) / CGFloat(peak))
            let bar = NSRect(x: left + CGFloat(index) * (width + gap), y: base - height, width: width, height: height)
            (index == stats.daily.count - 1 ? theme.accent : theme.tileBorder).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        }
        let start = Calendar.current.date(byAdding: .day, value: -(stats.days - 1), to: Date()) ?? Date()
        let first = theme.labelText(Self.dayFormat.string(from: start), size: 10)
        first.draw(at: NSPoint(x: left, y: base + 6))
        let last = theme.labelText("Today", size: 10)
        last.draw(at: NSPoint(x: right - last.size().width, y: base + 6))
    }
}
