import AppKit
import LauncherCore

/// `theme` lists the looks. Moving the selection previews live; Return saves; Escape
/// (or typing anything else) reverts to the look in use when the picker opened.
extension AppDelegate {

    func themeResults() -> [PanelItem] {
        if case .theme = panelState.presentation {} else {
            panelState.presentation = .theme(original: appearanceSettings)
        }
        let accentName = appearanceSettings.accent.capitalized
        return [
            .theme(.look(id: "signal", name: "Signal")),
            .theme(.look(id: "glass", name: "Glass")),
            .theme(.look(id: "raycast", name: "Compact")),
            .theme(.accent(
                name: theme.instrument ? "Accent · \(accentName)" : "Accent · follows macOS",
                value: appearanceSettings.accent
            )),
        ]
    }

    func themeDetail(for option: ThemeOption) -> String {
        switch option {
        case .look(id: "signal", name: _): return "Dark instrument · one electric accent"
        case .look(id: "glass", name: _): return "Frosted macOS material · calm"
        case .look(id: "raycast", name: _): return "Light grey · one line per row"
        case .look: return ""
        case .accent: return theme.instrument ? "← → to change" : "System Settings › Appearance › Accent colour"
        }
    }

    /// The saved theme carries an "Active" note; nil keeps the default trailing text.
    func themeNote(for option: ThemeOption) -> String {
        guard case .look(let id, _) = option else { return "" }
        let original: AppearanceSettings
        if case .theme(let saved) = panelState.presentation { original = saved }
        else { original = appearanceSettings }
        return id == original.theme ? "Active" : ""
    }

    func themeSwatch(for option: ThemeOption) -> NSImage {
        let size = NSSize(width: 28, height: 28)
        return NSImage(size: size, flipped: false) { rect in
            switch option {
            case .accent:
                let color = self.theme.instrument ? self.theme.accent : NSColor.controlAccentColor
                color.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 6, dy: 6)).fill()
            case .look(id: "raycast", name: _):
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 3), xRadius: 5, yRadius: 5)
                NSColor(hex: 0xF4F4F4).setFill(); path.fill()
                NSColor(hex: 0xCFCFCF).setStroke(); path.lineWidth = 1; path.stroke()
                NSColor(hex: 0xDCDCDC).setFill()
                NSBezierPath(roundedRect: NSRect(x: 4, y: 11, width: 20, height: 6), xRadius: 3, yRadius: 3).fill()
                NSColor(hex: 0x0D0D0D).setFill()
                NSRect(x: 7, y: 13.5, width: 9, height: 1).fill()
            case .look(id: "glass", name: _):
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 3), xRadius: 6, yRadius: 6)
                NSColor(hex: 0x3B4766).setFill(); path.fill()
                NSColor(hex: 0x5B7CFA, alpha: 0.6).setFill()
                NSBezierPath(ovalIn: NSRect(x: -4, y: 12, width: 18, height: 18)).fill()
                NSColor(white: 1, alpha: 0.85).setFill()
                NSBezierPath(roundedRect: NSRect(x: 6, y: 15, width: 12, height: 2), xRadius: 1, yRadius: 1).fill()
                NSColor(white: 1, alpha: 0.3).setStroke(); path.lineWidth = 1; path.stroke()
            case .look:
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 3), xRadius: 5, yRadius: 5)
                NSColor(hex: 0x0B0C0F).setFill(); path.fill()
                NSColor(hex: 0x2B2F36).setStroke(); path.lineWidth = 1; path.stroke()
                NSColor(hex: 0xC9CDD2).setFill()
                NSBezierPath(roundedRect: NSRect(x: 6, y: 16, width: 12, height: 2), xRadius: 1, yRadius: 1).fill()
                Theme.signal(accent: self.appearanceSettings.accent).accent.setFill()
                NSRect(x: 6, y: 12, width: 9, height: 1).fill()
            }
            return true
        }
    }

    /// Selection moved inside the picker: repaint with that look, keep the selected row.
    func previewSelectedTheme() {
        guard case .theme = panelState.presentation,
              case .theme(.look(let id, _))? = selectedItem,
              id != appearanceSettings.theme else { return }
        restyle(AppearanceSettings(theme: id, accent: appearanceSettings.accent))
    }

    func cycleAccent(_ step: Int) -> Bool {
        guard case .theme = panelState.presentation, theme.instrument,
              case .theme(.accent)? = selectedItem else { return false }
        let names = AppearanceSettings.accents
        let index = names.firstIndex(of: appearanceSettings.accent) ?? 0
        let next = names[(index + step + names.count) % names.count]
        restyle(AppearanceSettings(theme: appearanceSettings.theme, accent: next))
        return true
    }

    func applyThemeSelection() {
        guard case .theme = panelState.presentation else { return }
        let chosen: AppearanceSettings?
        if case .theme(.look(let id, _))? = selectedItem {
            chosen = AppearanceSettings(theme: id, accent: appearanceSettings.accent)
        } else { chosen = nil }
        let saved = setTheme(chosen ?? appearanceSettings, persist: true)
        panelState.presentation = .standard(favoriteCount: 0)
        refreshResults()
        footer.message = saved
            ? "\(appearanceSettings.theme.capitalized) saved."
            : "Could not save the theme. It resets when Impulse restarts."
    }

    /// Restores the look from before the picker opened. True when something changed.
    @discardableResult
    func revertThemePreview() -> Bool {
        guard case .theme(let original) = panelState.presentation else { return false }
        panelState.presentation = .standard(favoriteCount: 0)
        guard original != appearanceSettings else { return false }
        setTheme(original, persist: false)
        return true
    }

    private func restyle(_ settings: AppearanceSettings) {
        setTheme(settings, persist: false)
        refreshResults()
    }
}
