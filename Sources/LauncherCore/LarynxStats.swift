import Foundation
import SQLite3

/// The `larynx` dashboard: Larynx's own daily totals for the last 28 days. Numbers only, never text.
public struct LarynxStats: Equatable, Sendable {
    /// One "Where you talk" row.
    public struct AppShare: Equatable, Sendable {
        public enum Name: Equatable, Sendable {
            /// A bundle ID, as Larynx records it. The app turns it into a display name.
            case app(String)
            /// The words of every app below the top four.
            case other
            /// Rows recorded before Larynx kept the app name ('unknown').
            case unrecorded
        }

        public let name: Name
        public let words: Int

        public init(name: Name, words: Int) {
            self.name = name
            self.words = words
        }
    }

    public static let days = 28
    /// The most dictations the median reads.
    public static let medianSample = 1_000
    /// Typing speed the estimates compare against.
    public static let typingWPM = 40.0

    /// Words per day, oldest first; the last entry is today.
    public var daily: [Int]
    public var dictations: Int
    public var words: Int
    public var talkSeconds: Double
    public var fixes: Int
    public var keptSafe: Int
    public var currentStreak: Int
    public var longestStreak: Int
    public var medianTranscribeMs: Double?
    public var apps: [AppShare]
    /// The first day of the window, local.
    public var start: Date

    public init(daily: [Int], dictations: Int, words: Int, talkSeconds: Double, fixes: Int, keptSafe: Int,
                currentStreak: Int, longestStreak: Int, medianTranscribeMs: Double?, apps: [AppShare], start: Date) {
        self.daily = daily
        self.dictations = dictations
        self.words = words
        self.talkSeconds = talkSeconds
        self.fixes = fixes
        self.keptSafe = keptSafe
        self.currentStreak = currentStreak
        self.longestStreak = longestStreak
        self.medianTranscribeMs = medianTranscribeMs
        self.apps = apps
        self.start = start
    }

    /// Typing time for these words minus talking time, never below zero.
    public var secondsSaved: Double {
        max(0, Double(words) / Self.typingWPM * 60 - talkSeconds)
    }

    /// Words a minute while talking; nil with no talk time.
    public var wordsPerMinute: Int? {
        guard talkSeconds > 0 else { return nil }
        return Int((Double(words) / (talkSeconds / 60)).rounded())
    }

    /// How many times faster than typing, one decimal.
    public var timesTyping: String? {
        guard talkSeconds > 0 else { return nil }
        return String(format: "%.1f", Double(words) / (talkSeconds / 60) / Self.typingWPM)
    }

    public var appWords: Int { apps.reduce(0) { $0 + $1.words } }

    /// The current streak ends today, or yesterday when today has no dictation yet.
    /// `active` holds local 'YYYY-MM-DD' days with at least one dictation, in any order.
    /// Days become serial numbers, so the work is arithmetic, not calendar math (ten years in well under a millisecond).
    public static func streaks(_ active: [String], today: Date, calendar: Calendar = .current) -> (current: Int, longest: Int) {
        let days = Set(active.compactMap(serial))
        let parts = calendar.dateComponents([.year, .month, .day], from: today)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return (0, 0) }
        var longest = 0
        for start in days where !days.contains(start - 1) {
            var length = 1
            while days.contains(start + length) { length += 1 }
            longest = max(longest, length)
        }
        var cursor = serial(year: year, month: month, day: day)
        if !days.contains(cursor) { cursor -= 1 }
        var current = 0
        while days.contains(cursor) { current += 1; cursor -= 1 }
        return (current, longest)
    }

    /// Days since a fixed origin for a 'YYYY-MM-DD' string; nil when it is not one.
    static func serial(_ text: String) -> Int? {
        let fields = text.split(separator: "-")
        guard fields.count == 3, fields[0].count == 4, let year = Int(fields[0]), let month = Int(fields[1]), let day = Int(fields[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        return serial(year: year, month: month, day: day)
    }

    /// Proleptic Gregorian day number (days from civil, Howard Hinnant).
    static func serial(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe
    }

    /// Top four apps by words, then Other. 'unknown' gets its own row only when it holds most words.
    public static func shares(_ named: [(app: String, words: Int)], unknown: Int, total: Int) -> [AppShare] {
        guard total > 0 else { return [] }
        let majority = unknown * 2 > total
        let top = named.filter { $0.words > 0 }.prefix(majority ? 3 : 4)
        var rows: [AppShare] = majority ? [AppShare(name: .unrecorded, words: unknown)] : []
        rows += top.map { AppShare(name: .app($0.app), words: $0.words) }
        let rest = total - rows.reduce(0) { $0 + $1.words }
        if rest > 0 { rows.append(AppShare(name: .other, words: rest)) }
        return rows
    }

    /// The local 'YYYY-MM-DD' string Larynx uses for a day.
    public static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

extension DictationHistory {
    /// The dashboard numbers for the 28 days ending today. Aggregate queries only; no text column is read.
    /// Throws `.noStats` for a file from before Larynx kept daily totals.
    public func dashboard(now: Date = Date(), calendar: Calendar = .current) throws -> LarynxStats {
        let handle = try open()
        guard try scalarInt(handle, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('daily', 'daily_apps')") == 2 else {
            throw Failure.noStats
        }
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(LarynxStats.days - 1), to: today) ?? today
        let first = LarynxStats.dayString(start, calendar: calendar), last = LarynxStats.dayString(today, calendar: calendar)
        let firstSerial = LarynxStats.serial(first) ?? 0

        var daily = Array(repeating: 0, count: LarynxStats.days)
        var stats = LarynxStats(daily: [], dictations: 0, words: 0, talkSeconds: 0, fixes: 0, keptSafe: 0,
                                currentStreak: 0, longestStreak: 0, medianTranscribeMs: nil, apps: [], start: start)
        try rows(handle, "SELECT day, dictations, words, talk_s, fixes, kept_safe FROM daily WHERE day BETWEEN ? AND ? ORDER BY day LIMIT 64",
                 [first, last]) { stmt in
            let day = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let words = Int(sqlite3_column_int64(stmt, 2))
            if let serial = LarynxStats.serial(day), daily.indices.contains(serial - firstSerial) {
                daily[serial - firstSerial] += words
            }
            stats.dictations += Int(sqlite3_column_int64(stmt, 1))
            stats.words += words
            stats.talkSeconds += sqlite3_column_double(stmt, 3)
            stats.fixes += Int(sqlite3_column_int64(stmt, 4))
            stats.keptSafe += Int(sqlite3_column_int64(stmt, 5))
        }
        stats.daily = daily

        // Streaks use the whole table (daily totals are never pruned); ten years of days at most.
        var active: [String] = []
        try rows(handle, "SELECT day FROM daily WHERE dictations > 0 AND day <= ? ORDER BY day DESC LIMIT 3660", [last]) { stmt in
            if let text = sqlite3_column_text(stmt, 0) { active.append(String(cString: text)) }
        }
        (stats.currentStreak, stats.longestStreak) = LarynxStats.streaks(active, today: now, calendar: calendar)

        var total = 0, unknown = 0
        try rows(handle, "SELECT COALESCE(SUM(words), 0), COALESCE(SUM(CASE WHEN app = 'unknown' THEN words END), 0) FROM daily_apps WHERE day BETWEEN ? AND ?",
                 [first, last]) { stmt in
            total = Int(sqlite3_column_int64(stmt, 0))
            unknown = Int(sqlite3_column_int64(stmt, 1))
        }
        var named: [(app: String, words: Int)] = []
        try rows(handle, "SELECT app, SUM(words) AS w FROM daily_apps WHERE day BETWEEN ? AND ? AND app <> 'unknown' GROUP BY app ORDER BY w DESC, app LIMIT 4",
                 [first, last]) { stmt in
            named.append((sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "", Int(sqlite3_column_int64(stmt, 1))))
        }
        stats.apps = LarynxStats.shares(named, unknown: unknown, total: total)

        // Median time to text, over the newest 1,000 timed dictations in the window (the created_at index walks them).
        // An older file without the column has no median.
        let timed = try scalarInt(handle, "SELECT COUNT(*) FROM pragma_table_info('dictations') WHERE name = 'transcribe_ms'") == 1
        if timed {
            var values: [Double] = []
            try rows(handle, "SELECT transcribe_ms FROM dictations WHERE created_at >= \(start.timeIntervalSince1970) AND transcribe_ms IS NOT NULL ORDER BY created_at DESC LIMIT \(LarynxStats.medianSample)", []) { stmt in
                values.append(sqlite3_column_double(stmt, 0))
            }
            values.sort()
            if !values.isEmpty {
                let middle = values.count / 2
                stats.medianTranscribeMs = values.count % 2 == 1 ? values[middle] : (values[middle - 1] + values[middle]) / 2
            }
        }
        return stats
    }

    private func scalarInt(_ handle: OpaquePointer, _ sql: String) throws -> Int {
        var value = 0
        try rows(handle, sql, []) { value = Int(sqlite3_column_int64($0, 0)) }
        return value
    }

    private func rows(_ handle: OpaquePointer, _ sql: String, _ texts: [String], _ each: (OpaquePointer?) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { throw fail(handle) }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, text) in texts.enumerated() { sqlite3_bind_text(stmt, Int32(index + 1), text, -1, transient) }
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { return }
            guard code == SQLITE_ROW else { throw fail(handle) }
            each(stmt)
        }
    }
}
