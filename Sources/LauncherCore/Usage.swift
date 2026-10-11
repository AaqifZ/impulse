import Foundation

/// One line in the usage log: a panel open, or an action that finished.
/// It never holds search words, snippet text, clipboard contents, or file paths.
public struct UsageEvent: Codable, Equatable, Sendable {
    public enum Event: String, Codable, Sendable { case open, action }
    /// How the action was reached: its alias, its name, or the list without typing.
    public enum Route: String, Codable, Sendable { case alias, name, list }

    public let t: Date
    public let ev: Event
    public let id: String?
    public let kind: ActionKind?
    public let keys: Int?
    public let ms: Int?
    public let via: Route?

    public static func open(at time: Date) -> UsageEvent {
        UsageEvent(t: time, ev: .open, id: nil, kind: nil, keys: nil, ms: nil, via: nil)
    }

    /// A finished action. File, clipboard, and dictation rows are logged by kind only.
    public static func action(_ action: LauncherAction, at time: Date, keys: Int, ms: Int, via: Route) -> UsageEvent {
        let id: String
        switch action.kind {
        case .file: id = "file"
        case .clipboard: id = "clipboard"
        case .dictation: id = "dictation"
        case .calculation, .error: id = "calculation"
        case .url, .app, .terminal, .workspace, .snippet, .application, .shortcut, .system,
             .webSearch, .laptopSearch, .emoji, .local, .theme, .accent, .stats: id = action.id
        }
        return UsageEvent(t: time, ev: .action, id: id, kind: action.kind, keys: max(0, keys), ms: max(0, ms), via: via)
    }

    /// A finished transient operation, recorded without manufacturing a saved action.
    public static func transient(kind: ActionKind, at time: Date, keys: Int, ms: Int, via: Route) -> UsageEvent {
        let id = kind == .clipboard || kind == .dictation ? kind.rawValue : "calculation"
        return UsageEvent(t: time, ev: .action, id: id, kind: kind, keys: max(0, keys), ms: max(0, ms), via: via)
    }

    /// How the typed text reached this action.
    public static func route(typed: String, action: LauncherAction) -> Route {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.isEmpty { return .list }
        let first = text.split(separator: " ").first.map(String.init) ?? text
        return action.aliases.contains { $0.lowercased().hasPrefix(text) || $0.lowercased() == first } ? .alias : .name
    }
}

/// The usage log: one JSON line per event, one file per month, in a local folder.
public final class UsageLog: @unchecked Sendable {
    public let directory: URL
    private let queue = DispatchQueue(label: "local.impulse.usage", qos: .utility)
    private static let fileFormat: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM"
        return format
    }()

    public init(directory: URL) {
        self.directory = directory
    }

    /// Appends in the background; the caller never waits on the disk.
    public func append(_ event: UsageEvent) {
        queue.async { [directory] in
            guard let line = try? Self.encoder.encode(event) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(Self.fileFormat.string(from: event.t) + ".jsonl")
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line + Data("\n".utf8))
            } else {
                try? (line + Data("\n".utf8)).write(to: url, options: .atomic)
            }
        }
    }

    /// Events from this month and the months before it. Unreadable lines are skipped.
    public func load(months: Int = 2, now: Date = Date(), calendar: Calendar = .current) -> [UsageEvent] {
        queue.sync { read(months: months, now: now, calendar: calendar) }
    }

    /// Reads at this exact point in the log queue, then delivers on the main actor.
    /// Appends requested afterwards are excluded.
    public func loadAsync(
        months: Int = 2,
        now: Date = Date(),
        calendar: Calendar = .current,
        completion: @escaping @MainActor @Sendable ([UsageEvent]) -> Void
    ) {
        queue.async { [self] in
            let events = read(months: months, now: now, calendar: calendar)
            DispatchQueue.main.async { completion(events) }
        }
    }

    private func read(months: Int, now: Date, calendar: Calendar) -> [UsageEvent] {
        var events: [UsageEvent] = []
        for back in stride(from: months - 1, through: 0, by: -1) {
            guard let month = calendar.date(byAdding: .month, value: -back, to: now) else { continue }
            let url = directory.appendingPathComponent(Self.fileFormat.string(from: month) + ".jsonl")
            guard let data = try? Data(contentsOf: url) else { continue }
            for line in data.split(separator: UInt8(ascii: "\n")) {
                if let event = try? Self.decoder.decode(UsageEvent.self, from: Data(line)) { events.append(event) }
            }
        }
        return events
    }

    /// Deletes the whole log. Throws when the log is still on disk afterwards.
    public func reset() throws {
        try queue.sync {
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            try FileManager.default.removeItem(at: directory)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let format = ISO8601DateFormatter()
        format.timeZone = .current
        encoder.dateEncodingStrategy = .custom { date, coder in
            var container = coder.singleValueContainer()
            try container.encode(format.string(from: date))
        }
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// How much each action was used lately. Each use counts 1 today and half as much a week later.
public enum UsageRanking {
    public static let halfLifeDays = 7.0

    public static func weights(_ events: [UsageEvent], now: Date = Date()) -> [String: Double] {
        var weights: [String: Double] = [:]
        for event in events where event.ev == .action {
            guard let id = event.id else { continue }
            let days = max(0, now.timeIntervalSince(event.t) / 86_400)
            weights[id, default: 0] += pow(0.5, days / halfLifeDays)
        }
        return weights
    }
}

/// The numbers the stats view shows, computed from the log on demand.
public struct UsageStats: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let id: String
        public let count: Int
        public init(id: String, count: Int) { self.id = id; self.count = count }
    }

    public let days: Int
    public let actions: Int
    public let opens: Int
    /// Actions per day, oldest first; the last value is today.
    public let daily: [Int]
    public let keysPerAction: Double?
    public let medianMs: Int?
    /// An estimate: see `manualSeconds` and `typingCharactersPerSecond`.
    public let secondsSaved: Double
    public let top: [Entry]

    /// Seconds the same task takes without Impulse. The estimate subtracts the measured time.
    /// Workspaces are absent: Impulse only requests the layout and never sees it finish.
    public static let manualSeconds: [ActionKind: Double] = [
        .url: 6, .webSearch: 6, .app: 3, .application: 3, .file: 6, .system: 4,
        .shortcut: 5, .terminal: 5, .calculation: 8, .clipboard: 4, .dictation: 4, .emoji: 5,
    ]
    /// 40 words a minute at 5 characters a word, for snippets (TextExpander's method).
    public static let typingCharactersPerSecond = 40.0 * 5 / 60

    public static func compute(
        _ events: [UsageEvent],
        now: Date = Date(),
        calendar: Calendar = .current,
        days: Int = 28,
        snippetLengths: [String: Int] = [:],
        topCount: Int = 5
    ) -> UsageStats {
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) else {
            return UsageStats(days: days, actions: 0, opens: 0, daily: Array(repeating: 0, count: days), keysPerAction: nil, medianMs: nil, secondsSaved: 0, top: [])
        }
        let window = events.filter { $0.t >= start && $0.t <= now }
        let actions = window.filter { $0.ev == .action }
        var daily = Array(repeating: 0, count: days)
        var counts: [String: Int] = [:]
        var saved = 0.0
        // Calendar maths per event is slow; compare against the day starts once computed.
        let dayStarts = (0..<days).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        for event in actions {
            if let day = dayStarts.lastIndex(where: { $0 <= event.t }) { daily[day] += 1 }
            if let id = event.id { counts[id, default: 0] += 1 }
            saved += secondsSaved(by: event, snippetLengths: snippetLengths)
        }
        let keys = actions.compactMap(\.keys)
        let times = actions.compactMap(\.ms).sorted()
        let top = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(topCount).map { Entry(id: $0.key, count: $0.value) }
        return UsageStats(
            days: days,
            actions: actions.count,
            opens: window.filter { $0.ev == .open }.count,
            daily: daily,
            keysPerAction: keys.isEmpty ? nil : Double(keys.reduce(0, +)) / Double(keys.count),
            medianMs: times.isEmpty ? nil : times[times.count / 2],
            secondsSaved: saved,
            top: Array(top)
        )
    }

    static func secondsSaved(by event: UsageEvent, snippetLengths: [String: Int]) -> Double {
        guard let kind = event.kind else { return 0 }
        if kind == .snippet {
            guard let id = event.id, let length = snippetLengths[id] else { return 0 }
            return Double(max(0, length - (event.keys ?? 0))) / typingCharactersPerSecond
        }
        return max(0, (manualSeconds[kind] ?? 0) - Double(event.ms ?? 0) / 1000)
    }

    /// "2h 41m", "7m", or "40s".
    public static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 { return "\(total / 3600)h \((total % 3600) / 60)m" }
        if total >= 60 { return "\(total / 60)m" }
        return "\(total)s"
    }
}
