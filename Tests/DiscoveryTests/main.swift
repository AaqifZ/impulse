import Foundation
import LauncherCore

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw TestFailure(description: message) }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    guard actual == expected else {
        throw TestFailure(description: "\(message): expected \(expected), got \(actual)")
    }
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("impulse-discovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func writeInfo(
    at appURL: URL,
    displayName: String,
    bundleIdentifier: String?
) throws {
    let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    var info: [String: String] = [
        "CFBundleDisplayName": displayName,
        "CFBundleName": displayName,
    ]
    if let bundleIdentifier {
        info["CFBundleIdentifier"] = bundleIdentifier
    }
    let data = try PropertyListSerialization.data(
        fromPropertyList: info,
        format: .xml,
        options: 0
    )
    try data.write(to: contents.appendingPathComponent("Info.plist"))
}

private func makeApp(
    under root: URL,
    folderName: String,
    displayName: String,
    bundleIdentifier: String?
) throws -> URL {
    let appURL = root.appendingPathComponent(folderName, isDirectory: true)
    try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
    try writeInfo(at: appURL, displayName: displayName, bundleIdentifier: bundleIdentifier)
    return appURL
}

private final class CommandRecorder: @unchecked Sendable {
    var executable = ""
    var arguments: [String] = []
    var timeout: TimeInterval = 0
    var maxOutputBytes = 0
    var invocations: [[String]] = []
}

@main
struct DiscoveryTestRunner {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("app discovery and bundle dedupe", testApps),
            ("linked system apps", {
                let directory = try temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: directory) }
                let root = directory.appendingPathComponent("Applications")
                let system = directory.appendingPathComponent("Cryptex")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let safari = try makeApp(under: system, folderName: "Safari.app", displayName: "Safari", bundleIdentifier: "com.example.safari")
                let link = root.appendingPathComponent("Safari.app")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: safari)
                try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Broken.app"), withDestinationURL: directory.appendingPathComponent("missing"))
                let apps = Discovery(appRoots: [root], homeDirectory: directory).apps()
                try expectEqual(apps.count, 1, "linked app missing or broken link included")
                try expect(apps.first?.target == link.path, "original launch path preserved")
                let engine = ActionEngine(config: LauncherConfig(version: 1, actions: apps))
                try expect(engine.search("saf").first?.name == "Safari", "linked Safari searchable by prefix")
            }),
            ("Spotlight file query and filtering", testFiles),
            ("Spotlight word relevance and ranking", testFileWordRelevance),
            ("shortcuts parsing and command errors", testShortcuts),
            ("safe system actions", testSystemActions),
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
        print("PASS \(tests.count) Discovery tests")
    }

    private static func testApps() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let userRoot = directory.appendingPathComponent("Applications", isDirectory: true)
        let systemRoot = directory.appendingPathComponent("SystemApplications", isDirectory: true)
        try FileManager.default.createDirectory(at: userRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: systemRoot, withIntermediateDirectories: true)

        let userCapCut = try makeApp(
            under: userRoot,
            folderName: "CapCut.app",
            displayName: "CapCut",
            bundleIdentifier: "com.example.capcut"
        )
        _ = try makeApp(
            under: systemRoot,
            folderName: "CapCut.app",
            displayName: "CapCut",
            bundleIdentifier: "com.example.capcut"
        )
        let unique = try makeApp(
            under: systemRoot,
            folderName: "A Unique.app",
            displayName: "A Unique",
            bundleIdentifier: "com.example.unique"
        )
        let hiddenRoot = systemRoot.appendingPathComponent(".hidden", isDirectory: true)
        try FileManager.default.createDirectory(at: hiddenRoot, withIntermediateDirectories: true)
        _ = try makeApp(
            under: hiddenRoot,
            folderName: "Hidden.app",
            displayName: "Hidden",
            bundleIdentifier: "com.example.hidden"
        )
        let outer = try makeApp(
            under: systemRoot,
            folderName: "Outer.app",
            displayName: "Outer",
            bundleIdentifier: "com.example.outer"
        )
        _ = try makeApp(
            under: outer,
            folderName: "Nested.app",
            displayName: "Nested",
            bundleIdentifier: "com.example.nested"
        )

        let discovery = Discovery(appRoots: [userRoot, systemRoot], homeDirectory: directory)
        let actions = discovery.apps()
        try expectEqual(actions.count, 3, "unexpected app count")
        try expect(actions.allSatisfy { $0.kind == .application }, "wrong app action kind")
        try expect(actions.allSatisfy { $0.target.hasPrefix("/") }, "app target is not absolute")
        try expect(actions.allSatisfy { $0.id.hasPrefix("runtime.app.") }, "app ID is not path based")
        try expect(actions.contains { $0.name == "A Unique" && $0.target == unique.path }, "unique app missing")
        try expect(
            actions.contains { $0.name == "CapCut" && $0.target == userCapCut.path },
            "user CapCut did not win bundle-ID dedupe"
        )
        try expect(!actions.contains { $0.name == "Hidden" }, "hidden app was discovered")
        try expect(!actions.contains { $0.name == "Nested" }, "app bundle descendants were discovered")
        try expect(
            actions.first(where: { $0.name == "CapCut" })?.aliases == ["capcut"],
            "app alias was not normalized"
        )
        try expectEqual(actions.map(\.id), discovery.apps().map(\.id), "app IDs are not stable")

        // A newly installed app must appear on the next refresh without any
        // manually configured alias. Its searchable alias is derived from the
        // app's display name by discovery itself.
        let refreshedApp = try makeApp(
            under: userRoot,
            folderName: "Refresh Tool.app",
            displayName: "Refresh Tool",
            bundleIdentifier: "com.example.refresh"
        )
        let refreshed = discovery.apps()
        try expectEqual(refreshed.count, 4, "new app was not picked up on refresh")
        try expect(
            refreshed.contains {
                $0.name == "Refresh Tool" &&
                $0.target == refreshedApp.path &&
                $0.aliases == ["refresh tool"]
            },
            "new app was not discovered without a manual alias"
        )
    }

    private static func testFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let notes = directory.appendingPathComponent("notes.txt")
        let folder = directory.appendingPathComponent("Project Folder", isDirectory: true)
        let readme = directory.appendingPathComponent("README.md")
        let readmeNotes = directory.appendingPathComponent("README-notes.md")
        let agents = directory.appendingPathComponent("AGENTS.md")
        let appInternal = directory
            .appendingPathComponent("Example.app/Contents/Resources/info.txt")
        try Data("notes".utf8).write(to: notes)
        try Data("readme".utf8).write(to: readme)
        try Data("readme notes".utf8).write(to: readmeNotes)
        try Data("readme content".utf8).write(to: agents)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: appInternal.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("internal".utf8).write(to: appInternal)

        let recorder = CommandRecorder()
        let runner: Discovery.CommandRunner = { executable, arguments, timeout, maxOutputBytes in
            recorder.executable = executable
            recorder.arguments = arguments
            recorder.timeout = timeout
            recorder.maxOutputBytes = maxOutputBytes
            recorder.invocations.append(arguments)
            if arguments.last?.contains("readme") == true {
                return DiscoveryCommandResult(
                    exitCode: 0,
                    standardOutput: "\(agents.path)\n\(readmeNotes.path)\n\(readme.path)\n"
                )
            }
            return DiscoveryCommandResult(
                exitCode: 0,
                standardOutput: "\(notes.path)\n\(appInternal.path)\n\(folder.path)\n\(notes.path)\n\(directory.path)/outside.txt\n"
            )
        }
        let discovery = Discovery(
            appRoots: [],
            homeDirectory: directory,
            commandRunner: runner
        )

        try expect(discovery.files(matching: "ab").isEmpty, "short file query should be ignored")
        try expectEqual(recorder.executable, "", "short query launched mdfind")

        let actions = discovery.files(matching: "abc\"*)", limit: 20)
        try expectEqual(actions.map(\.target), [folder.path, notes.path].sorted(), "file results were not filtered")
        try expect(actions.allSatisfy { $0.kind == .file }, "wrong file action kind")
        try expect(actions.allSatisfy { $0.name == URL(fileURLWithPath: $0.target).lastPathComponent }, "wrong file name")
        try expect(actions.allSatisfy { $0.id.hasPrefix("runtime.file.") }, "file ID is not path based")
        try expectEqual(recorder.executable, "/usr/bin/mdfind", "wrong Spotlight executable")
        try expectEqual(Array(recorder.arguments.prefix(2)), ["-onlyin", directory.path], "wrong Spotlight scope")
        let spotlightQuery = recorder.arguments.last ?? ""
        try expect(spotlightQuery.contains("kMDItemFSName"), "filename search missing")
        try expect(spotlightQuery.contains("kMDItemTextContent"), "content search missing")
        try expect(
            spotlightQuery.contains("kMDItemFSName == \"*abc*\"cd"),
            "filename search lost substring matching"
        )
        try expect(
            spotlightQuery.contains("kMDItemTextContent == \"abc*\"cd"),
            "content search is not using the indexed prefix form"
        )
        try expect(
            !spotlightQuery.contains("kMDItemTextContent == \"*abc*\"cd"),
            "content search regressed to a slow leading wildcard"
        )
        try expect(!spotlightQuery.contains("abc\"*)"), "unsafe Spotlight syntax reached the query")
        try expect(spotlightQuery.contains("*abc*"), "safe query token was removed")
        try expect(recorder.timeout > 0 && recorder.timeout <= 2, "file search is not bounded")
        try expect(recorder.maxOutputBytes > 0, "file output is not bounded")

        let ranked = discovery.files(matching: "README", limit: 2)
        try expectEqual(
            ranked.map(\.target),
            [readme.path, readmeNotes.path],
            "filename ranking was not applied before limit"
        )
        try expect(ranked.allSatisfy { $0.name != "AGENTS.md" }, "content-only result outranked filename result")
        let rankedSpotlightQuery = recorder.arguments.last ?? ""

        try expect(discovery.files(matching: "abc", limit: 0).isEmpty, "zero limit should be ignored")
        try expectEqual(recorder.arguments.last ?? "", rankedSpotlightQuery, "zero limit launched another query")
    }

    private static func testFileWordRelevance() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let exactName = directory.appendingPathComponent("Robotics Party Plan.md")
        let relatedFolder = directory.appendingPathComponent("Robots/Parties", isDirectory: true)
        let relatedPath = relatedFolder.appendingPathComponent("agenda.txt")
        let fullContent = directory.appendingPathComponent("meeting-notes.txt")
        let partialName = directory.appendingPathComponent("Robotics Budget.md")
        let partialContent = directory.appendingPathComponent("misc.txt")
        try FileManager.default.createDirectory(at: relatedFolder, withIntermediateDirectories: true)
        for file in [exactName, relatedPath, fullContent, partialName, partialContent] {
            try Data("fixture".utf8).write(to: file)
        }

        let recorder = CommandRecorder()
        let runner: Discovery.CommandRunner = { executable, arguments, timeout, maxOutputBytes in
            recorder.executable = executable
            recorder.arguments = arguments
            recorder.timeout = timeout
            recorder.maxOutputBytes = maxOutputBytes
            recorder.invocations.append(arguments)
            let query = arguments.last ?? ""
            if query.contains(" && ") {
                return DiscoveryCommandResult(
                    exitCode: 0,
                    standardOutput: "\(fullContent.path)\n\(relatedPath.path)\n\(exactName.path)\n"
                )
            }
            return DiscoveryCommandResult(
                exitCode: 0,
                standardOutput: "\(partialContent.path)\n\(partialName.path)\n\(fullContent.path)\n"
            )
        }
        let discovery = Discovery(appRoots: [], homeDirectory: directory, commandRunner: runner)
        let actions = discovery.files(matching: "robotics party", limit: 20)

        try expectEqual(recorder.invocations.count, 2, "multi-word search did not use strict and broad queries")
        let strictQuery = recorder.invocations[0].last ?? ""
        let broadQuery = recorder.invocations[1].last ?? ""
        try expect(strictQuery.contains("*robot*"), "robotics was not reduced to a useful robot variant")
        try expect(strictQuery.contains("*party*"), "party singular variant missing")
        try expect(strictQuery.contains("*parties*"), "party plural variant missing")
        try expect(strictQuery.contains(" && "), "strict query did not require full term coverage")
        try expect(!broadQuery.contains(" && ") && broadQuery.contains(" || "), "broad query did not allow partial matches")
        try expectEqual(
            actions.map(\.target),
            [exactName.path, relatedPath.path, fullContent.path, partialName.path, partialContent.path],
            "word relevance did not rank full coverage and path evidence"
        )
        try expect(actions.allSatisfy { $0.kind == .file }, "word relevance changed the files API kind")

        recorder.invocations.removeAll()
        _ = discovery.files(matching: "the thing about robots", limit: 20)
        try expectEqual(recorder.invocations.count, 1, "single meaningful word launched a redundant broad query")
        let fillerQuery = recorder.invocations[0].last ?? ""
        try expect(fillerQuery.contains("*robot*"), "meaningful word was removed")
        try expect(!fillerQuery.contains("thing") && !fillerQuery.contains("about"), "filler words reached Spotlight")
    }

    private static func testShortcuts() throws {
        let recorder = CommandRecorder()
        let runner: Discovery.CommandRunner = { executable, arguments, timeout, maxOutputBytes in
            recorder.executable = executable
            recorder.arguments = arguments
            recorder.timeout = timeout
            recorder.maxOutputBytes = maxOutputBytes
            return DiscoveryCommandResult(
                exitCode: 0,
                standardOutput: "Morning Routine\nWorkspace - Open\nMorning Routine\n"
            )
        }
        let discovery = Discovery(commandRunner: runner)
        let actions = try discovery.shortcuts()
        try expectEqual(actions.map(\.name), ["Morning Routine", "Workspace - Open"], "shortcut names changed")
        try expect(actions.allSatisfy { $0.kind == .shortcut }, "wrong shortcut action kind")
        try expect(actions.allSatisfy { $0.target == $0.name }, "shortcut target was not exact name")
        try expectEqual(recorder.executable, "/usr/bin/shortcuts", "wrong shortcuts executable")
        try expectEqual(recorder.arguments, ["list"], "shortcuts command executed an action")
        try expect(recorder.timeout > 0 && recorder.timeout <= 2.5, "shortcut search is not bounded")

        let failure = Discovery(commandRunner: { _, _, _, _ in
            DiscoveryCommandResult(exitCode: 64, standardError: "not authorized")
        })
        do {
            _ = try failure.shortcuts()
            throw TestFailure(description: "shortcut failure was swallowed")
        } catch let error as DiscoveryError {
            try expectEqual(error, .commandFailed("/usr/bin/shortcuts", 64, "not authorized"), "wrong shortcut error")
        }

        let timeout = Discovery(commandRunner: { _, _, _, _ in
            DiscoveryCommandResult(exitCode: 15, timedOut: true)
        })
        do {
            _ = try timeout.shortcuts()
            throw TestFailure(description: "shortcut timeout was swallowed")
        } catch let error as DiscoveryError {
            try expectEqual(error, .commandTimedOut("/usr/bin/shortcuts"), "wrong shortcut timeout")
        }
    }

    private static func testSystemActions() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let actions = Discovery(homeDirectory: directory).systemActions()
        try expectEqual(
            actions.map(\.name),
            ["Home", "Downloads", "Desktop", "Applications", "System Settings"],
            "system action names changed"
        )
        try expectEqual(actions[0].target, directory.path, "home target changed")
        try expectEqual(actions[1].target, directory.appendingPathComponent("Downloads").path, "Downloads target changed")
        try expectEqual(actions[2].target, directory.appendingPathComponent("Desktop").path, "Desktop target changed")
        try expectEqual(actions[3].target, "/Applications", "Applications target changed")
        try expectEqual(actions[4].kind, .system, "System Settings is not an explicit system action")
        try expectEqual(actions[4].target, "system-settings", "System Settings ID changed")
        try expect(actions.allSatisfy { !$0.aliases.isEmpty }, "system action missing alias")
    }
}
