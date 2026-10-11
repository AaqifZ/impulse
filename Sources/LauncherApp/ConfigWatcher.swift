import Darwin
import Foundation
import LauncherCore

final class ConfigWatcher {
    typealias Snapshot = (config: LauncherConfig, revision: String)
    typealias ChangeHandler = (Result<Snapshot, Error>) -> Void

    private enum WatchError: Error, CustomStringConvertible {
        case cannotWatchDirectory(String, Int32)

        var description: String {
            switch self {
            case .cannotWatchDirectory(let path, let code):
                return "Cannot watch configuration directory \(path) (errno \(code))"
            }
        }
    }

    private enum Fingerprint: Equatable {
        case missing(Int32)
        case file(
            device: UInt64,
            inode: UInt64,
            size: Int64,
            modifiedSeconds: Int64,
            modifiedNanoseconds: Int64,
            changedSeconds: Int64,
            changedNanoseconds: Int64
        )
    }

    private let url: URL
    private let directoryURL: URL
    private let onChange: ChangeHandler
    private let queue = DispatchQueue(label: "local.impulse.config-watcher", qos: .userInitiated)
    private let callbackLock = NSLock()
    private var callbacksEnabled = false

    // Accessed only on queue.
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var debounceWork: DispatchWorkItem?
    private var lastFingerprint: Fingerprint?
    private var eventSequence: UInt64 = 0
    private var processedSequence: UInt64 = 0
    private var started = false

    init(url: URL, onChange: @escaping ChangeHandler) {
        self.url = url.standardizedFileURL
        self.directoryURL = url.deletingLastPathComponent().standardizedFileURL
        self.onChange = onChange
    }

    func start() {
        setCallbacksEnabled(true)
        queue.async { [weak self] in self?.startOnQueue() }
    }

    func requestReload() {
        queue.async { [weak self] in
            guard let self, self.started else { return }
            self.eventSequence &+= 1
            self.scheduleReload(force: true)
        }
    }

    func stop() {
        setCallbacksEnabled(false)
        queue.async { [weak self] in self?.stopOnQueue() }
    }

    deinit {
        setCallbacksEnabled(false)
        debounceWork?.cancel()
        fileSource?.cancel()
        directorySource?.cancel()
    }

    private func startOnQueue() {
        guard !started else { return }
        let descriptor = open(directoryURL.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            deliver(.failure(WatchError.cannotWatchDirectory(directoryURL.path, errno)))
            return
        }

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .attrib, .extend, .link, .revoke],
            queue: queue
        )
        newSource.setEventHandler { [weak self] in
            guard let self, self.started else { return }
            self.eventSequence &+= 1
            self.scheduleReload(force: false)
        }
        newSource.setCancelHandler { close(descriptor) }
        directorySource = newSource
        lastFingerprint = fingerprint()
        started = true
        newSource.resume()
        armFileSource()
    }

    private func stopOnQueue() {
        guard started || directorySource != nil || fileSource != nil else { return }
        started = false
        eventSequence &+= 1
        processedSequence = eventSequence
        debounceWork?.cancel()
        debounceWork = nil
        fileSource?.setEventHandler {}
        fileSource?.cancel()
        fileSource = nil
        directorySource?.setEventHandler {}
        directorySource?.cancel()
        directorySource = nil
        lastFingerprint = nil
    }

    private func scheduleReload(force: Bool) {
        debounceWork?.cancel()
        let scheduledSequence = eventSequence
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.started else { return }
            self.processReload(sequence: scheduledSequence, force: force)
        }
        debounceWork = work
        queue.asyncAfter(deadline: .now() + .milliseconds(50), execute: work)
    }

    private func processReload(sequence: UInt64, force: Bool) {
        guard started else { return }
        debounceWork = nil
        let initialFingerprint = fingerprint()
        if !force, initialFingerprint == lastFingerprint {
            processedSequence = max(processedSequence, sequence)
            return
        }

        var before = initialFingerprint
        var result: Result<Snapshot, Error> = Result {
            let snapshot = try ConfigStore(url: url).snapshot()
            return (snapshot.config, snapshot.revision)
        }
        var after = fingerprint()

        // An atomic replacement or direct edit may land while the snapshot is
        // being read. Re-read until the observed target is stable, with a
        // finite bound so a continuously changing writer cannot starve queue.
        var retries = 0
        while before != after && retries < 3 {
            before = after
            result = Result {
                let snapshot = try ConfigStore(url: url).snapshot()
                return (snapshot.config, snapshot.revision)
            }
            after = fingerprint()
            retries += 1
        }

        processedSequence = max(processedSequence, sequence)
        guard before == after else {
            // Never publish a snapshot whose bytes may not correspond to the
            // final fingerprint. Force another pass instead.
            lastFingerprint = nil
            armFileSource()
            eventSequence &+= 1
            scheduleReload(force: true)
            return
        }

        lastFingerprint = after
        armFileSource()
        let fingerprintAfterRearm = fingerprint()
        guard fingerprintAfterRearm == after else {
            // Covers the gap between the final read and attaching the new
            // file-descriptor source after an inode replacement.
            lastFingerprint = nil
            eventSequence &+= 1
            scheduleReload(force: true)
            return
        }

        deliver(result)
        if processedSequence < eventSequence {
            eventSequence &+= 1
            scheduleReload(force: true)
        }
    }

    private func fingerprint() -> Fingerprint {
        var metadata = stat()
        guard stat(url.path, &metadata) == 0 else { return .missing(errno) }
        return .file(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            size: Int64(metadata.st_size),
            modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
            changedSeconds: Int64(metadata.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(metadata.st_ctimespec.tv_nsec)
        )
    }

    private func armFileSource() {
        fileSource?.setEventHandler {}
        fileSource?.cancel()
        fileSource = nil
        guard started else { return }

        let descriptor = open(url.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .attrib, .extend, .link, .revoke],
            queue: queue
        )
        newSource.setEventHandler { [weak self] in
            guard let self, self.started else { return }
            self.eventSequence &+= 1
            self.scheduleReload(force: false)
        }
        newSource.setCancelHandler { close(descriptor) }
        fileSource = newSource
        newSource.resume()
    }

    private func deliver(_ result: Result<Snapshot, Error>) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.areCallbacksEnabled() else { return }
            self.onChange(result)
        }
    }

    private func setCallbacksEnabled(_ enabled: Bool) {
        callbackLock.lock()
        callbacksEnabled = enabled
        callbackLock.unlock()
    }

    private func areCallbacksEnabled() -> Bool {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        return callbacksEnabled
    }
}

extension ConfigWatcher {
    static func runChecks() throws {
        struct CheckFailure: Error, CustomStringConvertible { let description: String }
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            guard condition() else { throw CheckFailure(description: label) }
        }
        func action(_ suffix: String) -> LauncherAction {
            LauncherAction(
                id: "watcher.\(suffix)",
                name: "Watcher \(suffix)",
                aliases: ["watcher-\(suffix)"],
                kind: .url,
                target: "https://example.com/\(suffix)"
            )
        }
        func write(_ config: LauncherConfig, to url: URL) throws {
            try JSONEncoder().encode(config).write(to: url, options: .atomic)
        }
        func writeInPlace(_ config: LauncherConfig, to url: URL) throws {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: JSONEncoder().encode(config))
            try handle.synchronize()
        }
        func runMainLoop(until predicate: () -> Bool, timeout: TimeInterval = 3) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !predicate() && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            return predicate()
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("impulse-watcher-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = root.appendingPathComponent("config", isDirectory: true)
        let configURL = configDirectory.appendingPathComponent("actions.json")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = LauncherConfig(version: 1, actions: [action("one")])
        let second = LauncherConfig(version: 1, actions: [action("two")])
        try write(first, to: configURL)

        var callbackCount = 0
        var successCount = 0
        var failureCount = 0
        var lastGoodID: String?
        let watcher = ConfigWatcher(url: configURL) { result in
            callbackCount += 1
            switch result {
            case .success(let snapshot):
                successCount += 1
                lastGoodID = snapshot.config.actions.first?.id
            case .failure:
                failureCount += 1
            }
        }
        watcher.start()
        watcher.requestReload()
        try check(runMainLoop(until: { successCount == 1 }), "initial requested snapshot")
        try check(lastGoodID == "watcher.one", "initial snapshot contents")

        try writeInPlace(second, to: configURL)
        try check(
            runMainLoop(until: { lastGoodID == "watcher.two" && successCount == 2 }),
            "in-place content write event"
        )

        try write(first, to: configURL)
        try check(
            runMainLoop(until: { lastGoodID == "watcher.one" && successCount == 3 }),
            "atomic replacement event"
        )

        try Data("{invalid".utf8).write(to: configURL, options: .atomic)
        try check(runMainLoop(until: { failureCount == 1 }), "invalid configuration signal")
        try check(lastGoodID == "watcher.one", "invalid snapshot did not replace last good state")

        try FileManager.default.removeItem(at: configURL)
        try check(runMainLoop(until: { failureCount == 2 }), "delete event")
        try write(second, to: configURL)
        try check(runMainLoop(until: { lastGoodID == "watcher.two" && successCount == 4 }), "recreate event")

        let stableCount = callbackCount
        let runtime = configDirectory.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try Data("{}".utf8).write(
            to: runtime.appendingPathComponent("status.json"),
            options: .atomic
        )
        _ = runMainLoop(until: { false }, timeout: 0.15)
        try check(callbackCount == stableCount, "unrelated runtime writes ignored")

        watcher.stop()
        try write(second, to: configURL)
        _ = runMainLoop(until: { false }, timeout: 0.15)
        try check(callbackCount == stableCount, "shutdown suppresses callbacks")
        print("PASS ConfigWatcher in-place/atomic writes, invalid, delete/recreate, filtering, and shutdown checks")
    }
}
