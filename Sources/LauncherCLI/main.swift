import Foundation
import LauncherCore
#if canImport(Darwin)
import Darwin
#endif

@main
struct LauncherCLI {
    static func main() {
        do {
            try run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func run(_ arguments: [String]) throws {
        var arguments = arguments
        var configURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("config/actions.json")
        if arguments.first == "--config" {
            guard arguments.count >= 3 else { throw CLIError.usage }
            configURL = URL(fileURLWithPath: arguments[1], relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
            arguments.removeFirst(2)
        }
        guard let command = arguments.first else { throw CLIError.usage }
        let operands = Array(arguments.dropFirst())
        let store = ConfigStore(url: configURL)

        switch command {
        case "validate":
            guard operands.count == 1 else { throw CLIError.usage }
            let source = fileURL(operands[0])
            _ = try ConfigStore.validate(url: source)
            let data = try Data(contentsOf: source)
            print(ConfigStore.revision(of: data))
        case "apply":
            guard operands.count == 1 else { throw CLIError.usage }
            print(try store.apply(from: fileURL(operands[0])))
        case "rollback":
            guard operands.isEmpty else { throw CLIError.usage }
            print(try store.rollback())
        case "list":
            guard operands.isEmpty else { throw CLIError.usage }
            try printJSON(store.load().actions)
        case "resolve":
            guard !operands.isEmpty else { throw CLIError.usage }
            let config = try store.load()
            var engine = ActionEngine(config: LauncherConfig(version: config.version, actions: config.catalog(adding: Discovery.apps() + Discovery.systemActions())))
            try printJSON(engine.resolve(operands.joined(separator: " ")))
        case "apps":
            try printJSON(Discovery.apps())
        case "files":
            guard !operands.isEmpty else { throw CLIError.usage }
            try printJSON(Discovery.files(matching: operands.joined(separator: " "), limit: 20))
        case "shortcuts":
            try printJSON(Discovery.shortcuts())
        case "calculate":
            guard !operands.isEmpty else { throw CLIError.usage }
            let input = operands.joined(separator: " ")
            let result = Calculator.evaluate(input) ?? CurrencyConverter.convert(input, cacheURL: configURL.deletingLastPathComponent().appendingPathComponent("runtime/exchange-rates.json"))
            guard let result else { throw LauncherError.noMatch(input) }
            try printJSON(result)
        case "search":
            guard !operands.isEmpty else { throw CLIError.usage }
            let input = operands.joined(separator: " ")
            let config = try store.load()
            var engine = ActionEngine(config: LauncherConfig(version: config.version, actions: config.catalog(adding: Discovery.apps() + Discovery.systemActions())))
            engine.usage = UsageRanking.weights(UsageLog(directory: configURL.deletingLastPathComponent().appendingPathComponent("runtime/usage", isDirectory: true)).load())
            var results = engine.search(input)
            if input.count >= 3 && results.first?.target.contains("{query}") != true && results.first?.id != "runtime.open-url" { results += Discovery.files(matching: input, limit: 20) }
            try printJSON(results)
        case "alias":
            // Adds an alias to a configured action, or gives a discovered app a config entry.
            guard operands.count == 2 else { throw CLIError.usage }
            let configured = try store.load().actions.contains { $0.id == operands[0] }
            let discovered = configured ? nil : Discovery.apps().first { $0.id == operands[0] }
            print(try store.update { try $0.addingAlias(operands[1], to: operands[0], orAppending: discovered?.configuredApp(alias: operands[1])) }.revision)
        case "suggest":
            guard operands.isEmpty else { throw CLIError.usage }
            let config = try store.load()
            let usage = UsageLog(directory: configURL.deletingLastPathComponent().appendingPathComponent("runtime/usage", isDirectory: true)).load()
            let suggestions = AliasSuggester.suggest(usage, catalog: config.catalog(adding: Discovery.apps() + Discovery.systemActions()), limit: 10)
            try printJSON(suggestions.map { Suggestion(actionID: $0.action.id, name: $0.action.name, kind: $0.action.kind, alias: $0.alias, uses: $0.uses, keysPerUse: ($0.keysPerUse * 10).rounded() / 10, keysSaved: $0.keysSaved) })
        case "status":
            guard operands.isEmpty else { throw CLIError.usage }
            if FileManager.default.fileExists(atPath: store.statusURL.path) {
                var object = try JSONSerialization.jsonObject(with: Data(contentsOf: store.statusURL)) as? [String: Any] ?? [:]
                if let pid = object["pid"] as? Int {
                    let probe = kill(pid_t(pid), 0)
                    if probe == 0 || errno == EPERM {
                        object["running"] = true
                        object.removeValue(forKey: "stale")
                    } else if errno == ESRCH {
                        object["running"] = false
                        object["stale"] = true
                    } else {
                        object["statusCheck"] = "unavailable"
                    }
                } else {
                    object["running"] = false
                    object["stale"] = true
                }
                let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self))
            } else {
                print("{\n  \"running\" : false\n}")
            }
        default:
            throw CLIError.usage
        }
    }

    private static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
}

private enum CLIError: Error, LocalizedError {
    case usage

    var errorDescription: String? {
        "Usage: launcherctl [--config PATH] <validate PATH|apply PATH|rollback|list|resolve INPUT|search INPUT|apps|files QUERY|shortcuts|calculate INPUT|suggest|alias ID ALIAS|status>"
    }
}

/// One alias suggestion, as `launcherctl suggest` prints it. It holds counts, never typed text.
private struct Suggestion: Encodable {
    let actionID: String
    let name: String
    let kind: ActionKind
    let alias: String
    let uses: Int
    let keysPerUse: Double
    let keysSaved: Int
}
