import AppKit
import LauncherCore

enum PerformanceChecks {
    static func run() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("actions.json")
        let old = ProcessInfo.processInfo.environment["IMPULSE_CONFIG"]
        setenv("IMPULSE_CONFIG", url.path, 1)
        defer {
            if let old { setenv("IMPULSE_CONFIG", old, 1) } else { unsetenv("IMPULSE_CONFIG") }
            try? FileManager.default.removeItem(at: root)
        }
        let actions = (0..<200).map { index in
            LauncherAction(id: "fixture.\(index)", name: "Destination \(index)", aliases: ["dest\(index)"], kind: .url, target: "https://example.com/search?q={query}")
        }
        try JSONEncoder().encode(LauncherConfig(version: 1, actions: actions)).write(to: url)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let app = AppDelegate(clipboard: ClipboardHistory(pasteboard: board))
        app.setupPanel()
        app.reloadConfig()
        defer { app.queryWork?.cancel(); app.panel.orderOut(nil); app.panel.close() }
        for _ in 0..<100 {
            app.show()
            for query in ["dest1", "dest10", "dest10 cats"] {
                app.field.stringValue = query
                app.refreshResults()
            }
            app.hide()
        }
        let data = try JSONSerialization.data(withJSONObject: app.performance.summary(), options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
