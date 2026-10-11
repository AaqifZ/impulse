import Foundation
import SQLite3

/// One Larynx dictation, as Impulse shows it.
public struct Dictation: Equatable, Sendable {
    public let id: String
    public let createdAt: Date
    public let textFinal: String
    public let textRaw: String

    public init(id: String, createdAt: Date, textFinal: String, textRaw: String) {
        self.id = id
        self.createdAt = createdAt
        self.textFinal = textFinal
        self.textRaw = textRaw
    }
}

/// Reads Larynx's dictation history (~/.larynx/history.db) strictly read-only.
/// It never creates, writes, or migrates the file. Larynx owns it.
/// The open handle is kept between queries; a failed read closes it, and the next query opens it again.
public final class DictationHistory {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// No history.db on this Mac.
        case missing
        /// The file exists but SQLite cannot read it.
        case unreadable(String)
        /// The file is from before Larynx kept daily totals.
        case noStats

        public var description: String {
            switch self {
            case .missing: return "No Larynx history on this Mac"
            case .unreadable: return "Larynx history is unreadable"
            case .noStats: return "No Larynx stats yet"
            }
        }
    }

    /// The most rows a query returns.
    public static let limit = 50
    public static var defaultPath: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".larynx/history.db")
    }

    public let path: URL
    private var db: OpaquePointer?

    public init(path: URL = DictationHistory.defaultPath) {
        self.path = path
    }

    /// True when Larynx has a history file. Without one, `lx` and `larynx` are ordinary searches.
    public var isAvailable: Bool { FileManager.default.fileExists(atPath: path.path) }

    deinit { close() }

    /// The newest dictations, newest first. Every word in `term` must appear in the final text (any case).
    public func recent(matching term: String = "", limit: Int = DictationHistory.limit) throws -> [Dictation] {
        let handle = try open()
        let words = term.split(whereSeparator: \.isWhitespace).map(String.init)
        // Only the number of placeholders depends on the input; the words are bound, never interpolated.
        var sql = "SELECT id, created_at, text_final, text_raw FROM dictations WHERE text_final <> ''"
        for _ in words { sql += " AND text_final LIKE ? ESCAPE '\\'" }
        sql += " ORDER BY created_at DESC, rowid DESC LIMIT ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { throw fail(handle) }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, word) in words.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), "%" + Self.escapeLike(word) + "%", -1, transient)
        }
        sqlite3_bind_int(stmt, Int32(words.count + 1), Int32(max(0, limit)))
        func text(_ column: Int32) -> String { sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? "" }
        var rows: [Dictation] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw fail(handle) }
            rows.append(Dictation(id: text(0), createdAt: date(stmt, 1), textFinal: text(2), textRaw: text(3)))
        }
        return rows
    }

    /// Larynx stores epoch seconds (REAL). ISO 8601 text is accepted too.
    private func date(_ stmt: OpaquePointer?, _ column: Int32) -> Date {
        if sqlite3_column_type(stmt, column) == SQLITE_TEXT, let raw = sqlite3_column_text(stmt, column) {
            let value = String(cString: raw)
            let iso = ISO8601DateFormatter()
            if let date = iso.date(from: value) { return date }
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return iso.date(from: value) ?? .distantPast
        }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, column))
    }

    func open() throws -> OpaquePointer {
        if let db { return db }
        // Check first: SQLITE_OPEN_READONLY never creates the file, and this gives a clear message.
        guard FileManager.default.fileExists(atPath: path.path) else { throw Failure.missing }
        var handle: OpaquePointer?
        let code = sqlite3_open_v2(path.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard code == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw Failure.unreadable(message)
        }
        sqlite3_busy_timeout(handle, 200)
        sqlite3_exec(handle, "PRAGMA query_only = 1", nil, nil, nil)
        db = handle
        return handle
    }

    func fail(_ handle: OpaquePointer) -> Failure {
        let failure = Failure.unreadable(String(cString: sqlite3_errmsg(handle)))
        close()
        return failure
    }

    private func close() {
        sqlite3_close(db)
        db = nil
    }

    /// Makes %, _ and \ match themselves in a LIKE pattern.
    static func escapeLike(_ word: String) -> String {
        var out = ""
        for character in word {
            if character == "%" || character == "_" || character == "\\" { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// A short time for a row: "just now", "2 min ago", "14:05", "yesterday 14:05", "Mon 14:05", "3 Oct".
    public static func relativeTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.dateFormat = "HH:mm"
        let time = format.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday " + time
        }
        if seconds < 6 * 86_400 {
            format.dateFormat = "EEE HH:mm"
            return format.string(from: date)
        }
        format.dateFormat = "d MMM"
        return format.string(from: date)
    }
}
