import AppKit
import LauncherCore

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// One set of design values. Signal and Glass share the layout; only these values differ.
struct Theme {
    let id: String
    let accentName: String
    let accent: NSColor
    let accentInk: NSColor
    let usesMaterial: Bool
    let panelFill: NSColor
    let panelBorder: NSColor
    let radius: CGFloat
    let rowRadius: CGFloat
    let text: NSColor
    let rowTitle: NSColor
    let secondary: NSColor
    let label: NSColor
    let rule: NSColor
    let selectionFill: NSColor
    let selectionBorder: NSColor
    let tileFill: NSColor
    let tileBorder: NSColor
    let symbol: NSColor
    let keyFill: NSColor
    let keyBorder: NSColor
    let keyText: NSColor
    let warning: NSColor
    /// Signal speaks in mono capitals with a glowing indicator; Glass in soft sentence case.
    let instrument: Bool
    /// Raycast rows: one line, 40 points, bare icons, a 20-point input.
    var compact = false
    /// One keycap per key (⌘ and K apart), and the first footer hint reads as the primary action.
    var separateKeys = false
    var footerFill = NSColor(white: 1, alpha: 0.03)
    var hintText = NSColor(white: 1, alpha: 0.62)
    var brandText = NSColor(white: 1, alpha: 0.72)
    var chipFill = NSColor(white: 1, alpha: 0.13)

    static let signalAccents: [(name: String, color: NSColor)] = [
        ("volt", NSColor(hex: 0xD4FF3A)),
        ("cyan", NSColor(hex: 0x4DE8FF)),
        ("orange", NSColor(hex: 0xFF8A3D)),
        ("violet", NSColor(hex: 0xB69CFF)),
    ]

    static func make(_ settings: AppearanceSettings) -> Theme {
        switch settings.theme {
        case "glass": return .glass
        case "raycast": return .raycast
        default: return .signal(accent: settings.accent)
        }
    }

    /// The Compact look (saved as "raycast" for older settings files): one grey surface,
    /// a soft selection pill, grey everything except titles and app icons.
    static var raycast: Theme {
        var theme = Theme(
            id: "raycast", accentName: "system", accent: .controlAccentColor, accentInk: .white,
            usesMaterial: false,
            panelFill: NSColor(hex: 0xF4F4F4), panelBorder: NSColor(hex: 0xCFCFCF),
            radius: 12, rowRadius: 10,
            text: NSColor(hex: 0x0D0D0D), rowTitle: NSColor(hex: 0x0D0D0D),
            secondary: NSColor(hex: 0x5F5F5F), label: NSColor(hex: 0x696969),
            rule: NSColor(hex: 0xDCDCDC),
            selectionFill: NSColor(hex: 0xDCDCDC), selectionBorder: .clear,
            tileFill: .clear, tileBorder: .clear,
            symbol: NSColor(hex: 0x5F5F5F),
            keyFill: NSColor(hex: 0xD8D8D9), keyBorder: .clear, keyText: NSColor(hex: 0x555555),
            warning: NSColor(hex: 0xC2410C),
            instrument: false
        )
        theme.compact = true
        theme.separateKeys = true
        theme.footerFill = NSColor(hex: 0xEFEFF0)
        theme.hintText = NSColor(hex: 0x696969)
        theme.brandText = NSColor(hex: 0x696969)
        theme.chipFill = NSColor(hex: 0xDCDCDC)
        return theme
    }

    static func signal(accent name: String) -> Theme {
        let accent = signalAccents.first { $0.name == name }?.color ?? signalAccents[0].color
        return Theme(
            id: "signal", accentName: name, accent: accent, accentInk: NSColor(hex: 0x0B0C0F),
            usesMaterial: false,
            panelFill: NSColor(hex: 0x0B0C0F), panelBorder: NSColor(hex: 0x1F2329),
            radius: 14, rowRadius: 8,
            text: NSColor(hex: 0xF4F6F7), rowTitle: NSColor(hex: 0xC9CDD2),
            secondary: NSColor(hex: 0x7D848C), label: NSColor(hex: 0x646A73),
            rule: NSColor(hex: 0x1F2329),
            selectionFill: NSColor(hex: 0x14171B), selectionBorder: NSColor(hex: 0x23272E),
            tileFill: NSColor(hex: 0x181B20), tileBorder: NSColor(hex: 0x262A31),
            symbol: NSColor(hex: 0xC9CDD2),
            keyFill: .clear, keyBorder: NSColor(hex: 0x2B2F36), keyText: NSColor(hex: 0x8E959D),
            warning: NSColor(hex: 0xFF8A3D),
            instrument: true
        )
    }

    static var glass: Theme {
        let white = { (alpha: CGFloat) in NSColor(white: 1, alpha: alpha) }
        return Theme(
            id: "glass", accentName: "system", accent: .controlAccentColor, accentInk: .white,
            usesMaterial: true,
            panelFill: NSColor(hex: 0x1C1E26, alpha: 0.55), panelBorder: white(0.12),
            radius: 24, rowRadius: 12,
            text: .white, rowTitle: .white,
            secondary: white(0.58), label: white(0.48),
            rule: white(0.08),
            selectionFill: white(0.13), selectionBorder: white(0.07),
            tileFill: white(0.09), tileBorder: white(0.12),
            symbol: white(0.88),
            keyFill: white(0.11), keyBorder: .clear, keyText: white(0.82),
            warning: NSColor(hex: 0xFFB35C),
            instrument: false
        )
    }

    func monoFont(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// Section labels, status labels and hint words.
    func labelText(_ text: String, color: NSColor? = nil, size: CGFloat = 10) -> NSAttributedString {
        if instrument {
            return NSAttributedString(string: text.uppercased(), attributes: [
                .font: monoFont(size, .medium), .foregroundColor: color ?? label, .kern: size * 0.14,
            ])
        }
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size + 1, weight: .semibold), .foregroundColor: color ?? label,
        ])
    }
}

enum PulseMark {
    /// The Impulse mark: a flat line with one spike, drawn on a 24-point grid.
    static func image(size: CGFloat, color: NSColor?, lineWidth: CGFloat = 2.2) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let scale = rect.width / 24
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 2 * scale, y: 12 * scale))
            path.line(to: NSPoint(x: 7 * scale, y: 12 * scale))
            path.line(to: NSPoint(x: 9.5 * scale, y: 5 * scale))
            path.line(to: NSPoint(x: 14.5 * scale, y: 19 * scale))
            path.line(to: NSPoint(x: 17 * scale, y: 12 * scale))
            path.line(to: NSPoint(x: 22 * scale, y: 12 * scale))
            path.lineWidth = lineWidth * scale
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            (color ?? .black).setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = color == nil
        return image
    }
}

/// A key glyph in a small rounded box (↵, ⌘↵, ⇥, or an alias). Frame layout keeps table rows cheap.
final class KeycapView: NSView {
    private let label = NSTextField(labelWithString: "")
    private(set) var preferredWidth: CGFloat = 20

    init(_ text: String, theme: Theme, emphasized: Bool = false, size: CGFloat = 11) {
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        update(text, theme: theme, emphasized: emphasized, size: size)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: preferredWidth, height: 20) }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 5, y: (bounds.height - 15) / 2, width: max(0, bounds.width - 10), height: 15)
    }

    /// Restyles in place so table rows can reuse one keycap.
    func update(_ text: String, theme: Theme, emphasized: Bool = false, size: CGFloat = 11) {
        layer?.cornerRadius = theme.instrument ? 5 : 6
        layer?.borderWidth = theme.instrument ? 1 : 0
        layer?.borderColor = (emphasized ? theme.accent : theme.keyBorder).cgColor
        // Raycast keeps every keycap grey, even the one for Return.
        let accentFill = emphasized && !theme.instrument && !theme.separateKeys
        layer?.backgroundColor = (accentFill ? theme.accent.withAlphaComponent(0.85) : theme.keyFill).cgColor
        let font = theme.instrument ? theme.monoFont(size) : NSFont.systemFont(ofSize: size, weight: .medium)
        if label.stringValue != text || label.font != font {
            label.stringValue = text
            label.font = font
            preferredWidth = max(20, ceil((text as NSString).size(withAttributes: [.font: font]).width) + 18)
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
        label.textColor = emphasized && !theme.separateKeys ? (theme.instrument ? theme.accent : theme.accentInk) : theme.keyText
    }
}

/// The rule under the input. Signal adds a glowing accent segment.
final class SignalLineView: NSView {
    private let segment = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        segment.wantsLayer = true
        segment.translatesAutoresizingMaskIntoConstraints = false
        addSubview(segment)
        NSLayoutConstraint.activate([
            segment.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            segment.topAnchor.constraint(equalTo: topAnchor),
            segment.bottomAnchor.constraint(equalTo: bottomAnchor),
            segment.widthAnchor.constraint(equalToConstant: 110),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ theme: Theme) {
        layer?.backgroundColor = theme.rule.cgColor
        segment.isHidden = !theme.instrument
        segment.layer?.backgroundColor = theme.accent.cgColor
        segment.layer?.shadowColor = theme.accent.cgColor
        segment.layer?.shadowOpacity = 1
        segment.layer?.shadowRadius = 5
        segment.layer?.shadowOffset = .zero
        segment.layer?.masksToBounds = false
        layer?.masksToBounds = false
    }
}

/// Bottom bar: the Impulse mark and timing on the left, key hints or a status message on the right.
final class FooterView: NSView {
    private let mark = NSImageView()
    private let brand = NSTextField(labelWithString: "")
    private let timing = NSTextField(labelWithString: "")
    private let hintStack = NSStackView()
    private let messageLabel = NSTextField(labelWithString: "")
    private let rule = NSView()
    private var theme = Theme.signal(accent: "volt")
    private var hints: [(key: String, label: String)] = []
    /// What is on screen now; render() skips work when nothing changed.
    private var renderedSignature = ""

    /// A status or error line. It replaces the hints until the next results refresh.
    var message: String? { didSet { render() } }
    var isWarning = false { didSet { render() } }
    var latencyMilliseconds: Double? { didSet { renderTiming() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for view in [mark, brand, timing, hintStack, messageLabel, rule] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        rule.wantsLayer = true
        hintStack.orientation = .horizontal
        hintStack.spacing = 16
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        brand.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 42),
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
            mark.widthAnchor.constraint(equalToConstant: 14),
            mark.heightAnchor.constraint(equalToConstant: 14),
            brand.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 8),
            brand.centerYAnchor.constraint(equalTo: centerYAnchor),
            timing.leadingAnchor.constraint(equalTo: brand.trailingAnchor, constant: 8),
            timing.centerYAnchor.constraint(equalTo: centerYAnchor),
            hintStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            hintStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: timing.trailingAnchor, constant: 16),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Status")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ theme: Theme) {
        self.theme = theme
        rule.layer?.backgroundColor = (theme.instrument ? NSColor(hex: 0x1A1D22) : theme.rule).cgColor
        layer?.backgroundColor = (theme.instrument ? NSColor.clear : theme.footerFill).cgColor
        mark.image = PulseMark.image(size: 14, color: theme.instrument ? theme.accent : theme.secondary, lineWidth: 2.6)
        renderedSignature = ""
        brand.attributedStringValue = theme.labelText("Impulse", color: theme.instrument ? NSColor(hex: 0x9AA0A7) : theme.brandText, size: 11)
        // Raycast's footer carries the mark alone.
        brand.isHidden = theme.separateKeys
        renderTiming()
        render()
    }

    /// "⌘K" → ["⌘", "K"]; "⌘↵" → ["⌘", "↵"]; "esc" and "←→" stay whole.
    static func keyParts(_ key: String) -> [String] {
        let modifiers: Set<Character> = ["⌘", "⌥", "⇧", "⌃"]
        var parts: [String] = []
        var rest = Substring(key)
        while let first = rest.first, modifiers.contains(first), rest.count > 1 {
            parts.append(String(first))
            rest = rest.dropFirst()
        }
        if !rest.isEmpty { parts.append(String(rest)) }
        return parts
    }

    func setHints(_ hints: [(key: String, label: String)]) {
        self.hints = hints
        message = nil
    }

    private func renderTiming() {
        guard theme.instrument, let latencyMilliseconds else { timing.stringValue = ""; return }
        let text = latencyMilliseconds < 1 ? String(format: "%.1f ms", latencyMilliseconds) : "\(Int(latencyMilliseconds.rounded())) ms"
        timing.attributedStringValue = theme.labelText(text, color: theme.accent, size: 11)
    }

    private func render() {
        let signature = message.map { "m|\(isWarning)|\($0)" } ?? "h|" + hints.map { $0.key + $0.label }.joined(separator: "|")
        guard signature != renderedSignature else { return }
        renderedSignature = signature
        hintStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let message {
            hintStack.isHidden = true
            messageLabel.isHidden = false
            let font = theme.instrument ? theme.monoFont(11) : NSFont.systemFont(ofSize: 12)
            let color = isWarning ? theme.warning : theme.secondary
            let text = NSMutableAttributedString()
            // A warning leads with its symbol, so it reads as a problem before the words do.
            if isWarning, let symbol = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold).applying(.init(paletteColors: [color]))) {
                let attachment = NSTextAttachment()
                attachment.image = symbol
                attachment.bounds = NSRect(x: 0, y: -2, width: symbol.size.width, height: symbol.size.height)
                text.append(NSAttributedString(attachment: attachment))
                text.append(NSAttributedString(string: "  "))
            }
            text.append(NSAttributedString(string: message, attributes: [.font: font, .foregroundColor: color]))
            messageLabel.attributedStringValue = text
            setAccessibilityValue(message)
            return
        }
        messageLabel.isHidden = true
        hintStack.isHidden = false
        // Raycast leads with what Return does.
        var shown = hints
        if theme.separateKeys, let enter = shown.firstIndex(where: { $0.key == "↵" }), enter > 0 {
            shown.insert(shown.remove(at: enter), at: 0)
        }
        for (index, hint) in shown.enumerated() {
            let item = NSStackView()
            item.orientation = .horizontal
            item.spacing = 6
            // Raycast names what Return does in dark text; the other hints stay grey.
            let primary = theme.separateKeys && index == 0
            let word = NSTextField(labelWithAttributedString: primary
                ? NSAttributedString(string: hint.label, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: theme.text])
                : theme.labelText(hint.label, color: theme.instrument ? theme.secondary : theme.hintText, size: 11))
            let keys = NSStackView()
            keys.orientation = .horizontal
            keys.spacing = 2
            for part in theme.separateKeys ? Self.keyParts(hint.key) : [hint.key] {
                keys.addArrangedSubview(KeycapView(part, theme: theme))
            }
            if theme.instrument { item.addArrangedSubview(keys); item.addArrangedSubview(word) }
            else { item.addArrangedSubview(word); item.addArrangedSubview(keys) }
            if theme.separateKeys, index > 0 {
                let divider = NSView()
                divider.wantsLayer = true
                divider.layer?.backgroundColor = theme.rule.cgColor
                divider.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([divider.widthAnchor.constraint(equalToConstant: 1), divider.heightAnchor.constraint(equalToConstant: 14)])
                hintStack.addArrangedSubview(divider)
            }
            hintStack.addArrangedSubview(item)
        }
        setAccessibilityValue(hints.map { "\($0.label) \($0.key)" }.joined(separator: ", "))
    }
}
