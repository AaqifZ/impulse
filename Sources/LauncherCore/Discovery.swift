import CryptoKit
import Foundation

/// A bounded result from a local command used by a discovery provider.
///
/// The result is public so the command runner can be replaced by a deterministic
/// test double without invoking Spotlight or Shortcuts.
public struct DiscoveryCommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
    public let timedOut: Bool

    public init(
        exitCode: Int32,
        standardOutput: String = "",
        standardError: String = "",
        timedOut: Bool = false
    ) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
    }
}

public enum DiscoveryError: Error, Equatable, LocalizedError, Sendable {
    case commandUnavailable(String)
    case commandFailed(String, Int32, String)
    case commandTimedOut(String)

    public var errorDescription: String? {
        switch self {
        case .commandUnavailable(let executable):
            return "Discovery command unavailable: \(executable)"
        case .commandFailed(let executable, let exitCode, let detail):
            if detail.isEmpty {
                return "Discovery command failed: \(executable) (exit \(exitCode))"
            }
            return "Discovery command failed: \(executable) (exit \(exitCode)): \(detail)"
        case .commandTimedOut(let executable):
            return "Discovery command timed out: \(executable)"
        }
    }
}

/// Local discovery providers for installed apps, Spotlight files, Shortcuts,
/// and a small allow-list of safe system destinations.
///
/// Discovery is deliberately separate from configured actions. It returns the
/// same value type, but callers must still choose the adapter appropriate to
/// each runtime kind before opening or executing anything.
public struct Discovery: Sendable {
    public typealias CommandRunner = @Sendable (
        _ executable: String,
        _ arguments: [String],
        _ timeout: TimeInterval,
        _ maxOutputBytes: Int
    ) throws -> DiscoveryCommandResult

    public static let standardAppRoots: [URL] = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true),
    ]

    private static let commandOutputLimit = 512 * 1024
    private static let fileSearchTimeout: TimeInterval = 1.5
    private static let shortcutSearchTimeout: TimeInterval = 2.0
    private static let maximumFileResults = 100
    private static let maximumFileSearchTerms = 8
    private static let maximumSpotlightCandidates = 2_000
    private static let fileSearchFillerWords: Set<String> = [
        "a", "about", "an", "and", "anything", "document", "documents", "file", "files",
        "find", "folder", "folders", "for", "from", "in", "it", "look", "looking", "me",
        "my", "of", "on", "open", "related", "relating", "search", "show", "something",
        "stuff", "that", "the", "thing", "this", "to", "with",
    ]

    private let appRoots: [URL]
    private let homeDirectory: URL
    private let commandRunner: CommandRunner

    /// Pass app roots and a home directory in tests to avoid touching the
    /// user's real Applications or home folders. The command runner is also
    /// injectable so file/shortcut parsing can be tested without subprocesses.
    public init(
        appRoots: [URL]? = nil,
        homeDirectory: URL? = nil,
        commandRunner: CommandRunner? = nil
    ) {
        let resolvedHome = (homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser)
            .standardizedFileURL
        self.homeDirectory = resolvedHome
        self.appRoots = (appRoots ?? Self.standardAppRoots + [
            resolvedHome.appendingPathComponent("Applications", isDirectory: true),
        ]).map(\.standardizedFileURL)
        self.commandRunner = commandRunner ?? { executable, arguments, timeout, maxOutputBytes in
            try Self.runCommand(
                executable: executable,
                arguments: arguments,
                timeout: timeout,
                maxOutputBytes: maxOutputBytes
            )
        }
    }

    /// Discover installed `.app` bundles in the standard user/system roots.
    public static func apps() -> [LauncherAction] {
        Discovery().apps()
    }

    /// Discover Spotlight-indexed files and folders in the current user's home.
    public static func files(matching: String, limit: Int = 20) -> [LauncherAction] {
        Discovery().files(matching: matching, limit: limit)
    }

    /// Discover names from the user's Shortcuts library without executing them.
    public static func shortcuts() throws -> [LauncherAction] {
        try Discovery().shortcuts()
    }

    /// Return a small, explicit set of safe destinations.
    public static func systemActions() -> [LauncherAction] {
        Discovery().systemActions()
    }

    /// Discover installed applications. Roots are enumerated in the supplied
    /// order; this makes `/Applications` win over later system roots when the
    /// same bundle identifier appears more than once.
    public func apps() -> [LauncherAction] {
        let fileManager = FileManager.default
        var candidates: [AppCandidate] = []
        var visitedRoots = Set<String>()

        for (rootPriority, root) in appRoots.enumerated() {
            let standardizedRoot = root.standardizedFileURL
            guard visitedRoots.insert(standardizedRoot.path).inserted,
                  fileManager.fileExists(atPath: standardizedRoot.path) else { continue }

            guard let enumerator = fileManager.enumerator(
                at: standardizedRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                let standardizedURL = url.standardizedFileURL

                // A hidden directory can still appear when a caller supplies a
                // custom enumerator/root, so guard it explicitly as well.
                if standardizedURL.lastPathComponent.hasPrefix(".") {
                    enumerator.skipDescendants()
                    continue
                }

                guard standardizedURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
                    continue
                }

                // Do not descend into a package. Even a malformed `.app` is a
                // package boundary and must not produce its internal files.
                enumerator.skipDescendants()
                // Safari and other installed apps can be links to system volumes.
                let resolvedURL = standardizedURL.resolvingSymlinksInPath()
                let resolvedValues = try? resolvedURL.resourceValues(forKeys: [.isDirectoryKey])
                guard resolvedValues?.isDirectory == true,
                      let metadata = Self.appMetadata(at: resolvedURL) else { continue }

                candidates.append(
                    AppCandidate(
                        path: standardizedURL.path,
                        displayName: metadata.displayName,
                        bundleIdentifier: metadata.bundleIdentifier,
                        rootPriority: rootPriority
                    )
                )
            }
        }

        // FileManager enumeration order is not a public contract. Sorting by
        // root priority and path makes selection and results repeatable.
        candidates.sort {
            if $0.rootPriority != $1.rootPriority {
                return $0.rootPriority < $1.rootPriority
            }
            return $0.path < $1.path
        }

        var seenBundleIDs = Set<String>()
        var seenPaths = Set<String>()
        var actions: [LauncherAction] = []
        for candidate in candidates {
            guard seenPaths.insert(candidate.path).inserted else { continue }
            if let bundleIdentifier = candidate.bundleIdentifier {
                let key = bundleIdentifier.casefolded
                guard seenBundleIDs.insert(key).inserted else { continue }
            }

            let alias = Self.normalizedName(candidate.displayName)
            guard !alias.isEmpty else { continue }
            actions.append(
                LauncherAction(
                    id: Self.runtimeID(prefix: "app", identity: candidate.path),
                    name: LauncherText.visible(candidate.displayName),
                    aliases: [alias],
                    kind: .application,
                    target: candidate.path
                )
            )
        }
        return actions
    }

    /// Query Spotlight by both filename and indexed text content. The query is
    /// passed as one Process argument and never interpreted by a shell.
    public func files(matching: String, limit: Int = 20) -> [LauncherAction] {
        let trimmed = matching.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3, limit > 0 else { return [] }

        let boundedLimit = min(limit, Self.maximumFileResults)
        let concepts = Self.fileSearchConcepts(for: trimmed)
        guard !concepts.isEmpty else { return [] }

        let fullQuery = Self.spotlightQuery(for: concepts, requireAll: true)
        guard let fullResult = Self.successfulSpotlightResult(
            try? commandRunner(
                "/usr/bin/mdfind",
                ["-onlyin", homeDirectory.path, fullQuery],
                Self.fileSearchTimeout,
                Self.commandOutputLimit
            )
        ) else { return [] }

        // A second OR query adds useful partial matches such as "robotics"
        // files for "robotics party". A failed broad pass must not discard the
        // stronger results already returned by the all-terms query.
        let partialResult: DiscoveryCommandResult?
        if concepts.count > 1 {
            let partialQuery = Self.spotlightQuery(for: concepts, requireAll: false)
            partialResult = Self.successfulSpotlightResult(
                try? commandRunner(
                    "/usr/bin/mdfind",
                    ["-onlyin", homeDirectory.path, partialQuery],
                    Self.fileSearchTimeout,
                    Self.commandOutputLimit
                )
            )
        } else {
            partialResult = nil
        }

        let homePath = homeDirectory.path == "/"
            ? "/"
            : homeDirectory.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var coverageByPath: [String: FileSearchCoverage] = [:]
        Self.collectSpotlightPaths(
            from: fullResult.standardOutput,
            coverage: .full,
            homePath: homePath,
            into: &coverageByPath
        )
        if let partialResult {
            Self.collectSpotlightPaths(
                from: partialResult.standardOutput,
                coverage: .partial,
                homePath: homePath,
                into: &coverageByPath
            )
        }

        let candidates = coverageByPath.map { path, coverage in
                (
                    path: path,
                    rank: Self.fileSearchRank(
                        path: path,
                        matching: trimmed,
                        concepts: concepts,
                        coverage: coverage
                    )
                )
            }
            .sorted {
                if $0.rank != $1.rank {
                    return $0.rank < $1.rank
                }
                return $0.path < $1.path
            }

        return candidates.prefix(boundedLimit).compactMap { candidate in
            let path = candidate.path
            let name = URL(fileURLWithPath: path).lastPathComponent
            let alias = Self.normalizedName(name)
            guard !name.isEmpty, !alias.isEmpty else { return nil }
            return LauncherAction(
                id: Self.runtimeID(prefix: "file", identity: path),
                name: name,
                aliases: [alias],
                kind: .file,
                target: path
            )
        }
    }

    /// List the user's shortcuts. A non-zero exit is surfaced with the exact
    /// stderr text so permission/availability problems are diagnosable without
    /// exposing any shortcut body (shortcuts list returns names only).
    public func shortcuts() throws -> [LauncherAction] {
        let result = try commandRunner(
            "/usr/bin/shortcuts",
            ["list"],
            Self.shortcutSearchTimeout,
            Self.commandOutputLimit
        )
        if result.timedOut {
            throw DiscoveryError.commandTimedOut("/usr/bin/shortcuts")
        }
        guard result.exitCode == 0 else {
            throw DiscoveryError.commandFailed(
                "/usr/bin/shortcuts",
                result.exitCode,
                result.standardError
            )
        }

        var seenNames = Set<String>()
        return result.standardOutput
            .components(separatedBy: "\n")
            .map { line in
                line.hasSuffix("\r") ? String(line.dropLast()) : line
            }
            .filter { !$0.isEmpty && seenNames.insert($0).inserted }
            .compactMap { name in
                let alias = Self.normalizedName(name)
                guard !alias.isEmpty else { return nil }
                return LauncherAction(
                    id: Self.runtimeID(prefix: "shortcut", identity: name),
                    name: name,
                    aliases: [alias],
                    kind: .shortcut,
                    target: name
                )
            }
    }

    /// Safe paths and one explicit system action. The system action uses a
    /// fixed identifier so adapters cannot turn arbitrary user input into a
    /// system command.
    public func systemActions() -> [LauncherAction] {
        let home = homeDirectory.path
        let folders: [(id: String, name: String, path: String)] = [
            ("runtime.system.home", "Home", home),
            ("runtime.system.downloads", "Downloads", homeDirectory.appendingPathComponent("Downloads").path),
            ("runtime.system.desktop", "Desktop", homeDirectory.appendingPathComponent("Desktop").path),
            ("runtime.system.applications", "Applications", "/Applications"),
        ]
        let folderActions = folders.map { folder in
            LauncherAction(
                id: folder.id,
                name: folder.name,
                aliases: [Self.normalizedName(folder.name)],
                kind: .file,
                target: URL(fileURLWithPath: folder.path).standardizedFileURL.path
            )
        }

        let settings = LauncherAction(
            id: "runtime.system.settings",
            name: "System Settings",
            aliases: [Self.normalizedName("System Settings")],
            kind: .system,
            target: "system-settings"
        )
        return folderActions + [settings]
    }

    // MARK: - App metadata and IDs

    private struct AppCandidate: Sendable {
        let path: String
        let displayName: String
        let bundleIdentifier: String?
        let rootPriority: Int
    }

    private struct AppMetadata {
        let displayName: String
        let bundleIdentifier: String?
    }

    private static func appMetadata(at url: URL) -> AppMetadata? {
        let fallbackName = url.deletingPathExtension().lastPathComponent
        var info: [String: Any] = [:]
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        if let data = try? Data(contentsOf: infoURL),
           let object = try? PropertyListSerialization.propertyList(
               from: data,
               options: [],
               format: nil
           ),
           let dictionary = object as? [String: Any] {
            info = dictionary
        } else if let bundle = Bundle(url: url), let dictionary = bundle.infoDictionary {
            info = dictionary
        }

        let displayNameCandidates: [String?] = [
            info["CFBundleDisplayName"] as? String,
            info["CFBundleName"] as? String,
            fallbackName,
        ]
        let displayName = displayNameCandidates.compactMap { (value: String?) -> String? in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return value
        }.first
        guard let displayName else { return nil }

        let bundleIdentifier = (info["CFBundleIdentifier"] as? String)?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return AppMetadata(
            displayName: displayName,
            bundleIdentifier: bundleIdentifier?.isEmpty == false ? bundleIdentifier : nil
        )
    }

    private static func runtimeID(prefix: String, identity: String) -> String {
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "runtime.\(prefix).\(String(digest.prefix(16)))"
    }

    private static func normalizedName(_ name: String) -> String {
        LauncherText.normalizeWords(name)
    }

    // MARK: - Spotlight

    private enum FileSearchCoverage: Int, Comparable {
        case full = 0
        case partial = 1

        static func < (lhs: FileSearchCoverage, rhs: FileSearchCoverage) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    private struct FileSearchRank: Comparable {
        let coverage: FileSearchCoverage
        let pathEvidence: Int
        let phraseEvidence: Int

        static func < (lhs: FileSearchRank, rhs: FileSearchRank) -> Bool {
            if lhs.coverage != rhs.coverage { return lhs.coverage < rhs.coverage }
            if lhs.pathEvidence != rhs.pathEvidence { return lhs.pathEvidence < rhs.pathEvidence }
            return lhs.phraseEvidence < rhs.phraseEvidence
        }
    }

    private static func fileSearchConcepts(for value: String) -> [[String]] {
        var seen = Set<String>()
        return searchTokens(in: value)
            .filter { $0.count >= 2 && !fileSearchFillerWords.contains($0) }
            .map(canonicalSearchToken)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(maximumFileSearchTerms)
            .map(searchVariants)
    }

    private static func searchTokens(in value: String) -> [String] {
        let normalized = normalizedName(value)
        return normalized.unicodeScalars
            .split { !CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
    }

    private static func canonicalSearchToken(_ token: String) -> String {
        if token.hasSuffix("ies"), token.count > 4 {
            return String(token.dropLast(3)) + "y"
        }
        if token.hasSuffix("ics"), token.count > 5 {
            return String(token.dropLast(3))
        }
        if token.hasSuffix("ic"), token.count > 4 {
            return String(token.dropLast(2))
        }
        if token.hasSuffix("s"), token.count > 3,
           !token.hasSuffix("ss"), !token.hasSuffix("us") {
            return String(token.dropLast())
        }
        return token
    }

    private static func searchVariants(for canonical: String) -> [String] {
        var variants = [canonical]
        if canonical.hasSuffix("y"), canonical.count > 2 {
            let beforeY = canonical[canonical.index(canonical.endIndex, offsetBy: -2)]
            if !"aeiou".contains(beforeY) {
                variants.append(String(canonical.dropLast()) + "ies")
            }
        } else if canonical.hasSuffix("s") || canonical.hasSuffix("x") ||
                    canonical.hasSuffix("z") || canonical.hasSuffix("ch") ||
                    canonical.hasSuffix("sh") {
            variants.append(canonical + "es")
        } else {
            variants.append(canonical + "s")
        }
        return variants
    }

    private static func spotlightQuery(for concepts: [[String]], requireAll: Bool) -> String {
        let conceptQueries = concepts.map { variants in
            let variantQueries = variants.flatMap { variant -> [String] in
                let escaped = escapeSpotlightLiteral(variant)
                return [
                    "kMDItemFSName == \"*\(escaped)*\"cd",
                    // A leading wildcard forces Spotlight into a slow content
                    // scan. Prefix matching uses the text index and stays
                    // inside the launcher's command timeout.
                    "kMDItemTextContent == \"\(escaped)*\"cd",
                ]
            }
            return "(" + variantQueries.joined(separator: " || ") + ")"
        }
        return "(" + conceptQueries.joined(separator: requireAll ? " && " : " || ") + ")"
    }

    private static func escapeSpotlightLiteral(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0...31, 127:
                // Keep the query one line and prevent control characters from
                // changing the mdfind expression.
                escaped.append(" ")
            case 34: // double quote
                escaped.append("\\\"")
            case 42: // wildcard
                escaped.append("\\*")
            case 63: // single-character wildcard
                escaped.append("\\?")
            case 92: // backslash
                escaped.append("\\\\")
            default:
                escaped.append(String(scalar))
            }
        }
        return escaped
    }

    private static func isWithinHome(_ path: String, homePath: String) -> Bool {
        if homePath == "/" { return path.hasPrefix("/") }
        return path == "/\(homePath)" || path.hasPrefix("/\(homePath)/")
    }

    private static func isInsideAppBundle(_ path: String) -> Bool {
        path.split(separator: "/").contains { component in
            component.lowercased().hasSuffix(".app")
        }
    }

    private static func isRegularFileOrDirectory(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isRegularFileKey]
        ) else { return false }
        return values.isDirectory == true || values.isRegularFile == true
    }

    private static func successfulSpotlightResult(
        _ result: DiscoveryCommandResult?
    ) -> DiscoveryCommandResult? {
        guard let result, !result.timedOut, result.exitCode == 0 else { return nil }
        return result
    }

    private static func collectSpotlightPaths(
        from output: String,
        coverage: FileSearchCoverage,
        homePath: String,
        into paths: inout [String: FileSearchCoverage]
    ) {
        for line in output.split(whereSeparator: { $0.isNewline }).prefix(maximumSpotlightCandidates) {
            let path = String(line)
            guard !path.isEmpty else { continue }
            let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            guard isWithinHome(standardizedPath, homePath: homePath),
                  !isInsideAppBundle(standardizedPath),
                  isRegularFileOrDirectory(standardizedPath) else { continue }
            if let existing = paths[standardizedPath], existing <= coverage { continue }
            paths[standardizedPath] = coverage
        }
    }

    private static func fileSearchRank(
        path: String,
        matching: String,
        concepts: [[String]],
        coverage: FileSearchCoverage
    ) -> FileSearchRank {
        let url = URL(fileURLWithPath: path)
        let query = normalizedName(matching)
        let basename = normalizedName(url.lastPathComponent)
        let stem = normalizedName(url.deletingPathExtension().lastPathComponent)
        let normalizedPath = normalizedName(path)
        let basenameCoverage = concepts.filter { variants in
            variants.contains { basename.contains($0) || stem.contains($0) }
        }.count
        let pathCoverage = concepts.filter { variants in
            variants.contains { normalizedPath.contains($0) }
        }.count

        let pathEvidence: Int
        if basenameCoverage == concepts.count {
            pathEvidence = 0
        } else if pathCoverage == concepts.count {
            pathEvidence = 1
        } else if basenameCoverage > 0 {
            pathEvidence = 2
        } else if pathCoverage > 0 {
            pathEvidence = 3
        } else {
            // Spotlight does not report which metadata field matched. A row
            // without path evidence is therefore treated as content-only.
            pathEvidence = 4
        }

        // A query without an extension should still treat README.md as an
        // exact basename match. This keeps the common launcher query concise.
        let phraseEvidence: Int
        if basename == query || (!query.contains(".") && stem == query) {
            phraseEvidence = 0
        } else if basename.hasPrefix(query) || basename.contains(query) ||
                    stem.hasPrefix(query) || stem.contains(query) {
            phraseEvidence = 1
        } else {
            phraseEvidence = 2
        }
        return FileSearchRank(
            coverage: coverage,
            pathEvidence: pathEvidence,
            phraseEvidence: phraseEvidence
        )
    }

    // MARK: - Bounded subprocesses

    private static func runCommand(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        maxOutputBytes: Int
    ) throws -> DiscoveryCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            throw DiscoveryError.commandUnavailable(executable)
        }

        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        let outputGroup = DispatchGroup()
        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutBox.data = Self.readBounded(
                from: standardOutput.fileHandleForReading,
                maxBytes: maxOutputBytes
            )
            outputGroup.leave()
        }
        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrBox.data = Self.readBounded(
                from: standardError.fileHandleForReading,
                maxBytes: maxOutputBytes
            )
            outputGroup.leave()
        }

        let processGroup = DispatchGroup()
        processGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            processGroup.leave()
        }

        var timedOut = processGroup.wait(timeout: .now() + timeout) == .timedOut
        if timedOut, process.isRunning {
            process.terminate()
            if processGroup.wait(timeout: .now() + 0.25) == .timedOut,
               process.isRunning {
                #if canImport(Darwin)
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                #endif
            }
        }

        // Never wait indefinitely after a timeout. A process that ignores
        // terminate (or whose status update is delayed) gets one final bounded
        // SIGKILL attempt, and is reported with an explicit nonzero sentinel.
        if process.isRunning {
            timedOut = true
            #if canImport(Darwin)
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            #endif
        }

        // The readers drain/discard beyond the cap so a noisy child cannot fill
        // a pipe and stall the bounded command runner.
        _ = processGroup.wait(timeout: .now() + 0.5)
        _ = outputGroup.wait(timeout: .now() + 0.5)

        // Process.terminationStatus is only valid after the process has
        // stopped. If it is still running, return a deliberate nonzero value
        // rather than consulting an indeterminate status or waiting forever.
        let processStopped = !process.isRunning
        let exitCode: Int32
        if processStopped {
            exitCode = process.terminationStatus
        } else {
            exitCode = -1
        }
        return DiscoveryCommandResult(
            exitCode: exitCode,
            standardOutput: String(decoding: stdoutBox.data, as: UTF8.self),
            standardError: String(decoding: stderrBox.data, as: UTF8.self),
            timedOut: timedOut
        )
    }

    private static func readBounded(from handle: FileHandle, maxBytes: Int) -> Data {
        var data = Data()
        let chunkSize = 64 * 1024
        while true {
            let chunk: Data
            do {
                guard let next = try handle.read(upToCount: chunkSize), !next.isEmpty else { break }
                chunk = next
            } catch {
                break
            }
            if data.count < maxBytes {
                data.append(chunk.prefix(maxBytes - data.count))
            }
        }
        return data
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

private extension String {
    var casefolded: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
