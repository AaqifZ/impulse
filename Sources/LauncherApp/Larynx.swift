import AppKit
import LauncherCore
import SQLite3

/// The `larynx` dashboard. Larynx owns ~/.larynx/history.db; Impulse only reads its daily totals.
extension AppDelegate {
    /// The dashboard card, or one notice row when there are no stats to read.
    func larynxResults() -> [PanelItem] {
        do {
            return [.larynx(try dictations.dashboard())]
        } catch let failure as DictationHistory.Failure {
            switch failure {
            case .missing, .noStats: return [.notice("No Larynx stats yet")]
            case .unreadable: return [.notice(failure.description)]
            }
        } catch {
            return [.notice("Larynx history is unreadable")]
        }
    }
}

/// Display names for the bundle IDs Larynx records. Looked up once per ID.
enum AppNames {
    private static var cache: [String: String] = [:]

    static func name(_ bundleID: String) -> String {
        if let known = cache[bundleID] { return known }
        var name = bundleID
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let bundle = Bundle(url: url)
            let display = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            // Drop invisible format characters (WhatsApp's name starts with a left-to-right mark).
            let clean = String(String.UnicodeScalarView(display.unicodeScalars.filter { $0.properties.generalCategory != .format }))
                .trimmingCharacters(in: .whitespaces)
            if !clean.isEmpty { name = clean }
        }
        cache[bundleID] = name
        return name
    }

    static func label(_ share: LarynxStats.AppShare) -> String {
        switch share.name {
        case .app(let id): return name(id)
        case .other: return "Other"
        case .unrecorded: return "Earlier, app not recorded"
        }
    }
}

/// The `larynx` card: three headline numbers, the streak, a 28-day strip, where you talk, and Larynx at work.
/// Drawn in one pass, like the `stats` card.
final class LarynxCardView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("launcher-larynx-card")
    private var stats: LarynxStats?
    private var theme = Theme.signal(accent: "volt")
    private static let dayFormat: DateFormatter = {
        let format = DateFormatter()
        format.setLocalizedDateFormatFromTemplate("MMM d")
        return format
    }()

    // Vertical layout, top down (flipped view).
    private static let streakY: CGFloat = 86
    private static let stripTop: CGFloat = 112, stripBase: CGFloat = 140
    private static let talkLabelY: CGFloat = 174
    private static let talkRowsY: CGFloat = 194, talkRow: CGFloat = 21
    private static let tileHeight: CGFloat = 66

    /// The card grows with the number of "Where you talk" rows (one line when there are none).
    static func height(for stats: LarynxStats) -> CGFloat {
        let rows = CGFloat(max(1, stats.apps.count))
        return talkRowsY + rows * talkRow + 12 + 20 + tileHeight + 12
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func configure(_ stats: LarynxStats, theme: Theme) {
        self.stats = stats
        self.theme = theme
        var label = "\(stats.words.formatted()) words in \(stats.dictations.formatted()) dictations, about \(UsageStats.duration(stats.secondsSaved)) saved"
        if let speed = stats.wordsPerMinute { label += ", \(speed) words a minute" }
        setAccessibilityLabel(label + ", \(stats.currentStreak) day streak")
        needsDisplay = true
    }

    private func text(_ string: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular, _ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let stats else { return }
        let left: CGFloat = 26, right = bounds.width - 26

        // Headline numbers.
        let typing = Int(LarynxStats.typingWPM)
        let metrics: [(label: String, value: String, unit: String, note: String, accent: Bool)] = [
            ("Words", stats.words.formatted(), "", stats.dictations == 1 ? "1 dictation" : "\(stats.dictations.formatted()) dictations", false),
            ("Time saved · est", UsageStats.duration(stats.secondsSaved), "", "vs typing at \(typing) wpm", true),
            ("Your speed", stats.wordsPerMinute.map { $0.formatted() } ?? "–", stats.wordsPerMinute == nil ? "" : "wpm",
             stats.timesTyping.map { "\($0)× typing at \(typing) wpm" } ?? "no talk time yet", false),
        ]
        let column = (right - left) / CGFloat(metrics.count)
        for (index, metric) in metrics.enumerated() {
            let x = left + CGFloat(index) * column
            theme.labelText(metric.label, size: 10).draw(at: NSPoint(x: x, y: 10))
            let value = text(metric.value, 28, .semibold, metric.accent ? theme.accent : theme.text)
            value.draw(at: NSPoint(x: x - 1, y: 24))
            if !metric.unit.isEmpty {
                let unit = text(metric.unit, 15, .medium, theme.secondary)
                unit.draw(at: NSPoint(x: x + value.size().width + 5, y: 24 + value.size().height - unit.size().height - 4))
            }
            text(metric.note, 12, .regular, theme.secondary).draw(at: NSPoint(x: x, y: 60))
        }

        // Streak.
        var x = left
        for (count, words) in [(stats.currentStreak, "day streak"), (stats.longestStreak, "longest")] {
            let number = text(count.formatted(), 15, .semibold, theme.accent)
            number.draw(at: NSPoint(x: x, y: Self.streakY))
            x += number.size().width + 5
            let caption = text(words, 13, .regular, theme.rowTitle)
            caption.draw(at: NSPoint(x: x, y: Self.streakY + 2))
            x += caption.size().width + 22
        }

        // One bar per day, oldest on the left; today in the accent.
        let days = stats.daily.count
        if days > 0 {
            let gap: CGFloat = 3, top = Self.stripTop, base = Self.stripBase
            let width = (right - left - gap * CGFloat(days - 1)) / CGFloat(days)
            let peak = max(1, stats.daily.max() ?? 1)
            for (index, count) in stats.daily.enumerated() {
                let height = max(2, (base - top) * CGFloat(count) / CGFloat(peak))
                let bar = NSRect(x: left + CGFloat(index) * (width + gap), y: base - height, width: width, height: height)
                (index == days - 1 ? theme.accent : theme.tileBorder).setFill()
                NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
            }
            theme.labelText(Self.dayFormat.string(from: stats.start), size: 10).draw(at: NSPoint(x: left, y: base + 6))
            let last = theme.labelText("Today", size: 10)
            last.draw(at: NSPoint(x: right - last.size().width, y: base + 6))
        }

        // Where you talk.
        theme.labelText("Where you talk", size: 10).draw(at: NSPoint(x: left, y: Self.talkLabelY))
        let total = max(1, stats.appWords)
        let nameWidth: CGFloat = 170, percentWidth: CGFloat = 40
        let trackLeft = left + nameWidth + 12, trackRight = right - percentWidth - 8
        if stats.apps.isEmpty {
            text("No dictations in the last 28 days", 13, .regular, theme.secondary).draw(at: NSPoint(x: left, y: Self.talkRowsY))
        }
        for (index, share) in stats.apps.enumerated() {
            let y = Self.talkRowsY + CGFloat(index) * Self.talkRow
            let name = Self.truncatedMiddle(AppNames.label(share), width: nameWidth, font: .systemFont(ofSize: 13))
            text(name, 13, .regular, theme.rowTitle).draw(at: NSPoint(x: left, y: y))
            let track = NSRect(x: trackLeft, y: y + 6, width: trackRight - trackLeft, height: 5)
            theme.tileFill.setFill()
            NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
            let fraction = CGFloat(share.words) / CGFloat(total)
            let fill = NSRect(x: track.minX, y: track.minY, width: max(4, track.width * fraction), height: track.height)
            (index == 0 ? theme.accent : theme.secondary.withAlphaComponent(0.55)).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 2.5, yRadius: 2.5).fill()
            let percent = NSAttributedString(string: "\(Int((fraction * 100).rounded()))%", attributes: [
                .font: theme.monoFont(11), .foregroundColor: theme.secondary,
            ])
            percent.draw(at: NSPoint(x: right - percent.size().width, y: y + 1))
        }

        // Larynx at work.
        let workLabelY = Self.talkRowsY + CGFloat(max(1, stats.apps.count)) * Self.talkRow + 12
        theme.labelText("Larynx at work", size: 10).draw(at: NSPoint(x: left, y: workLabelY))
        let tiles: [(String, String, String)] = [
            ("Lands in", stats.medianTranscribeMs.map { String(format: "%.2f s", $0 / 1000) } ?? "–",
             stats.medianTranscribeMs == nil ? "no timings yet" : "median"),
            ("Words fixed", stats.fixes.formatted(), "fillers, names"),
            ("Kept safe", stats.keptSafe.formatted(), "no text box, on clipboard"),
        ]
        let tileGap: CGFloat = 12
        let tileWidth = (right - left - tileGap * 2) / 3
        let tileTop = workLabelY + 20
        for (index, tile) in tiles.enumerated() {
            let rect = NSRect(x: left + CGFloat(index) * (tileWidth + tileGap), y: tileTop, width: tileWidth, height: Self.tileHeight)
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: theme.rowRadius, yRadius: theme.rowRadius)
            theme.tileFill.setFill()
            path.fill()
            theme.tileBorder.setStroke()
            path.lineWidth = 1
            path.stroke()
            text(tile.0, 12, .regular, theme.secondary).draw(at: NSPoint(x: rect.minX + 12, y: rect.minY + 9))
            text(tile.1, 17, .semibold, theme.text).draw(at: NSPoint(x: rect.minX + 12, y: rect.minY + 25))
            let note = Self.truncatedMiddle(tile.2, width: rect.width - 24, font: .systemFont(ofSize: 11))
            text(note, 11, .regular, theme.secondary).draw(at: NSPoint(x: rect.minX + 12, y: rect.minY + 47))
        }
    }

    /// Cuts the middle of a name that does not fit, so both ends stay readable.
    static func truncatedMiddle(_ value: String, width: CGFloat, font: NSFont) -> String {
        func fits(_ text: String) -> Bool { (text as NSString).size(withAttributes: [.font: font]).width <= width }
        guard !fits(value) else { return value }
        let characters = Array(value)
        var keep = characters.count - 1
        while keep > 1 {
            let head = keep - keep / 2, tail = keep / 2
            let candidate = String(characters.prefix(head)) + "…" + String(characters.suffix(tail))
            if fits(candidate) { return candidate }
            keep -= 1
        }
        return "…"
    }
}

/// Made-up Larynx histories for self-tests and captures, written to a temporary folder. Never ~/.larynx.
enum LarynxFixture: String, CaseIterable {
    /// 28 busy days with a gap, five apps.
    case full
    /// The tables exist, with no rows.
    case empty
    /// One day: today.
    case today
    /// A million words and an app name too long to fit.
    case huge
    /// Every row from before Larynx recorded the app.
    case unknown
    /// An older history with no daily tables.
    case old

    static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("impulse-larynx-fixtures", isDirectory: true)

    /// Writes the fixture (fresh each time) and returns its path.
    func write(now: Date = Date(), calendar: Calendar = .current) throws -> URL {
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let url = Self.folder.appendingPathComponent("\(rawValue).db")
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw DictationHistory.Failure.unreadable("fixture")
        }
        defer { sqlite3_close(db) }
        var sql = """
            CREATE TABLE dictations(id TEXT PRIMARY KEY, created_at REAL NOT NULL, text_raw TEXT NOT NULL, text_final TEXT NOT NULL,
              style TEXT NOT NULL, model TEXT NOT NULL, cleanup TEXT NOT NULL, duration_s REAL NOT NULL, landed TEXT NOT NULL,
              transcribe_ms REAL, clean_ms REAL, app TEXT, words INTEGER, fixes INTEGER);
            CREATE INDEX dictations_created ON dictations(created_at);
            """
        if self != .old {
            sql += """
                CREATE TABLE daily(day TEXT PRIMARY KEY, dictations INTEGER NOT NULL, words INTEGER NOT NULL, talk_s REAL NOT NULL,
                  fixes INTEGER NOT NULL, kept_safe INTEGER NOT NULL);
                CREATE TABLE daily_apps(day TEXT NOT NULL, app TEXT NOT NULL, dictations INTEGER NOT NULL, words INTEGER NOT NULL, PRIMARY KEY(day, app));
                """
        }
        sql += "BEGIN;"
        let today = calendar.startOfDay(for: now)
        func day(_ back: Int) -> String { LarynxStats.dayString(calendar.date(byAdding: .day, value: -back, to: today) ?? today, calendar: calendar) }
        func row(_ back: Int, dictations: Int, words: Int, wpm: Double, apps: [(String, Double)]) {
            sql += "INSERT INTO daily VALUES('\(day(back))', \(dictations), \(words), \(Double(words) / wpm * 60), \(words / 30), \(max(0, dictations / 12)));"
            for (app, share) in apps {
                sql += "INSERT INTO daily_apps VALUES('\(day(back))', '\(app)', \(max(1, Int(Double(dictations) * share))), \(Int(Double(words) * share)));"
            }
        }
        let mix = [("com.anthropic.claudefordesktop", 0.52), ("com.tinyspeck.slackmacgap", 0.18), ("dev.zed.Zed", 0.12),
                   ("com.apple.Notes", 0.08), ("com.apple.mail", 0.06), ("com.apple.Safari", 0.04)]
        switch self {
        case .full:
            for back in 0..<28 where back != 9 && back != 23 {
                let date = calendar.date(byAdding: .day, value: -back, to: today) ?? today
                let weekend = calendar.isDateInWeekend(date)
                let words = back == 0 ? 640 : (weekend ? 140 : 520) + (back * 97) % 380
                row(back, dictations: words / 32, words: words, wpm: 168, apps: mix)
            }
            // An older run: the longest streak is 14 days.
            for back in 30..<44 { row(back, dictations: 10, words: 300, wpm: 160, apps: [("unknown", 1)]) }
        case .empty, .old: break
        case .today:
            row(0, dictations: 84, words: 2_681, wpm: 178, apps: [("com.anthropic.claudefordesktop", 0.73), ("com.tinyspeck.slackmacgap", 0.14), ("dev.zed.Zed", 0.09), ("unknown", 0.04)])
        case .huge:
            for back in 0..<28 {
                row(back, dictations: 893, words: back == 0 ? 1_000_000 - 27 * 35_000 : 35_000, wpm: 171,
                    apps: [("com.example.an-extremely-long-application-name-that-never-seems-to-end.helper", 0.61), ("com.anthropic.claudefordesktop", 0.2),
                           ("com.tinyspeck.slackmacgap", 0.1), ("dev.zed.Zed", 0.05), ("com.apple.Notes", 0.04)])
            }
        case .unknown:
            for back in 0..<5 { row(back, dictations: 19, words: 640, wpm: 178, apps: [("unknown", 1)]) }
        }
        if self != .empty {
            // Timings for the median: 0.16 s to 0.31 s.
            for index in 0..<60 {
                let at = now.timeIntervalSince1970 - Double(index) * 3_600
                sql += "INSERT INTO dictations VALUES('f\(index)', \(at), 'fixture raw', 'Fixture text', 'plain', 'm', 'none', 2, 'clipboard', \(160 + (index * 37) % 150), 1, NULL, 9, 0);"
            }
        }
        sql += "COMMIT;"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DictationHistory.Failure.unreadable(String(cString: sqlite3_errmsg(db)))
        }
        return url
    }
}
