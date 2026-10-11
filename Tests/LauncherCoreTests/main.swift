import Foundation
import LauncherCore
import SQLite3

private struct TestFailure: Error, CustomStringConvertible { let description: String }

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func set(_ value: Value) { lock.withLock { self.value = value } }
    func get() -> Value? { lock.withLock { value } }
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw TestFailure(description: message) }
}

private func expectError(_ expected: LauncherError, _ body: () throws -> Void) throws {
    do {
        try body()
        throw TestFailure(description: "expected \(expected), but no error was thrown")
    } catch let error as LauncherError {
        try expect(error == expected, "expected \(expected), got \(error)")
    }
}

private func expectLauncherError(_ body: () throws -> Void) throws {
    do {
        try body()
        throw TestFailure(description: "expected LauncherError, but no error was thrown")
    } catch is LauncherError {}
}

private func action(_ id: String, _ name: String, _ aliases: [String], _ target: String) -> LauncherAction {
    LauncherAction(id: id, name: name, aliases: aliases, kind: .url, target: target)
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func write(_ config: LauncherConfig, to url: URL) throws {
    try JSONEncoder().encode(config).write(to: url)
}

@main
struct LauncherCoreTestRunner {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("longest multiword alias", testLongestAlias),
            ("alias suggestions", testAliasSuggestions),
            ("canonical config update", testCanonicalUpdate),
            ("emoji search and frequent use", testEmoji),
            ("larynx dictation routing", testDictationRouting),
            ("larynx dictation reader", testDictationReader),
            ("larynx dashboard aggregates", testLarynxAggregates),
            ("larynx dashboard reader", testLarynxDashboard),
            ("inline alias search", testInlineAliasSearch),
            ("stable fuzzy search", testStableSearch),
            ("app ranking independent of discovery order", {
                let installer = LauncherAction(id: "installer", name: "1Password Installer", aliases: ["1password installer"], kind: .application, target: "/Applications/1Password Installer.app")
                let app = LauncherAction(id: "password", name: "1Password", aliases: [], kind: .application, target: "/Applications/1Password.app")
                let other = action("other", "1Password Help", [], "https://example.com")
                let engine = ActionEngine(config: LauncherConfig(version: 1, actions: [installer, other, app]))
                try expect(engine.search("1password").first?.id == app.id, "exact app name must beat prefix aliases")
                let withAliases = LauncherAction(id: app.id, name: app.name, aliases: ["1password"], kind: app.kind, target: app.target)
                let prefixes = ActionEngine(config: LauncherConfig(version: 1, actions: [installer, withAliases]))
                for query in ["1", "1p", "1pass", "1password"] {
                    try expect(prefixes.search(query).first?.id == app.id, "main app must lead for \(query)")
                }
                try expect(prefixes.search("1password installer").first?.id == installer.id, "explicit installer remains accessible")
                let alias = action("chosen", "Chosen destination", ["1"], "https://example.com")
                let explicit = ActionEngine(config: LauncherConfig(version: 1, actions: [alias, withAliases]))
                try expect(explicit.search("1").first?.id == alias.id, "explicit aliases retain priority")
                let hashed = LauncherAction(id: "runtime.app.123abc", name: "Safari", aliases: ["safari"], kind: .application, target: "/Applications/Safari.app")
                let runtime = ActionEngine(config: LauncherConfig(version: 1, actions: [hashed]))
                try expect(runtime.search("123").isEmpty, "internal app hashes must not match user queries")
                let imported = action("app-slack-505b272fdfe3", "Slack", ["slack"], "https://example.com")
                let importedEngine = ActionEngine(config: LauncherConfig(version: 1, actions: [imported]))
                try expect(importedEngine.search("saf").isEmpty, "imported IDs must not create fuzzy matches")
            }),
            ("appearance settings defaults and round trip", testAppearanceSettings),
            ("display rounding and name cleanup", testDisplayFormat),
            ("missing query", testMissingQuery),
            ("URL injection encoding", testURLInjection),
            ("canonical selected action", testCanonicalAction),
            ("snippet date and cursor", testSnippet),
            ("unsupported snippet placeholder", testUnsupportedSnippet),
            ("unknown input", testUnknownInput),
            ("bare domain routing", testBareDomain),
            ("explicit web URL routing", testExplicitWebURL),
            ("configured alias beats direct URL", testAliasBeatsDirectURL),
            ("unsafe direct URL inputs", testUnsafeDirectURLs),
            ("forged direct URL action", testForgedDirectURLAction),
            ("workspace alias routing", testWorkspaceAliasRouting),
            ("workspace target validation", testWorkspaceTargetValidation),
            ("duplicate ID", testDuplicateID),
            ("duplicate alias", testDuplicateAlias),
            ("invalid URL templates", testInvalidURLs),
            ("invalid apply safety", testInvalidApply),
            ("apply rollback", testRollback),
            ("snapshot consistency", testSnapshot),
            ("status path", testStatusPath),
            ("empty YouTube query opens homepage", {
                let youtube = LauncherAction(id: "youtube", name: "YouTube", aliases: ["y"], kind: .url, target: "https://www.youtube.com/results?search_query={query}", browser: "com.example.browser", emptyQueryTarget: "https://www.youtube.com/")
                let engine = ActionEngine(config: try LauncherConfig(version: 1, actions: [youtube]).validated())
                for query in ["", "  \n"] {
                    let result = try engine.resolveQueryMode(action: youtube, query: query)
                    try expect(result.value == "https://www.youtube.com/" && result.browser == "com.example.browser", "empty query fallback")
                }
                try expect(try engine.resolveQueryMode(action: youtube, query: "cats & dogs").value == "https://www.youtube.com/results?search_query=cats%20%26%20dogs", "nonempty search preserved")
                try expect(try engine.resolve("y").value == youtube.emptyQueryTarget, "bare alias opens homepage")
                try expect(try engine.resolve(action: youtube, query: " \n").value == youtube.emptyQueryTarget, "selected result opens homepage")
                let unsafe = LauncherAction(id: "bad", name: "Bad", aliases: ["b"], kind: .url, target: youtube.target, emptyQueryTarget: "file:///tmp/test")
                try expectLauncherError { _ = try LauncherConfig(version: 1, actions: [unsafe]).validated() }
            }),
            ("terminal file routing", {
                let terminal = LauncherAction(id: "terminal.codex", name: "Codex in Terminal", aliases: ["codex"], kind: .terminal, target: "/private/tmp/Codex.command")
                let config = try LauncherConfig(version: 1, actions: [terminal]).validated()
                let result = try ActionEngine(config: config).resolve("codex")
                try expect(result.kind == .terminal && result.value == terminal.target, "terminal resolution")
                try expectLauncherError { _ = try ActionEngine(config: config).resolve("codex extra") }
                for target in ["codex", "https://example.com/x.command", "/tmp/a.sh", "/tmp/{query}.command"] {
                    try expectLauncherError { _ = try LauncherConfig(version: 1, actions: [LauncherAction(id: "t", name: "T", aliases: ["t"], kind: .terminal, target: target)]).validated() }
                }
            }),
            ("recent use ranks prefix matches", {
                let chess = LauncherAction(id: "chess", name: "Chess", aliases: ["chess"], kind: .application, target: "/System/Applications/Chess.app")
                let chatgpt = LauncherAction(id: "chatgpt", name: "ChatGPT", aliases: ["chatgpt"], kind: .application, target: "/Applications/ChatGPT.app")
                let calendar = action("cal", "Calendar", ["cal"], "https://calendar.google.com")
                var router = QueryRouter(configured: [calendar], discovered: [chess, chatgpt])
                func ids(_ input: String) -> [String] {
                    if case .results(let list) = router.route(input) { return list.compactMap(\.action).map(\.id) }
                    return []
                }
                try expect(ids("c").first == "chess", "with no history, the shorter app name wins")
                let now = Date()
                let events = (0..<3).map { UsageEvent.action(chatgpt, at: now.addingTimeInterval(-Double($0) * 3600), keys: 1, ms: 400, via: .name) }
                router.usage = UsageRanking.weights(events, now: now)
                try expect(ids("c").first == "chatgpt", "a much-used app wins on its first letter")
                try expect(ids("ch").prefix(2) == ["chatgpt", "chess"], "use reorders, never removes")
                try expect(ids("cal").first == "cal", "an exact alias still wins over use")
                let weekOld = UsageRanking.weights([UsageEvent.action(chatgpt, at: now.addingTimeInterval(-7 * 86_400), keys: 1, ms: 400, via: .name)], now: now)
                try expect(abs((weekOld["chatgpt"] ?? 0) - 0.5) < 0.001, "a use counts half after a week")
            }),
            ("invisible characters in app names", {
                // WhatsApp's display name starts with U+200E, a left-to-right mark.
                let whatsapp = LauncherAction(id: "wa", name: "\u{200E}WhatsApp", aliases: ["\u{200E}whatsapp"], kind: .application, target: "/Applications/WhatsApp.app")
                let router = QueryRouter(configured: [], discovered: [whatsapp])
                for input in ["w", "whats", "WhatsApp", "whats app"] {
                    guard case .results(let list) = router.route(input), list.first?.action?.id == "wa" else {
                        throw TestFailure(description: "\(input) did not find WhatsApp")
                    }
                }
            }),
            ("validated text is the text that runs", {
                let padded = LauncherAction(id: "safari", name: "Safari", aliases: ["saf"], kind: .app, target: " com.apple.Safari ")
                try expectLauncherError { _ = try LauncherConfig(version: 1, actions: [padded]).validated() }
                let paddedID = LauncherAction(id: " safari", name: "Safari", aliases: ["saf"], kind: .app, target: "com.apple.Safari")
                try expectLauncherError { _ = try LauncherConfig(version: 1, actions: [paddedID]).validated() }
                let snippet = LauncherAction(id: "sig", name: "Signature", aliases: ["sig"], kind: .snippet, target: "\n-- Sam\n")
                _ = try LauncherConfig(version: 1, actions: [snippet]).validated()
            }),
            ("aliases match the same way everywhere", {
                let google = action("google", "Google", ["G"], "https://example.invalid/find?q={query}")
                let config = try LauncherConfig(version: 1, actions: [google]).validated()
                try expect(try ActionEngine(config: config).resolve("g cats").value == "https://example.invalid/find?q=cats", "engine resolves an uppercase alias")
                let router = QueryRouter(configured: config.actions)
                let fallback = router.defaultSearches("cats")
                try expect(fallback[0].target == "https://example.invalid/find?q=cats", "fallback uses the configured search")
                try expect(router.configuredSearch(for: fallback[0])?.id == "google", "query mode finds the configured search")
            }),
            ("query routing", {
                let google = action("google", "Google Search", ["g"], "https://www.google.com/search?q={query}")
                let github = action("github", "GitHub", ["gh"], "https://github.com")
                let app = LauncherAction(id: "one", name: "1Password", aliases: [], kind: .application, target: "/Applications/1Password.app")
                let router = QueryRouter(configured: [google, github], discovered: [app], fileExists: { $0 == "/tmp/real" })
                func first(_ input: String) -> QueryResult? {
                    if case .results(let list) = router.route(input) { return list.first }
                    return nil
                }
                try expect(router.route("clip notes") == .clipboard(term: "notes"), "clip term")
                try expect(router.route("Clipboard") == .clipboard(term: ""), "clipboard keyword")
                try expect(router.route("shortcuts") == .shortcuts && router.route("system") == .system, "keywords")
                try expect(router.route("Appearance") == .theme, "theme word")
                try expect(router.route("Stats") == .stats && router.route("stats reset") == .statsReset, "stats words")
                try expect(!QueryRouter.wantsExtendedSearch("stats", firstResult: nil), "stats skips file search")
                try expect(router.route("files report") == .results([]), "files prefix waits for file search")
                try expect(first("gh")?.action?.id == "github", "exact alias")
                guard case .answer(let calculation)? = first("2 * (3 + 4)") else { throw TestFailure(description: "calculator answer type") }
                try expect(calculation.value == "14" && calculation.detail == "2 * (3 + 4) = 14", "calculator")
                try expect(first("1")?.action?.id == "one", "a bare number keeps app matches")
                try expect(first("/tmp/real")?.action?.kind == .file && first("/tmp/missing")?.action?.kind == .webSearch, "direct path only when it exists")
                try expect(first("git")?.action?.id == "github", "name prefix keeps matches")
                guard case .results(let fallback) = router.route("zzqxv") else { throw TestFailure(description: "fallback route") }
                let fallbackActions = fallback.compactMap(\.action)
                try expect(fallbackActions.map(\.kind) == [.webSearch, .webSearch, .laptopSearch], "default searches")
                try expect(fallbackActions[0].target == "https://www.google.com/search?q=zzqxv", "default search uses the configured Google")
                try expect(router.configuredSearch(for: fallbackActions[0])?.id == "google", "search row finds its configured action")
                try expect(QueryRouter.wantsExtendedSearch("report", firstResult: nil), "file search for words")
                try expect(!QueryRouter.wantsExtendedSearch("re", firstResult: nil), "short queries skip file search")
                try expect(!QueryRouter.wantsExtendedSearch("g cats", firstResult: .action(google)), "alias search owns its words")
                try expect(!QueryRouter.wantsExtendedSearch("2+2", firstResult: first("2+2")), "answers skip file search")
            }),
            ("usage stats", {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "Australia/Sydney")!
                let now = ISO8601DateFormatter().date(from: "2026-10-04T06:00:00Z")!  // 16:00 in Sydney
                func ago(days: Int, _ hours: Int = 0) -> Date { now.addingTimeInterval(-Double(days * 86_400 + hours * 3_600)) }
                let youtube = LauncherAction(id: "yt", name: "YouTube", aliases: ["y"], kind: .url, target: "https://www.youtube.com/results?search_query={query}")
                let today = LauncherAction(id: "today", name: "Today", aliases: [";today"], kind: .snippet, target: "{date}")
                let file = LauncherAction(id: "runtime.file.abc", name: "secret.pdf", aliases: [], kind: .file, target: "/Volumes/Data/me/secret.pdf")
                let events: [UsageEvent] = [
                    .open(at: ago(days: 0)), .open(at: ago(days: 1)), .open(at: ago(days: 40)),
                    .action(youtube, at: ago(days: 0, 1), keys: 2, ms: 1_000, via: .alias),
                    .action(youtube, at: ago(days: 1), keys: 2, ms: 3_000, via: .alias),
                    .action(today, at: ago(days: 2), keys: 6, ms: 500, via: .alias),
                    .action(file, at: ago(days: 27), keys: 9, ms: 4_000, via: .name),
                    .action(youtube, at: ago(days: 40), keys: 2, ms: 1_000, via: .alias),
                ]
                try expect(events[6].id == "file", "files are logged by kind only")
                let stats = UsageStats.compute(events, now: now, calendar: calendar, snippetLengths: ["today": 26])
                try expect(stats.actions == 4 && stats.opens == 2, "28-day window")
                try expect(stats.daily.count == 28 && stats.daily[27] == 1 && stats.daily[26] == 1 && stats.daily[0] == 1, "daily buckets")
                try expect(stats.top.first == UsageStats.Entry(id: "yt", count: 2), "most used")
                try expect(stats.keysPerAction == 19.0 / 4 && stats.medianMs == 3_000, "keys and median")
                // url: (6 - 1) + (6 - 3); snippet: (26 - 6) / (200/60); file: 6 - 4.
                try expect(abs(stats.secondsSaved - (5 + 3 + 6 + 2)) < 0.001, "time saved estimate")
                try expect(UsageStats.duration(9_660) == "2h 41m" && UsageStats.duration(420) == "7m" && UsageStats.duration(40) == "40s", "durations")
                try expect(UsageEvent.route(typed: "y", action: youtube) == .alias, "alias route")
                try expect(UsageEvent.route(typed: "youtu", action: youtube) == .name, "name route")
                try expect(UsageEvent.route(typed: "", action: youtube) == .list, "list route")

                let directory = try temporaryDirectory().appendingPathComponent("usage")
                let log = UsageLog(directory: directory)
                for event in events { log.append(event) }
                let loaded = log.load(months: 3, now: now, calendar: calendar)
                try expect(loaded.count == events.count, "log round trip")
                let maxi = LauncherAction(id: "workspace.grid", name: "Grid", aliases: ["grid"], kind: .workspace, target: "hammerspoon://grid")
                let requested = UsageStats.compute([.action(maxi, at: now, keys: 4, ms: 500, via: .alias)], now: now, calendar: calendar)
                try expect(requested.actions == 1 && requested.secondsSaved == 0, "a requested workspace counts as use, not as time saved")
                let boundaryEvents = LockedValue<[UsageEvent]>()
                log.loadAsync(months: 3, now: now, calendar: calendar) { events in
                    boundaryEvents.set(events)
                }
                log.append(.open(at: now))
                let boundaryDeadline = Date().addingTimeInterval(2)
                while boundaryEvents.get() == nil && Date() < boundaryDeadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                }
                try expect(boundaryEvents.get()?.count == events.count, "async load excludes appends queued after its boundary")
                try expect(UsageStats.compute(loaded, now: now, calendar: calendar, snippetLengths: ["today": 26]) == stats, "stats from disk match")
                let text = try FileManager.default.contentsOfDirectory(atPath: directory.path).map {
                    try String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8)
                }.joined()
                try expect(!text.contains("secret") && !text.contains("/Volumes/"), "no names or paths in the log")
                // A locked parent folder makes the delete fail; reset must say so.
                let parent = directory.deletingLastPathComponent()
                try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
                let lockedReset = Result { try log.reset() }
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
                try expect((try? lockedReset.get()) == nil, "a failed delete is reported")
                try expect(FileManager.default.fileExists(atPath: directory.path), "the log survives a failed delete")
                try log.reset()
                try expect(!FileManager.default.fileExists(atPath: directory.path), "reset deletes the log")
                try log.reset()
            }),
            ("action kinds keep their JSON strings", {
                let action = LauncherAction(id: "w", name: "W", aliases: [], kind: .webSearch, target: "x")
                let json = String(decoding: try JSONEncoder().encode(action), as: UTF8.self)
                try expect(json.contains(#""kind":"web-search""#), "web-search raw value")
                let decoded = try JSONDecoder().decode(LauncherAction.self, from: Data(#"{"id":"a","name":"A","aliases":[],"kind":"laptop-search","target":""}"#.utf8))
                try expect(decoded.kind == .laptopSearch, "laptop-search decodes")
                try expectError(.unsupportedKind("teleport")) {
                    _ = try JSONDecoder().decode(LauncherAction.self, from: Data(#"{"id":"a","name":"A","aliases":[],"kind":"teleport","target":""}"#.utf8))
                }
                try expectError(.unsupportedKind("file")) {
                    _ = try LauncherConfig(version: 1, actions: [LauncherAction(id: "f", name: "F", aliases: ["f"], kind: .file, target: "/tmp")]).validated()
                }
                try expect(ActionKind.allCases.filter(\.isConfigurable) == [.url, .app, .terminal, .workspace, .snippet], "configurable kinds")
            }),
        ]
        for (name, test) in tests {
            do {
                try test()
                print("PASS \(name)")
            } catch {
                FileHandle.standardError.write(Data("FAIL \(name): \(error)\n".utf8))
                throw error
            }
        }
        print("PASS \(tests.count) LauncherCore tests")
    }

    private static func testLongestAlias() throws {
        let general = action("maps", "Maps", ["g"], "https://maps.google.com/?q={query}")
        let specific = action("drive", "Google Drive", ["g drive"], "https://drive.google.com/drive/u/0/my-drive?q={query}")
        let engine = ActionEngine(config: try LauncherConfig(version: 1, actions: [general, specific]).validated())
        let result = try engine.resolve("g drive quarterly plan")
        try expect(result.actionID == "drive", "wrong action")
        try expect(result.value.hasSuffix("q=quarterly%20plan"), "wrong query")
    }

    private static func testInlineAliasSearch() throws {
        let youtube = action("youtube", "YouTube", ["y"], "https://youtube.com/results?search_query={query}")
        let engine = ActionEngine(config: try LauncherConfig(version: 1, actions: [youtube]).validated())
        try expect(engine.search("y cats").first?.id == "youtube", "inline alias was not presented")
    }

    private static func testStableSearch() throws {
        let youtube = action("youtube", "Video Search", ["y"], "https://youtube.com/results?search_query={query}")
        let why = action("why", "Y Research", ["yr"], "https://example.com/?q={query}")
        let engine = ActionEngine(config: try LauncherConfig(version: 1, actions: [youtube, why]).validated())
        try expect(engine.search("y").map(\.id) == ["youtube", "why"], "unstable exact ranking")
    }

    private static func testMissingQuery() throws {
        let youtube = action("youtube", "YouTube", ["y"], "https://youtube.com/results?search_query={query}")
        let engine = ActionEngine(config: try LauncherConfig(version: 1, actions: [youtube]).validated())
        try expectError(.missingQuery("youtube")) { _ = try engine.resolve("y") }
    }

    private static func testURLInjection() throws {
        let google = action("google", "Google", ["g"], "https://google.com/search?q={query}")
        let engine = ActionEngine(config: try LauncherConfig(version: 1, actions: [google]).validated())
        let result = try engine.resolve("g cats&safe=off#owned / 🐈")
        try expect(result.value == "https://google.com/search?q=cats%26safe%3Doff%23owned%20%2F%20%F0%9F%90%88", "query injection was not encoded")
    }

    private static func testCanonicalAction() throws {
        let canonical = action("google", "Google", ["g"], "https://google.com/search?q={query}")
        let forged = action("google", "Forged", ["x"], "https://evil.example/?q={query}")
        let engine = ActionEngine(config: try LauncherConfig(version: 1, actions: [canonical]).validated())
        try expect(try engine.resolve(action: forged, query: "safe").value == "https://google.com/search?q=safe", "forged action escaped config")
    }

    private static func testSnippet() throws {
        let snippet = LauncherAction(id: "follow", name: "Follow", aliases: [";follow"], kind: .snippet, target: "Hello {date format=\"yyyy-MM-dd\"}\n{cursor}Cheers")
        let fixedDate = ISO8601DateFormatter().date(from: "2026-09-12T10:00:00Z")!
        let engine = ActionEngine(config: try LauncherConfig(version: 1, actions: [snippet]).validated(), now: { fixedDate }, timeZone: TimeZone(secondsFromGMT: 0)!)
        let result = try engine.resolve(";follow")
        try expect(result.value == "Hello 2026-09-12\nCheers", "date placeholder mismatch")
        try expect(result.cursorOffset == 17, "cursor offset mismatch")
    }

    private static func testUnsupportedSnippet() throws {
        let snippet = LauncherAction(id: "bad", name: "Bad", aliases: [";bad"], kind: .snippet, target: "Paste {clipboard}")
        try expectLauncherError { _ = try LauncherConfig(version: 1, actions: [snippet]).validated() }
    }

    private static func testUnknownInput() throws {
        let google = action("google", "Google", ["g"], "https://google.com")
        let engine = ActionEngine(config: try LauncherConfig(version: 1, actions: [google]).validated())
        try expectError(.noMatch("goggle")) { _ = try engine.resolve("goggle") }
    }

    private static func testBareDomain() throws {
        let engine = ActionEngine(config: try LauncherConfig(version: 1, actions: []).validated())
        let results = engine.search("x.com/path?q=hello")
        try expect(results.first?.id == "runtime.open-url", "domain result missing")
        let resolved = try engine.resolve("x.com/path?q=hello")
        try expect(resolved.value == "https://x.com/path?q=hello", "bare domain was not normalized to HTTPS")
        try expect(resolved.browser == nil, "direct URL uses the default browser")
        let google = LauncherAction(id: "google", name: "Google", aliases: ["g"], kind: .url, target: "https://www.google.com/search?q={query}", browser: "org.example.Browser")
        let withBrowser = ActionEngine(config: try LauncherConfig(version: 1, actions: [google]).validated())
        try expect(try withBrowser.resolve("x.com").browser == "org.example.Browser", "direct URL follows the g action's browser")
    }

    private static func testExplicitWebURL() throws {
        let engine = ActionEngine(config: try LauncherConfig(version: 1, actions: []).validated())
        let resolved = try engine.resolve("http://Example.com:8080/path?q=1")
        try expect(resolved.value == "http://example.com:8080/path?q=1", "explicit HTTP URL was not preserved safely")
        let fragment = try engine.resolve("https://example.com/@user#section")
        try expect(fragment.value == "https://example.com/@user#section", "safe path or fragment was rejected")
    }

    private static func testAliasBeatsDirectURL() throws {
        let configured = action("configured", "Configured destination", ["x.com"], "https://configured.example")
        let engine = ActionEngine(config: try LauncherConfig(version: 1, actions: [configured]).validated())
        try expect(engine.search("x.com").first?.id == "configured", "direct URL outranked exact alias")
        try expect(try engine.resolve("x.com").value == "https://configured.example", "resolve ignored exact alias")
    }

    private static func testUnsafeDirectURLs() throws {
        let engine = ActionEngine(config: try LauncherConfig(version: 1, actions: []).validated())
        let unsafe = [
            "person@example.com",
            "javascript://example.com/alert",
            "ftp://example.com/file",
            "https://user:password@example.com",
            "localhost/path",
            "example.com:8080/path",
            "https://exa mple.com",
        ]
        for input in unsafe {
            try expect(engine.search(input).isEmpty, "unsafe input appeared in search: \(input)")
            try expectError(.noMatch(input)) { _ = try engine.resolve(input) }
        }
    }

    private static func testForgedDirectURLAction() throws {
        let engine = ActionEngine(config: try LauncherConfig(version: 1, actions: []).validated())
        let forged = LauncherAction(id: "runtime.open-url", name: "Forged", aliases: ["x"], kind: .url, target: "javascript://example.com", browser: "com.apple.Safari")
        try expectError(.noMatch("runtime.open-url")) { _ = try engine.resolve(action: forged, query: "") }
    }

    private static func testWorkspaceAliasRouting() throws {
        let workspace = LauncherAction(id: "workspace.grid", name: "Four Terminals", aliases: ["grid"], kind: .workspace, target: "hammerspoon://grid")
        let board = LauncherAction(id: "workspace.board", name: "Board + Editor", aliases: ["board editor"], kind: .workspace, target: "hammerspoon://board-editor")
        let config = try LauncherConfig(version: 1, actions: [workspace, board]).validated()
        let engine = ActionEngine(config: config)
        try expect(engine.search("grid").first?.id == workspace.id, "workspace alias was not searchable")
        let resolved = try engine.resolve("grid")
        try expect(resolved.kind == .workspace && resolved.value == "hammerspoon://grid", "workspace resolution changed its target")
        let boardResolved = try engine.resolve("board editor")
        try expect(boardResolved.kind == .workspace && boardResolved.value == "hammerspoon://board-editor", "second workspace resolution changed its target")
        try expectError(.unexpectedQuery(workspace.id)) { _ = try engine.resolve("grid extra") }
    }

    private static func testWorkspaceTargetValidation() throws {
        let invalidTargets = ["grid", "https://example.com", "file:///tmp/x", "javascript://x", "hammerspoon://grid{query}",
                              " hammerspoon://grid ", "hammerspoon://", "hammerspoon:grid", "1bad://grid"]
        for (index, target) in invalidTargets.enumerated() {
            let action = LauncherAction(id: "workspace.\(index)", name: "Workspace", aliases: ["w\(index)"], kind: .workspace, target: target)
            try expectLauncherError { _ = try LauncherConfig(version: 1, actions: [action]).validated() }
        }
        for target in ["hammerspoon://grid", "myapp://layout/left?x=1"] {
            let action = LauncherAction(id: "workspace.ok", name: "Workspace", aliases: ["wok"], kind: .workspace, target: target)
            _ = try LauncherConfig(version: 1, actions: [action]).validated()
        }
        let browser = LauncherAction(id: "workspace.browser", name: "Workspace", aliases: ["wb"], kind: .workspace, target: "hammerspoon://grid", browser: "com.example.browser")
        try expectLauncherError { _ = try LauncherConfig(version: 1, actions: [browser]).validated() }
    }

    private static func testDuplicateID() throws {
        let config = LauncherConfig(version: 1, actions: [action("google", "Google", ["g"], "https://google.com"), action("GOOGLE", "Other", ["s"], "https://google.com")])
        try expectError(.duplicateID("GOOGLE")) { _ = try config.validated() }
    }

    private static func testDuplicateAlias() throws {
        let config = LauncherConfig(version: 1, actions: [action("one", "One", ["G  Drive"], "https://drive.google.com"), action("two", "Two", ["g drive"], "https://drive.google.com")])
        try expectError(.duplicateAlias("g drive")) { _ = try config.validated() }
    }

    private static func testInvalidURLs() throws {
        for (index, target) in ["javascript:alert(1)", "https://google.com/?q={query}&next={query}", "https://{query}.evil.example/path", "{query}://example.com/path"].enumerated() {
            try expectLauncherError { _ = try LauncherConfig(version: 1, actions: [action("bad\(index)", "Bad", ["b\(index)"], target)]).validated() }
        }
    }

    private static func testInvalidApply() throws {
        let directory = try temporaryDirectory()
        let live = directory.appendingPathComponent("config/actions.json")
        let valid = directory.appendingPathComponent("valid.json")
        let invalid = directory.appendingPathComponent("invalid.json")
        try write(config("g"), to: valid)
        try Data("{bad".utf8).write(to: invalid)
        let store = ConfigStore(url: live)
        let revision = try store.apply(from: valid)
        try expectLauncherError { _ = try store.apply(from: invalid) }
        try expect(try store.revision() == revision, "invalid apply replaced config")
    }

    private static func testRollback() throws {
        let directory = try temporaryDirectory()
        let live = directory.appendingPathComponent("config/actions.json")
        let first = directory.appendingPathComponent("first.json")
        let second = directory.appendingPathComponent("second.json")
        try write(config("g"), to: first)
        try write(config("search"), to: second)
        let store = ConfigStore(url: live)
        let firstRevision = try store.apply(from: first)
        let secondRevision = try store.apply(from: second)
        try expect(try store.rollback() == firstRevision, "rollback revision mismatch")
        try expect(try store.rollback() == secondRevision, "rollback swap mismatch")
        // A -> B -> B: the retry changes nothing and keeps A as the recovery point.
        try expect(try store.apply(from: second) == secondRevision, "identical apply revision")
        try expect(try store.rollback() == firstRevision, "identical apply erased the rollback")
    }

    private static func testSnapshot() throws {
        let directory = try temporaryDirectory()
        let live = directory.appendingPathComponent("config/actions.json")
        let source = directory.appendingPathComponent("source.json")
        try write(config("g"), to: source)
        let store = ConfigStore(url: live)
        _ = try store.apply(from: source)
        let snapshot = try store.snapshot()
        try expect(snapshot.revision == ConfigStore.revision(of: try Data(contentsOf: live)), "snapshot revision mismatch")
    }

    private static func testStatusPath() throws {
        let store = ConfigStore(url: URL(fileURLWithPath: "/tmp/example/config/actions.json"))
        try expect(store.statusURL.path == "/tmp/example/config/runtime/status.json", "wrong status path")
    }

    private static func testAliasSuggestions() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-04T06:00:00Z")!
        let slack = LauncherAction(id: "slack", name: "Slack", aliases: ["slack"], kind: .app, target: "com.tinyspeck.slackmacgap")
        let arc = LauncherAction(id: "runtime.app.arc", name: "Arc", aliases: ["arc"], kind: .application, target: "/Applications/Arc.app")
        let gmail = action("gm", "gm - Gmail", ["gm"], "https://mail.google.com")
        let youtube = action("yt", "YouTube Search", ["youtube"], "https://youtube.com/results?q={query}")
        let sleep = action("sleep", "Sleep Timer", ["sleep"], "https://example.com/sleep")
        let file = LauncherAction(id: "file", name: "file", aliases: [], kind: .file, target: "/tmp/x")
        let catalog = [slack, arc, gmail, youtube, sleep, file]
        func uses(_ target: LauncherAction, _ count: Int, keys: Int, daysAgo: Int = 1) -> [UsageEvent] {
            (0..<count).map { .action(target, at: now.addingTimeInterval(-Double(daysAgo * 86_400 + $0 * 60)), keys: keys, ms: 900, via: .name) }
        }
        let events = uses(slack, 60, keys: 5) + uses(arc, 4, keys: 3) + uses(gmail, 30, keys: 2)
            + uses(youtube, 10, keys: 8) + uses(sleep, 12, keys: 5) + uses(file, 40, keys: 9) + uses(slack, 50, keys: 5, daysAgo: 40)
        let list = AliasSuggester.suggest(events, catalog: catalog, now: now)
        try expect(list.map(\.action.id) == ["slack", "yt", "sleep"], "busiest typing first; got \(list.map(\.action.id))")
        try expect(list[0].alias == "sl" && list[0].uses == 60 && list[0].keysSaved == 180, "Slack: 60 uses in the window, 3 keys saved each")
        try expect(list[1].alias == "ys" && list[1].cost == 3, "a search alias still costs ⇥, and yo is a word")
        try expect(list[2].alias == "st", "Sleep Timer skips sl, which Slack took, and uses its initials")
        try expect(!list.contains { $0.action.id == "gm" }, "an action with a short alias is skipped")
        try expect(!list.contains { $0.action.id == "file" }, "file keys are content, not habit")
        try expect(!list.contains { $0.action.id == "runtime.app.arc" }, "fewer than five uses is not a habit")
        let crowded = catalog + [action("taken", "Taken", ["sl", "sa"], "https://example.com")]
        try expect(AliasSuggester.suggest(events, catalog: crowded, now: now).first?.alias == "sc", "a taken alias moves to the next choice")
        let stats = action("st", "Stats Board", ["stats board"], "https://example.com/stats")
        try expect(AliasSuggester.candidates(for: stats).first == "st", "candidates start with the name")
        let today = LauncherAction(id: "today", name: "Today's Date", aliases: [";today"], kind: .snippet, target: "{cursor}")
        try expect(AliasSuggester.candidates(for: today).first == "td", "a common word such as to is never an alias")
        try expect(AliasSuggester.suggest(uses(slack, 30, keys: 2), catalog: [slack], now: now).isEmpty, "an alias that saves nothing is not suggested")
    }

    private static func testEmoji() throws {
        let all = EmojiCatalog.all
        try expect(all.count == 1914 && Set(all.map(\.symbol)).count == 1914, "every emoji parses once")
        try expect(Set(all.map(\.group)) == Set(EmojiCatalog.groups), "every group is used")
        func first(_ query: String, _ count: Int = 1) -> [String] { Array(EmojiCatalog.search(query).prefix(count).map(\.symbol)) }
        try expect(first("fire") == ["🔥"], "an exact name comes first")
        try expect(first("thumbs") == ["👍"], "a name prefix keeps Unicode order")
        try expect(first("lol", 3).contains("😂"), "keywords find emoji: lol")
        try expect(first("heart eyes", 3).contains("😍"), "every word must match")
        try expect(first(" FIRE ") == ["🔥"], "case and spaces do not matter")
        try expect(EmojiCatalog.search("zzqxv").isEmpty, "nonsense finds nothing")
        try expect(EmojiCatalog.search("").count == 1914, "an empty query lists everything")
        // Use reorders matches of the same strength, never across strengths.
        try expect(EmojiCatalog.search("joy", usage: ["😹": 3]).first?.symbol == "😹", "use breaks ties")
        try expect(EmojiCatalog.search("fire", usage: ["🧯": 9]).first?.symbol == "🔥", "use never beats an exact name")
        let seed = ["🦾", "🤖", "👀"]
        try expect(EmojiCatalog.frequent(usage: [:], seed: seed).map(\.symbol) == seed, "the imported order is kept")
        try expect(EmojiCatalog.frequent(usage: ["🔥": 1], seed: seed).first?.symbol == "🔥", "one real use today beats the imported top")
        try expect(EmojiCatalog.usage(from: ["emoji.🔥": 2, "app-slack": 5]) == ["🔥": 2], "only emoji picks count")
        try expect(EmojiCatalog.usageID("🔥") == "emoji.🔥", "usage ID")
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("emoji-seed.json")
        try expect(EmojiCatalog.loadSeed(from: url).isEmpty, "a missing seed gives none")
        try Data(#"{"source":"Raycast","symbols":["🦾","🤖"]}"#.utf8).write(to: url)
        try expect(EmojiCatalog.loadSeed(from: url) == ["🦾", "🤖"], "seed round trip")
    }

    private static func testCanonicalUpdate() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("actions.json")
        let messy = #"{"actions":[{"target":"https://github.com","kind":"url","aliases":["github"],"name":"GitHub","id":"gh","browser":"com.example.browser"},{"id":"note","name":"Note","aliases":[";n"],"kind":"snippet","target":"line one\nline \"two\" / {cursor}"}],"version":1}"#
        try Data(messy.utf8).write(to: url)
        let store = ConfigStore(url: url)
        let before = try store.load()
        let saved = try store.update { try $0.addingAlias("gi", to: "gh") }
        let written = try store.load()
        try expect(written == saved.config && written.actions[0].aliases == ["github", "gi"], "the alias is written")
        try expect(written.actions[1] == before.actions[1], "other actions keep every value, escapes included")
        let text = try String(contentsOf: url, encoding: .utf8)
        try expect(text.contains(#""aliases": ["github", "gi"],"#) && text.hasPrefix("{\n  \"version\": 1,\n  \"actions\": [\n    {\n      \"id\": \"gh\","), "canonical layout")
        try expect(written.canonicalJSON() == Data(text.utf8), "the same config gives the same bytes")
        _ = try store.rollback()
        try expect(try store.load() == before, "the file before the update is the rollback point")
        let revision = try store.revision()
        _ = try store.update { $0 }
        try expect(try store.revision() == revision, "a change that alters nothing writes nothing")
        try expectError(.duplicateAlias("github")) { _ = try store.update { try $0.addingAlias("github", to: "note") } }
        try expect(try store.revision() == revision, "an invalid change leaves the file alone")
        try expectLauncherError { _ = try store.update { try $0.addingAlias("zz", to: "missing") } }
        let app = LauncherAction(id: "runtime.app.arc", name: "Arc", aliases: ["ar"], kind: .app, target: "company.thebrowser.Browser")
        let appended = try store.update { try $0.addingAlias("ar", to: app.id, orAppending: app) }
        try expect(appended.config.actions.last == app, "a discovered app joins the config under its own ID")
    }

    private static func testAppearanceSettings() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("config/settings.json")
        try expect(AppearanceSettings.load(from: url) == .standard, "missing file must give Signal + volt")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ broken".utf8).write(to: url)
        try expect(AppearanceSettings.load(from: url) == .standard, "invalid file must give the default")
        try Data(#"{"theme":"neon","accent":"cyan"}"#.utf8).write(to: url)
        try expect(AppearanceSettings.load(from: url) == AppearanceSettings(theme: "signal", accent: "cyan"), "unknown theme falls back alone")
        let glass = AppearanceSettings(theme: "glass", accent: "violet")
        try glass.save(to: url)
        try expect(AppearanceSettings.load(from: url) == glass, "settings round trip")
        let raycast = AppearanceSettings(theme: "raycast", accent: "volt")
        try raycast.save(to: url)
        try expect(AppearanceSettings.load(from: url) == raycast, "raycast theme round trip")
    }

    private static func testDisplayFormat() throws {
        try expect(DisplayFormat.rounded("6.21371192237 mi") == "6.21 mi", "unit rounding")
        try expect(DisplayFormat.rounded("14") == "14", "integers unchanged")
        try expect(DisplayFormat.rounded("144.05 AUD") == "144.05 AUD", "currency unchanged")
        try expect(DisplayFormat.rounded("0.000123456 km") == "0.0001235 km", "small values keep 4 significant digits")
        try expect(DisplayFormat.rounded("10 km → 6.21371192237 mi", fractionDigits: 4) == "10 km → 6.21371192237 mi", "only the first number changes")
        try expect(DisplayFormat.rounded("6.21371192237 mi", fractionDigits: 4) == "6.2137 mi", "detail precision")
        try expect(DisplayFormat.rounded("1e+21") == "1e+21", "scientific notation unchanged")
        try expect(DisplayFormat.rounded("Error") == "Error", "text unchanged")
        try expect(DisplayFormat.roundedAll("10 km → 6.21371192237 mi") == "10 km → 6.2137 mi", "detail rounding")
        try expect(DisplayFormat.roundedAll("100 USD → 144.07 AUD · Frankfurter reference 2026-10-04") == "100 USD → 144.07 AUD · Frankfurter reference 2026-10-04", "dates untouched")
        try expect(DisplayFormat.valueAndUnit("6.21 mi") == ("6.21", "mi"), "value and unit")
        try expect(DisplayFormat.valueAndUnit("14") == ("14", ""), "value without unit")
        try expect(DisplayFormat.valueAndUnit("Error") == ("Error", ""), "text value")
        try expect(DisplayFormat.cleanName("gh - GitHub", aliases: ["gh"]) == "GitHub", "alias prefix removed")
        try expect(DisplayFormat.cleanName("GitHub", aliases: ["gh"]) == "GitHub", "plain name unchanged")
        try expect(DisplayFormat.cleanName("gh - ", aliases: ["gh"]) == "gh - ", "never empties a name")
        try expect(DisplayFormat.modeName("YouTube Search", aliases: ["y"]) == "YouTube", "mode chip drops Search")
        try expect(DisplayFormat.modeName("gdrive - Google Drive Search", aliases: ["gdrive"]) == "Google Drive", "mode chip cleans both ends")
    }

    private static func testDictationRouting() throws {
        let router = QueryRouter(configured: [action("google", "Google Search", ["g"], "https://www.google.com/search?q={query}")])
        try expect(router.route("lx") == .dictations(term: ""), "lx lists recent dictations")
        try expect(router.route("larynx") == .larynx && router.route("  Larynx ") == .larynx, "larynx opens the dashboard")
        try expect(router.route("lx ") == .dictations(term: ""), "lx with a trailing space still lists")
        try expect(router.route("lx launch demo") == .dictations(term: "launch demo"), "lx keeps the filter words")
        try expect(router.route("  LX  Launch ") == .dictations(term: "Launch"), "case and spaces")
        try expect(router.route("Larynx notes") == .dictations(term: "notes"), "larynx with words")
        if case .dictations = router.route("lxa") { throw TestFailure(description: "lxa is not a dictation query") }
        try expect(!QueryRouter.wantsExtendedSearch("lx launch", firstResult: nil), "lx skips file search")
        try expect({ if case .results = router.route("lx launch demo", dictations: false) { return true }; return false }(), "without Larynx, lx is an ordinary search")
        try expect({ if case .results = router.route("larynx", dictations: false) { return true }; return false }(), "without Larynx, larynx is an ordinary search")
        try expect(!QueryRouter.wantsExtendedSearch("larynx", firstResult: nil), "the dashboard skips file search")
        try expect(QueryRouter.commandWords.isSuperset(of: ["lx", "larynx"]), "lx is never suggested as an alias")
        let copy = UsageEvent.transient(kind: .dictation, at: Date(), keys: 9, ms: 10, via: .name)
        try expect(copy.id == "dictation" && copy.kind == .dictation, "usage logs the kind only")
    }

    /// Writes a fixture with Larynx's schema (History.swift) in WAL mode.
    private static func dictationFixture(_ url: URL, rows: [(String, Double, String, String)]) throws -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else { throw TestFailure(description: "fixture open") }
        let schema = """
            PRAGMA journal_mode=WAL;
            CREATE TABLE dictations(id TEXT PRIMARY KEY, created_at REAL NOT NULL, text_raw TEXT NOT NULL, text_final TEXT NOT NULL,
              style TEXT NOT NULL, model TEXT NOT NULL, cleanup TEXT NOT NULL, duration_s REAL NOT NULL, landed TEXT NOT NULL,
              transcribe_ms REAL, clean_ms REAL);
            CREATE INDEX dictations_created ON dictations(created_at);
            """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { throw TestFailure(description: "fixture schema") }
        for row in rows { try insertDictation(db, row) }
        return db
    }

    private static func insertDictation(_ db: OpaquePointer?, _ row: (String, Double, String, String)) throws {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO dictations VALUES(?, ?, ?, ?, 'plain', 'm', 'none', 1.5, 'clipboard', NULL, NULL)", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, row.0, -1, transient)
        sqlite3_bind_double(stmt, 2, row.1)
        sqlite3_bind_text(stmt, 3, row.3, -1, transient)
        sqlite3_bind_text(stmt, 4, row.2, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw TestFailure(description: "fixture insert") }
    }

    private static func testDictationReader() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Missing file: a clear failure, and the reader does not create it.
        let missing = directory.appendingPathComponent("absent/history.db")
        do { _ = try DictationHistory(path: missing).recent(); throw TestFailure(description: "missing file must fail") }
        catch let failure as DictationHistory.Failure { try expect(failure == .missing, "missing failure") }
        try expect(!FileManager.default.fileExists(atPath: missing.path), "missing file is not created")
        try expect(!FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path), "missing folder is not created")

        let url = directory.appendingPathComponent("history.db")
        let writer = try dictationFixture(url, rows: [
            ("a", 1_000, "Launch demo on Friday", "launch demo on friday um"),
            ("b", 3_000, "Buy milk", "buy milk"),
            ("c", 2_000, "The LAUNCH board DEMO notes", "the launch board demo notes"),
            ("d", 4_000, "", "silence"),
            ("e", 5_000, "Grew 100% and a_b", "grew 100 percent"),
        ])
        let reader = DictationHistory(path: url)
        try expect(try reader.recent().map(\.id) == ["e", "b", "c", "a"], "newest first, empty text skipped")
        try expect(try reader.recent(limit: 2).map(\.id) == ["e", "b"], "limit")
        try expect(try reader.recent(matching: "launch demo").map(\.id) == ["c", "a"], "all words, any case")
        try expect(try reader.recent(matching: "demo board").map(\.id) == ["c"], "word order does not matter")
        try expect(try reader.recent(matching: "100%").map(\.id) == ["e"] && (try reader.recent(matching: "1%0")).isEmpty, "% is literal")
        try expect(try reader.recent(matching: "a_b").map(\.id) == ["e"] && (try reader.recent(matching: "a_c")).isEmpty, "_ is literal")
        try expect(try reader.recent(matching: "x' OR 1=1 --").isEmpty, "words are bound, not SQL")
        let first = try reader.recent(matching: "milk")[0]
        try expect(first.textFinal == "Buy milk" && first.textRaw == "buy milk" && first.createdAt == Date(timeIntervalSince1970: 3_000), "row fields")

        // The cached handle sees a row Larynx commits later.
        try insertDictation(writer, ("f", 6_000, "Fresh line", "fresh line"))
        try expect(try reader.recent(limit: 1).map(\.id) == ["f"], "cached handle sees new rows")
        sqlite3_close(writer)

        // Read-only: the reader works on a file it cannot write, and the file is unchanged.
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        let before = try Data(contentsOf: url)
        let fresh = DictationHistory(path: url)
        try expect(try fresh.recent().count == 5, "reads a read-only file")
        try expect(try Data(contentsOf: url) == before, "database bytes unchanged")

        // A file that is not SQLite gives a failure, not a crash.
        let junk = directory.appendingPathComponent("junk.db")
        try Data("not a database".utf8).write(to: junk)
        do { _ = try DictationHistory(path: junk).recent(); throw TestFailure(description: "junk file must fail") }
        catch let failure as DictationHistory.Failure {
            guard case .unreadable = failure else { throw TestFailure(description: "junk failure kind") }
        }

        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 15, minute: 0))!
        func ago(_ seconds: Double) -> String { DictationHistory.relativeTime(now.addingTimeInterval(-seconds), now: now, calendar: calendar) }
        try expect(ago(20) == "just now" && ago(120) == "2 min ago", "minutes")
        try expect(ago(3 * 3600 + 300) == "11:55", "earlier today")
        try expect(ago(86_400 + 3300) == "yesterday 14:05", "yesterday")
        try expect(ago(3 * 86_400) == "Thu 15:00", "this week")
        try expect(ago(20 * 86_400) == "21 Sep", "older")
    }

    private static func testLarynxAggregates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Sydney")!
        let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 15))!
        func streaks(_ days: [String]) -> (Int, Int) {
            let value = LarynxStats.streaks(days, today: today, calendar: calendar)
            return (value.current, value.longest)
        }
        try expect(streaks([]) == (0, 0), "no days")
        try expect(streaks(["2026-10-11"]) == (1, 1), "today only")
        try expect(streaks(["2026-10-09", "2026-10-10"]) == (2, 2), "today missing: the streak ends yesterday")
        try expect(streaks(["2026-10-08", "2026-10-09"]) == (0, 2), "a gap before yesterday breaks the streak")
        try expect(streaks(["2026-10-11", "2026-10-10", "2026-10-08", "2026-10-07", "2026-10-06"]) == (2, 3), "a gap: current 2, longest 3")
        try expect(streaks(["2026-09-30", "2026-10-01", "2026-10-02"]) == (0, 3), "runs cross a month")
        // Across the October daylight-saving change in Sydney (4 Oct 2026).
        try expect(streaks(["2026-10-03", "2026-10-04", "2026-10-05"]) == (0, 3), "runs cross a clock change")
        try expect(streaks(["2026-10-11", "2026-10-11", "bad"]) == (1, 1), "duplicates and junk ignored")

        func stats(words: Int, talk: Double) -> LarynxStats {
            LarynxStats(daily: [], dictations: 1, words: words, talkSeconds: talk, fixes: 0, keptSafe: 0,
                        currentStreak: 0, longestStreak: 0, medianTranscribeMs: nil, apps: [], start: today)
        }
        try expect(stats(words: 2_681, talk: 904).secondsSaved == 2_681.0 / 40 * 60 - 904, "time saved")
        try expect(stats(words: 10, talk: 600).secondsSaved == 0, "time saved floors at zero")
        try expect(stats(words: 2_681, talk: 904).wordsPerMinute == 178 && stats(words: 2_681, talk: 904).timesTyping == "4.4", "speed")
        try expect(stats(words: 50, talk: 0).wordsPerMinute == nil && stats(words: 50, talk: 0).timesTyping == nil, "zero talk time has no speed")
        try expect(UsageStats.duration(stats(words: 1_000_000, talk: 0).secondsSaved) == "416h 40m", "huge totals")

        typealias Share = LarynxStats.AppShare
        let named = [(app: "com.anthropic.claude", words: 60), (app: "com.tinyspeck.slackmacgap", words: 20), (app: "dev.zed.Zed", words: 9),
                     (app: "a", words: 3), (app: "b", words: 1)]
        try expect(LarynxStats.shares(named.prefix(4).map { $0 }, unknown: 7, total: 100) == [
            Share(name: .app("com.anthropic.claude"), words: 60), Share(name: .app("com.tinyspeck.slackmacgap"), words: 20),
            Share(name: .app("dev.zed.Zed"), words: 9), Share(name: .app("a"), words: 3), Share(name: .other, words: 8),
        ], "top four, unknown folded into Other")
        try expect(LarynxStats.shares([(app: "x", words: 10)], unknown: 90, total: 100) == [
            Share(name: .unrecorded, words: 90), Share(name: .app("x"), words: 10),
        ], "unknown majority gets its own row")
        try expect(LarynxStats.shares([], unknown: 40, total: 40) == [Share(name: .unrecorded, words: 40)], "only unknown")
        try expect(LarynxStats.shares([], unknown: 0, total: 0).isEmpty, "no words, no rows")
    }

    /// Writes a fixture with Larynx's current schema (History.swift at f128f45).
    private static func larynxFixture(_ url: URL, sql: String, withTotals: Bool = true) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else { throw TestFailure(description: "fixture open") }
        defer { sqlite3_close(db) }
        var schema = """
            PRAGMA journal_mode=WAL;
            CREATE TABLE dictations(id TEXT PRIMARY KEY, created_at REAL NOT NULL, text_raw TEXT NOT NULL, text_final TEXT NOT NULL,
              style TEXT NOT NULL, model TEXT NOT NULL, cleanup TEXT NOT NULL, duration_s REAL NOT NULL, landed TEXT NOT NULL,
              transcribe_ms REAL, clean_ms REAL, app TEXT, words INTEGER, fixes INTEGER);
            CREATE INDEX dictations_created ON dictations(created_at);
            """
        if withTotals {
            schema += """
                CREATE TABLE daily(day TEXT PRIMARY KEY, dictations INTEGER NOT NULL, words INTEGER NOT NULL, talk_s REAL NOT NULL,
                  fixes INTEGER NOT NULL, kept_safe INTEGER NOT NULL);
                CREATE TABLE daily_apps(day TEXT NOT NULL, app TEXT NOT NULL, dictations INTEGER NOT NULL, words INTEGER NOT NULL, PRIMARY KEY(day, app));
                """
        }
        guard sqlite3_exec(db, schema + sql, nil, nil, nil) == SQLITE_OK else {
            throw TestFailure(description: "fixture: " + String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
    }

    private static func testLarynxDashboard() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Sydney")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 15))!

        // Missing file: the failure the view turns into "No Larynx stats yet". Nothing is created.
        let missing = directory.appendingPathComponent("absent/history.db")
        do { _ = try DictationHistory(path: missing).dashboard(now: now, calendar: calendar); throw TestFailure(description: "missing must fail") }
        catch let failure as DictationHistory.Failure { try expect(failure == .missing, "missing dashboard") }
        try expect(!FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path), "missing folder not created")

        // An older file without the daily tables.
        let old = directory.appendingPathComponent("old.db")
        try larynxFixture(old, sql: "", withTotals: false)
        do { _ = try DictationHistory(path: old).dashboard(now: now, calendar: calendar); throw TestFailure(description: "old file must fail") }
        catch let failure as DictationHistory.Failure { try expect(failure == .noStats && failure.description == "No Larynx stats yet", "old file") }

        // Empty tables: zeros, not a failure.
        let empty = directory.appendingPathComponent("empty.db")
        try larynxFixture(empty, sql: "")
        let zero = try DictationHistory(path: empty).dashboard(now: now, calendar: calendar)
        try expect(zero.words == 0 && zero.dictations == 0 && zero.daily == Array(repeating: 0, count: 28) && zero.apps.isEmpty
                   && zero.currentStreak == 0 && zero.medianTranscribeMs == nil && zero.wordsPerMinute == nil, "empty tables")

        // Days: today, yesterday, a gap, then three days; one row outside the window; one in the future.
        let today = now.timeIntervalSince1970
        var sql = """
            INSERT INTO daily VALUES('2026-10-11', 10, 400, 120, 5, 1);
            INSERT INTO daily VALUES('2026-10-10', 5, 100, 60, 2, 0);
            INSERT INTO daily VALUES('2026-10-06', 1, 10, 6, 0, 0);
            INSERT INTO daily VALUES('2026-10-05', 1, 10, 6, 0, 0);
            INSERT INTO daily VALUES('2026-10-04', 1, 10, 6, 0, 0);
            INSERT INTO daily VALUES('2026-09-14', 2, 30, 9, 1, 1);
            INSERT INTO daily VALUES('2026-09-13', 99, 9999, 999, 99, 99);
            INSERT INTO daily VALUES('2026-10-12', 99, 9999, 999, 99, 99);
            INSERT INTO daily_apps VALUES('2026-10-11', 'com.anthropic.claude', 6, 300);
            INSERT INTO daily_apps VALUES('2026-10-11', 'unknown', 2, 40);
            INSERT INTO daily_apps VALUES('2026-10-10', 'com.tinyspeck.slackmacgap', 5, 100);
            INSERT INTO daily_apps VALUES('2026-10-06', 'dev.zed.Zed', 1, 10);
            INSERT INTO daily_apps VALUES('2026-10-05', 'com.apple.Notes', 1, 10);
            INSERT INTO daily_apps VALUES('2026-10-04', 'org.mozilla.firefox', 1, 10);
            INSERT INTO daily_apps VALUES('2026-09-13', 'com.old.app', 99, 9999);
            """
        // transcribe_ms 100..109 inside the window (median 104.5), one huge value outside it.
        for index in 0..<10 { sql += "INSERT INTO dictations VALUES('d\(index)', \(today - Double(index) * 3600), 'secret raw', 'secret text', 'p', 'm', 'c', 1, 'l', \(100 + index), 1, 'x', 2, 0);" }
        sql += "INSERT INTO dictations VALUES('old', \(today - 40 * 86_400), 'r', 't', 'p', 'm', 'c', 1, 'l', 99999, 1, 'x', 2, 0);"
        sql += "INSERT INTO dictations VALUES('untimed', \(today - 60), 'r', 't', 'p', 'm', 'c', 1, 'l', NULL, 1, 'x', 2, 0);"
        let url = directory.appendingPathComponent("history.db")
        try larynxFixture(url, sql: sql)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        let before = try Data(contentsOf: url)
        let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        let reader = DictationHistory(path: url)
        let stats = try reader.dashboard(now: now, calendar: calendar)
        try expect(stats.words == 560 && stats.dictations == 20 && stats.fixes == 8 && stats.keptSafe == 2, "28-day sums, window edges")
        try expect(abs(stats.talkSeconds - 207) < 0.001, "talk time")
        try expect(stats.daily.count == 28 && stats.daily.last == 400 && stats.daily[26] == 100 && stats.daily[0] == 30, "one bar per day, today last")
        try expect(stats.currentStreak == 2 && stats.longestStreak == 3, "streaks from the daily table")
        try expect(stats.medianTranscribeMs == 104.5, "median transcribe time in the window")
        try expect(stats.apps.map(\.name) == [.app("com.anthropic.claude"), .app("com.tinyspeck.slackmacgap"), .app("com.apple.Notes"), .app("dev.zed.Zed"), .other],
                   "top four by words, ties by id")
        try expect(stats.apps.last?.words == 50 && stats.appWords == 470, "Other holds the rest and unknown")
        try expect(calendar.isDate(stats.start, inSameDayAs: calendar.date(from: DateComponents(year: 2026, month: 9, day: 14))!), "window starts 27 days back")

        // Today has no rows yet: the streak still counts through yesterday.
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        let next = try reader.dashboard(now: tomorrow, calendar: calendar)
        try expect(next.daily.last == 9999 && next.currentStreak == 3, "the future row becomes today")

        try expect(try Data(contentsOf: url) == before, "database bytes unchanged")
        try expect((try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) == modified, "mtime unchanged")
        try expect(!FileManager.default.fileExists(atPath: url.path + "-journal"), "no journal created")

        // Speed: the dashboard reads aggregates only. A 3,000-row history stays well under a millisecond budget.
        var bulk = ""
        for day in 0..<3_660 {
            let date = calendar.date(byAdding: .day, value: -day, to: now)!
            let name = LarynxStats.dayString(date, calendar: calendar)
            bulk += "INSERT INTO daily VALUES('\(name)', 30, 900, 300, 9, 1);"
            for app in 0..<6 { bulk += "INSERT INTO daily_apps VALUES('\(name)', 'app.\(app)', 5, 150);" }
        }
        for index in 0..<3_000 { bulk += "INSERT INTO dictations VALUES('b\(index)', \(today - Double(index) * 800), '\(String(repeating: "raw ", count: 50))', '\(String(repeating: "final ", count: 50))', 'p', 'm', 'c', 1, 'l', \(150 + index % 90), 1, 'app.1', 9, 0);" }
        let big = directory.appendingPathComponent("big.db")
        try larynxFixture(big, sql: bulk)
        let bigReader = DictationHistory(path: big)
        let full = try bigReader.dashboard(now: now, calendar: calendar)
        try expect(full.daily.allSatisfy { $0 == 900 } && full.longestStreak == 3_660 && full.currentStreak == 3_660, "28 full days, ten years of streak")
        var times: [Double] = []
        for _ in 0..<30 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try bigReader.dashboard(now: now, calendar: calendar)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        times.sort()
        print(String(format: "  larynx dashboard on 3,660 days + 3,000 rows: median %.2f ms, p95 %.2f ms", times[15], times[28]))
        try expect(times[28] < 25, "dashboard query stays well under the result budget")
    }

    private static func config(_ alias: String) -> LauncherConfig {
        LauncherConfig(version: 1, actions: [action("google", "Google", [alias], "https://google.com/search?q={query}")])
    }
}

