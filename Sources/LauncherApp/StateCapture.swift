import AppKit
import LauncherCore

/// Design-audit capture: drives the launcher through fixed states in-process and saves
/// window images. No synthetic keystrokes, so nothing can type into another app.
/// Enable with IMPULSE_CAPTURE_DIR=<dir> and a sandbox IMPULSE_CONFIG.
enum StateCapture {
    enum Step {
        case type(String)
        case tab
        case down
        case pause(TimeInterval)
        case preview
        case breakConfig
        case setTheme(String, accent: String)
        /// Replaces the in-memory usage history with a fixed sample. The log file is untouched.
        case sampleUsage
        /// Opens the emoji picker with a fixed frequently-used list.
        case emoji
        /// Replaces the in-memory usage with fixed counts per action ID and feeds them to the search order.
        case rankingUsage([String: Int])
        /// Points the Larynx reader at a fixture, or at the real history (read-only) when nil.
        case larynx(LarynxFixture?)
    }

    struct State {
        let name: String
        let steps: [Step]
        var wait: TimeInterval = 1.0
    }

    static var directory: URL? {
        ProcessInfo.processInfo.environment["IMPULSE_CAPTURE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static let states: [State] = [
        State(name: "01-idle", steps: [.type("")], wait: 1.5),
        State(name: "02-app-match", steps: [.type("saf")], wait: 1.5),
        State(name: "03-alias-exact", steps: [.type("gh")]),
        State(name: "04-alias-prefix-list", steps: [.type("g")]),
        State(name: "05-selection-moved", steps: [.type("g"), .down, .down]),
        State(name: "06-query-mode-empty", steps: [.type("y"), .tab]),
        State(name: "07-query-mode-typed", steps: [.type("y"), .tab, .type("lofi beats")]),
        State(name: "08-inline-search", steps: [.type("y cats")]),
        State(name: "09-web-fallback", steps: [.type("imp")]),
        State(name: "10-calculator", steps: [.type("2 * (3 + 4)")]),
        State(name: "11-unit-conversion", steps: [.type("10 km in miles")]),
        State(name: "12-currency", steps: [.type("100 USD in AUD")], wait: 2.5),
        State(name: "13-snippet", steps: [.type("today")]),
        State(name: "14-workspace-terminal", steps: [.type("grid")]),
        State(name: "15-system", steps: [.type("system")]),
        State(name: "16-shortcuts", steps: [.type("shortcuts")], wait: 1.5),
        State(name: "17-clipboard", steps: [.type("clipboard")]),
        State(name: "18-no-match", steps: [.type("zzqxv")]),
        State(name: "19-file-search", steps: [.type("files publication")], wait: 3),
        State(name: "20-file-preview", steps: [.type("files publication"), .pause(2.5), .preview], wait: 2.5),
        State(name: "21-config-error", steps: [.type(""), .breakConfig], wait: 2.5),
        State(name: "22-theme-picker", steps: [.type("theme")]),
        State(name: "27-signal-results", steps: [.type("fig")], wait: 3),
        State(name: "23-glass-results", steps: [.setTheme("glass", accent: "volt"), .type("fig")], wait: 3),
        State(name: "24-glass-answer", steps: [.setTheme("glass", accent: "volt"), .type("10 km in miles")]),
        State(name: "25-glass-query-mode", steps: [.setTheme("glass", accent: "volt"), .type("y"), .tab, .type("lofi beats")]),
        State(name: "26-glass-theme-picker", steps: [.setTheme("glass", accent: "volt"), .type("theme")]),
        State(name: "28-letter-tiles", steps: [.type("lin")]),
        State(name: "29-stats", steps: [.sampleUsage, .type("stats")]),
        State(name: "30-glass-stats", steps: [.setTheme("glass", accent: "volt"), .sampleUsage, .type("stats")]),
        State(name: "31-emoji", steps: [.emoji]),
        State(name: "32-emoji-search", steps: [.emoji, .type("lol")]),
        State(name: "33-glass-emoji", steps: [.setTheme("glass", accent: "volt"), .emoji]),
        State(name: "34-larynx", steps: [.larynx(.full), .type("larynx")]),
        State(name: "35-glass-larynx", steps: [.setTheme("glass", accent: "volt"), .larynx(.full), .type("larynx")]),
        State(name: "36-larynx-empty", steps: [.larynx(.empty), .type("larynx")]),
        State(name: "37-larynx-today", steps: [.larynx(.today), .type("larynx")]),
        State(name: "38-larynx-huge", steps: [.larynx(.huge), .type("larynx")]),
        State(name: "39-larynx-unknown", steps: [.larynx(.unknown), .type("larynx")]),
        State(name: "40-larynx-missing", steps: [.larynx(.old), .type("larynx")]),
        State(name: "41-larynx-real", steps: [.larynx(nil), .type("larynx")]),
        State(name: "42-glass-larynx-real", steps: [.setTheme("glass", accent: "volt"), .larynx(nil), .type("larynx")]),
        State(name: "43-raycast-results", steps: [.setTheme("raycast", accent: "volt"), .type("fig")], wait: 3),
        State(name: "44-raycast-favorites", steps: [.setTheme("raycast", accent: "volt"), .type("")]),
        State(name: "45-raycast-query-mode", steps: [.setTheme("raycast", accent: "volt"), .type("y"), .tab, .type("lofi beats")]),
        State(name: "46-raycast-answer", steps: [.setTheme("raycast", accent: "volt"), .type("10 km in miles")]),
        State(name: "47-raycast-theme-picker", steps: [.setTheme("raycast", accent: "volt"), .type("theme")]),
        State(name: "48-raycast-emoji", steps: [.setTheme("raycast", accent: "volt"), .emoji]),
        State(name: "49-raycast-stats", steps: [.setTheme("raycast", accent: "volt"), .sampleUsage, .type("stats")]),
        // For the ranking explainer: run with a sample config that has these IDs and IMPULSE_CAPTURE_NO_DISCOVERY=1.
        State(name: "50-ranking", steps: [.rankingUsage(["clock": 12, "recipes": 8, "chess": 3, "music": 2, "calendar": 1]), .type("c")]),
    ]

    static func run(_ app: AppDelegate, into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = (try? Data(contentsOf: app.configURL)) ?? Data()
        let only = ProcessInfo.processInfo.environment["IMPULSE_CAPTURE_ONLY"]?.split(separator: ",").map(String.init)
        var queue = states.filter { only == nil || only!.contains($0.name) }
        var failed: [String] = []

        // Captured file results come from this repository only, never the home folder.
        let repository = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        app.fileSearchRoot = ProcessInfo.processInfo.environment["IMPULSE_CAPTURE_FILES"].map { URL(fileURLWithPath: $0) } ?? repository
        // The backdrop must be on screen before the first capture, or real windows show through.
        app.show()
        _ = makeBackdrop(behind: app.panel)

        func next() {
            guard !queue.isEmpty else {
                try? original.write(to: app.configURL, options: .atomic)
                app.setTheme(.standard, persist: false)
                guard failed.isEmpty else {
                    // A missing or discarded image fails the run, so callers cannot mistake it for a full set.
                    print("FAIL capture: \(failed.count) state(s) not saved: \(failed.joined(separator: ","))")
                    app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
                    exit(1)
                }
                NSApp.terminate(nil)
                return
            }
            let state = queue.removeFirst()
            app.previewWindow?.close()
            try? original.write(to: app.configURL, options: .atomic)
            // A theme picker left open would restore its own look on the next refresh.
            app.panelState.presentation = .standard(favoriteCount: 0)
            app.setTheme(.standard, persist: false)
            app.show()
            let misses = app.iconProvider.missCount
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                perform(state.steps[...], on: app) {
                  DispatchQueue.main.asyncAfter(deadline: .now() + state.wait) {
                    let window: NSWindow? = state.steps.contains { if case .preview = $0 { return true } else { return false } }
                        ? app.previewWindow : app.panel
                    let failure = window.map { save($0, to: directory.appendingPathComponent(state.name + ".png")) }
                        ?? "no window to capture"
                    if failure != nil { failed.append(state.name) }
                    // A miss means a row showed a placeholder while its icon loaded.
                    print(report(state.name, failure: failure, iconMisses: app.iconProvider.missCount - misses))
                    next()
                  }
                }
            }
        }
        // First launch of a fresh build is slow to composite; let the panel settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { next() }
    }

    /// 28 days of made-up use of the sandbox actions: weekdays busier, the same every run.
    private static func sampleUsage(_ actions: [LauncherAction]) -> [UsageEvent] {
        let weights = ["youtube": 9, "google": 8, "date": 4, "github": 3, "maps": 2, "calendar": 1, "workspace.grid": 1]
        let pool = actions.filter { weights[$0.id] != nil }.flatMap { Array(repeating: $0, count: weights[$0.id]!) }
        guard !pool.isEmpty else { return [] }
        var events: [UsageEvent] = []
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        for back in 0..<28 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            let weekend = calendar.isDateInWeekend(day)
            let count = back == 0 ? 38 : (weekend ? 9 : 40) + (back * 7) % 23
            for index in 0..<count {
                let time = day.addingTimeInterval(Double(8 * 3600 + index * 600) + Double(back % 5) * 60)
                if back == 0 && time > Date() { break }
                let action = pool[(index * 7 + back * 3) % pool.count]
                let alias = action.aliases.first ?? ""
                events.append(.open(at: time.addingTimeInterval(-2)))
                events.append(.action(action, at: time, keys: max(1, alias.count) + (action.target.contains("{query}") ? 1 : 0),
                                      ms: 700 + (index * 37 + back * 11) % 1400, via: .alias))
            }
        }
        return events.sorted { $0.t < $1.t }
    }

    /// Runs steps in order; `.pause` waits before the rest run.
    private static func perform(_ steps: ArraySlice<Step>, on app: AppDelegate, then done: @escaping () -> Void) {
        guard let step = steps.first else { done(); return }
        if case .pause(let seconds) = step {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { perform(steps.dropFirst(), on: app, then: done) }
            return
        }
        perform(step, on: app)
        perform(steps.dropFirst(), on: app, then: done)
    }

    private static func perform(_ step: Step, on app: AppDelegate) {
        switch step {
        case .pause: break
        case .type(let text):
            app.field.stringValue = text
            app.refreshResults()
            app.field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        case .tab: app.enterQueryMode()
        case .down: app.select(delta: 1)
        case .preview: app.previewSelected()
        case .breakConfig: try? Data("{ broken".utf8).write(to: app.configURL, options: .atomic)
        case .setTheme(let theme, let accent): app.setTheme(AppearanceSettings(theme: theme, accent: accent), persist: false)
        case .sampleUsage: app.usageEvents = sampleUsage(app.actions)
        case .rankingUsage(let counts):
            let now = Date()
            app.usageEvents = app.actions.flatMap { action in
                (0..<(counts[action.id] ?? 0)).map { index in
                    UsageEvent.action(action, at: now.addingTimeInterval(Double(-3600 * (index + 1))), keys: 2, ms: 900, via: .alias)
                }
            }
            app.refreshRanking()
        case .larynx(let fixture):
            app.dictations = DictationHistory(path: (try? fixture?.write()) ?? DictationHistory.defaultPath)
        case .emoji:
            app.emojiSeed = ["🦾", "🤖", "👀", "👌", "👇", "👍", "🔥", "🤨", "👋", "💯", "🥰", "🙏", "🚀", "😍", "🧠", "✅"]
            app.enterEmojiMode()
        }
    }

    private static var backdrop: NSWindow?
    private static let margin: CGFloat = 56

    /// A neutral desktop behind the panel, so Glass has content to blur and no personal
    /// windows appear in captures.
    private static func makeBackdrop(behind panel: NSWindow) -> NSWindow {
        if let backdrop { return backdrop }
        let frame = panel.frame.insetBy(dx: -margin, dy: -margin)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: panel.level.rawValue - 1)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(hex: 0x1A2130).cgColor
        let blocks: [(NSRect, UInt32)] = [
            (NSRect(x: 30, y: frame.height - 420, width: 300, height: 360), 0x283246),
            (NSRect(x: 60, y: frame.height - 300, width: 240, height: 150), 0x5B7CFA),
            (NSRect(x: frame.width - 360, y: frame.height - 330, width: 300, height: 260), 0xECE7DD),
            (NSRect(x: frame.width - 330, y: frame.height - 230, width: 120, height: 110), 0xE8774A),
            (NSRect(x: frame.width - 190, y: frame.height - 230, width: 120, height: 110), 0x3FA796),
        ]
        // IMPULSE_CAPTURE_PLAIN=1 leaves the backdrop one flat colour, for README images.
        let plain = ProcessInfo.processInfo.environment["IMPULSE_CAPTURE_PLAIN"] == "1"
        for (rect, color) in plain ? [] : blocks {
            let block = NSView(frame: rect)
            block.wantsLayer = true
            block.layer?.cornerRadius = 12
            block.layer?.backgroundColor = NSColor(hex: color).cgColor
            root.addSubview(block)
        }
        window.contentView = root
        window.orderFront(nil)
        backdrop = window
        return window
    }

    /// True when the top and side edges are one dark navy. Real windows are never that uniform.
    /// The bottom edge can cross a backdrop block, so it is not sampled.
    private static func edgesAreBackdrop(_ rep: NSBitmapImageRep) -> Bool {
        let w = rep.pixelsWide, h = rep.pixelsHigh
        let points = stride(from: 0, to: 20, by: 1).flatMap { i -> [(Int, Int)] in
            let x = 2 + (w - 5) * i / 19, y = 2 + (h - 5) * i / 19
            return [(x, 2), (2, y), (w - 3, y)]
        }
        func rgb(_ x: Int, _ y: Int) -> (CGFloat, CGFloat, CGFloat)? {
            rep.colorAt(x: x, y: y).map { ($0.redComponent * 255, $0.greenComponent * 255, $0.blueComponent * 255) }
        }
        guard let reference = rgb(2, 2),
              reference.0 + reference.1 + reference.2 < 200, reference.2 > reference.0 + 8
        else { return false }
        return points.allSatisfy { x, y in
            guard let c = rgb(x, y) else { return false }
            let same = abs(c.0 - reference.0) < 4 && abs(c.1 - reference.1) < 4 && abs(c.2 - reference.2) < 4
            if !same { FileHandle.standardError.write(Data("PX \(x),\(y) of \(w)x\(h): \(Int(c.0)),\(Int(c.1)),\(Int(c.2)) vs \(Int(reference.0)),\(Int(reference.1)),\(Int(reference.2))\n".utf8)) }
            return same
        }
    }

    /// One line per state: `ok` only when the image was saved.
    static func report(_ name: String, failure: String?, iconMisses: Int) -> String {
        if let failure { return "FAIL \(name): \(failure)" }
        return "ok \(name) icon-misses=\(iconMisses)"
    }

    /// Captures the window and saves it. Returns why no image was saved, or nil on success.
    private static func save(_ window: NSWindow, to url: URL) -> String? {
        let image: CGImage?
        if let panel = window as? PalettePanel, let app = NSApp.delegate as? AppDelegate {
            guard let back = backdrop, back.isVisible, panel.isVisible else {
                return "panel or backdrop not on screen"
            }
            back.setFrame(panel.frame.insetBy(dx: -margin, dy: -margin), display: true)
            back.order(.below, relativeTo: panel.windowNumber)
            // Global CG coordinates: origin at the top-left of the main screen.
            let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
            let visible = margin + app.cardHeight.constant + margin
            let rect = CGRect(x: back.frame.minX, y: screenTop - back.frame.maxY, width: back.frame.width, height: visible)
            // The panel plus whatever is below it; the opaque backdrop covers this whole rect.
            image = CGWindowListCreateImage(rect, [.optionOnScreenBelowWindow, .optionIncludingWindow], CGWindowID(panel.windowNumber), [.bestResolution])
        } else {
            image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.bestResolution])
        }
        guard let image else { return "window image unavailable" }
        return write(NSBitmapImageRep(cgImage: image), to: url, guarded: window is PalettePanel)
    }

    /// Writes the PNG. Returns why no image was saved, or nil when the file exists.
    static func write(_ rep: NSBitmapImageRep, to url: URL, guarded: Bool) -> String? {
        // Privacy guard: the edges must be the plain backdrop, or real windows showed through.
        if guarded, !edgesAreBackdrop(rep) { return "edges are not the backdrop; image discarded" }
        guard let png = rep.representation(using: .png, properties: [:]) else { return "PNG encoding failed" }
        do { try png.write(to: url) } catch { return "write failed: \(error.localizedDescription)" }
        return FileManager.default.fileExists(atPath: url.path) ? nil : "file missing after write"
    }

    /// The capture runner's result path: guard discard reports FAIL, a clean image reports ok.
    static func runChecks() throws {
        struct CheckFailure: Error, CustomStringConvertible { let description: String }
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            guard condition() else { throw CheckFailure(description: label) }
        }
        // Built from a CGImage, like a real capture.
        func image(edge: UInt32) -> NSBitmapImageRep {
            let width = 64, height = 48
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(NSColor(hex: 0x1A2130).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // The edge colour fills a band across the top, where a stray window would show.
            context.setFillColor(NSColor(hex: edge).cgColor)
            context.fill(CGRect(x: 0, y: height - 6, width: width, height: 6))
            return NSBitmapImageRep(cgImage: context.makeImage()!)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("impulse-capture-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let leaked = folder.appendingPathComponent("leaked.png")
        let discarded = write(image(edge: 0xF2F2F2), to: leaked, guarded: true)
        try check(discarded != nil, "the guard discards an image whose edge is not the backdrop")
        try check(!FileManager.default.fileExists(atPath: leaked.path), "a discarded image leaves no file")
        let failLine = report("02-app-match", failure: discarded, iconMisses: 0)
        try check(failLine.hasPrefix("FAIL 02-app-match: ") && failLine.contains("discarded"), "a discarded image reports FAIL with its reason")
        try check(!failLine.hasPrefix("ok"), "a discarded image never reports ok")

        let clean = folder.appendingPathComponent("clean.png")
        let saved = write(image(edge: 0x1A2130), to: clean, guarded: true)
        try check(saved == nil, "the guard keeps an image framed by the backdrop")
        try check(FileManager.default.fileExists(atPath: clean.path), "a kept image exists on disk")
        try check(report("01-idle", failure: saved, iconMisses: 0) == "ok 01-idle icon-misses=0", "a saved image reports ok")
        print("PASS capture checks: guard discard reports FAIL with no file; clean image saves and reports ok")
    }
}
