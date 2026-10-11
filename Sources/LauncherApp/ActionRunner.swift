import AppKit
import LauncherCore

/// Opens, copies, and runs things on this Mac. Each call reports one outcome on the main
/// thread; the app records it and decides what the panel shows.
final class ActionRunner {
    struct Outcome: Equatable {
        /// The status recorded in status.json. Nil records nothing.
        var status: String?
        /// The footer message. Nil leaves the footer as it is.
        var message: String?
        /// True when the panel hides because the action finished.
        var hides = false

        static func opened(_ ok: Bool, failure: String?) -> Outcome {
            ok ? Outcome(status: "opened", hides: true) : Outcome(status: "open-failed", message: failure)
        }
    }
    typealias Done = (Outcome) -> Void

    /// The Shortcut process. It stays set until the process has exited, even after a timeout.
    private(set) var runningShortcut: Process?
    /// True after the time limit asked the Shortcut to stop and it has not exited yet.
    private(set) var shortcutStopping = false
    /// The Shortcuts tool and its limit. Self-tests swap in a stand-in tool and a short limit.
    var shortcutsTool = URL(fileURLWithPath: "/usr/bin/shortcuts")
    var shortcutLimit: TimeInterval = 120
    private let workspace = NSWorkspace.shared

    /// Opens a web address, in the configured browser when there is one.
    func open(_ value: String, browser: String?, done: @escaping Done) {
        guard let url = URL(string: value) else { return done(Outcome(message: "Invalid destination.")) }
        guard let browser else {
            return done(.opened(workspace.open(url), failure: "Could not open destination."))
        }
        guard let app = workspace.urlForApplication(withBundleIdentifier: browser) else {
            return done(Outcome(status: "browser-not-found", message: "Configured browser is not installed."))
        }
        workspace.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            Self.onMain(done, .opened(error == nil, failure: "Could not open destination."))
        }
    }

    /// Opens an app by bundle ID (a configured "app" action).
    func openApp(bundleID: String, done: @escaping Done) {
        guard let app = workspace.urlForApplication(withBundleIdentifier: bundleID) else {
            return done(Outcome(status: "app-not-found", message: "App not installed: \(bundleID)"))
        }
        openApplication(at: app, failure: "Could not open app.", done: done)
    }

    /// Opens the app at a path. A nil failure message leaves the footer alone on failure.
    func openApplication(at url: URL, failure: String?, done: @escaping Done) {
        workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            Self.onMain(done, .opened(error == nil, failure: failure))
        }
    }

    func openFile(_ path: String) -> Outcome {
        .opened(workspace.open(URL(fileURLWithPath: path)), failure: "File is unavailable or cannot be opened.")
    }

    /// Opens the folder that holds a file (laptop search), or the folder itself.
    func openSourceFolder(of path: String) -> Outcome {
        guard FileManager.default.fileExists(atPath: path) else { return Outcome(message: "File is no longer available.") }
        let ok = workspace.open(Self.sourceFolder(for: path))
        return ok ? Outcome(status: "opened-source-folder", hides: true) : Outcome(status: "open-failed", message: "Could not open source folder.")
    }

    /// A folder opens itself; a file opens the folder that holds it.
    static func sourceFolder(for path: String) -> URL {
        var isDirectory: ObjCBool = false
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue { return url }
        return url.deletingLastPathComponent()
    }

    /// Puts a rendered snippet on the general pasteboard.
    func copySnippet(_ text: String) -> Outcome {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else {
            return Outcome(status: "copy-failed", message: "Could not copy snippet.")
        }
        return Outcome(status: "copied", message: "Copied. Paste with ⌘V.", hides: true)
    }

    /// Runs a .command file in a new Terminal window.
    func runTerminal(_ path: String, done: @escaping Done) {
        guard FileManager.default.isExecutableFile(atPath: path),
              let terminal = workspace.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            return done(Outcome(status: "terminal-unavailable", message: "Terminal or the command file is unavailable."))
        }
        workspace.open([URL(fileURLWithPath: path)], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            Self.onMain(done, .opened(error == nil, failure: "Could not start Terminal."))
        }
    }

    /// Opens a workspace URL (for example hammerspoon://my-layout) in the app that handles its scheme.
    /// The outcome means the request was delivered, not that the layout exists. Starts that app first when it is not running.
    func openWorkspace(_ target: String, progress: @escaping (String) -> Void, done: @escaping Done) {
        guard let url = URL(string: target), let appURL = workspace.urlForApplication(toOpen: url) else {
            return done(Outcome(status: "workspace-unavailable", message: "No app handles this workspace URL."))
        }
        // Impulse hands the request over and does not see the layout finish.
        // "requested" says exactly that; the handling app reports its own result.
        let finish = { [workspace] in
            let ok = workspace.open(url)
            done(ok ? Outcome(status: "requested", hides: true) : Outcome(status: "open-failed", message: "Could not request workspace."))
        }
        let bundleID = Bundle(url: appURL)?.bundleIdentifier
        if let bundleID, !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty { return finish() }
        let name = FileManager.default.displayName(atPath: appURL.path).replacingOccurrences(of: ".app", with: "")
        progress("Starting \(name)…")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        workspace.openApplication(at: appURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                guard error == nil else {
                    return done(Outcome(status: "handler-open-failed", message: "Could not start \(name)."))
                }
                // Apps such as Hammerspoon register URL handlers while they load.
                // Wait before delivery so the first cold-start request is not lost.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: finish)
            }
        }
    }

    /// Asks Hammerspoon to press ⌘V in the app that has focus. It holds Accessibility permission; Impulse does not.
    /// False when Hammerspoon is not running: the copied text stays on the clipboard.
    @discardableResult func requestPaste() -> Bool {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "org.hammerspoon.Hammerspoon").isEmpty,
              let url = URL(string: "hammerspoon://impulse-paste") else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        workspace.open(url, configuration: configuration)
        return true
    }

    /// Runs an Apple Shortcut by name, with a 2-minute limit. One Shortcut runs at a time.
    func runShortcut(_ name: String, done: @escaping Done) {
        guard runningShortcut == nil else { return }
        let process = Process()
        process.executableURL = shortcutsTool
        process.arguments = ["run", name]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self, self.runningShortcut === finished else { return }
                self.runningShortcut = nil
                // A timed-out run already reported its one outcome; its exit only frees the slot.
                if self.shortcutStopping { self.shortcutStopping = false; return }
                done(finished.terminationStatus == 0
                    ? Outcome(status: "completed", message: "Shortcut completed.")
                    : Outcome(status: "shortcut-failed", message: "Shortcut failed or was cancelled."))
            }
        }
        do { runningShortcut = process; try process.run() }
        catch { runningShortcut = nil; done(Outcome(message: "Could not run Shortcut.")) }
        DispatchQueue.main.asyncAfter(deadline: .now() + shortcutLimit) { [weak self, weak process] in
            guard let self, let process, self.runningShortcut === process, process.isRunning else { return }
            // Asking is not stopping: keep the slot until the termination handler sees the exit.
            self.shortcutStopping = true
            process.terminate()
            done(Outcome(status: "shortcut-timeout", message: "Shortcut exceeded 2 minutes; stop requested. Check Shortcuts for any continuing actions."))
        }
    }

    /// Stops a running Shortcut (on quit).
    func stopShortcut() {
        if runningShortcut?.isRunning == true { runningShortcut?.terminate() }
    }

    private static func onMain(_ done: @escaping Done, _ outcome: Outcome) {
        DispatchQueue.main.async { done(outcome) }
    }
}
