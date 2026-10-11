import CryptoKit
import Darwin
import Foundation

public struct ConfigStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url.standardizedFileURL
    }

    public var statusURL: URL {
        url.deletingLastPathComponent().appendingPathComponent("runtime/status.json")
    }

    public func load() throws -> LauncherConfig {
        try snapshot().config
    }

    public func snapshot() throws -> (config: LauncherConfig, revision: String) {
        let data = try Data(contentsOf: url)
        return (try Self.decodeAndValidate(data), Self.revision(of: data))
    }

    public func apply(from source: URL) throws -> String {
        let sourceData = try Data(contentsOf: source)
        _ = try Self.decodeAndValidate(sourceData)
        return try withLock {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let currentData = try? Data(contentsOf: url)
            // A retry of the same config must keep the only recovery point.
            if currentData == sourceData { return Self.revision(of: sourceData) }
            if let currentData, (try? Self.decodeAndValidate(currentData)) != nil {
                try currentData.write(to: rollbackURL, options: [.atomic])
            }
            try sourceData.write(to: url, options: [.atomic])
            return Self.revision(of: sourceData)
        }
    }

    /// Reads the file, changes it, and writes the result in the canonical layout, all under the lock.
    /// The file as it was becomes the rollback point. A change that alters nothing writes nothing.
    public func update(_ change: (LauncherConfig) throws -> LauncherConfig) throws -> (config: LauncherConfig, revision: String) {
        try withLock {
            let currentData = try Data(contentsOf: url)
            let current = try Self.decodeAndValidate(currentData)
            let next = try change(current).validated()
            if next == current { return (current, Self.revision(of: currentData)) }
            let data = next.canonicalJSON()
            try currentData.write(to: rollbackURL, options: [.atomic])
            try data.write(to: url, options: [.atomic])
            return (next, Self.revision(of: data))
        }
    }

    public func rollback() throws -> String {
        try withLock {
            guard let previousData = try? Data(contentsOf: rollbackURL) else {
                throw LauncherError.rollbackUnavailable
            }
            _ = try Self.decodeAndValidate(previousData)
            let currentData = try? Data(contentsOf: url)
            try previousData.write(to: url, options: [.atomic])
            if let currentData, (try? Self.decodeAndValidate(currentData)) != nil {
                try currentData.write(to: rollbackURL, options: [.atomic])
            }
            return Self.revision(of: previousData)
        }
    }

    public func revision() throws -> String {
        try snapshot().revision
    }

    public static func validate(url: URL) throws -> LauncherConfig {
        try decodeAndValidate(Data(contentsOf: url))
    }

    public static func revision(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private var rollbackURL: URL {
        url.deletingPathExtension().appendingPathExtension("previous.json")
    }

    private var lockURL: URL {
        url.appendingPathExtension("lock")
    }

    private static func decodeAndValidate(_ data: Data) throws -> LauncherConfig {
        do {
            return try JSONDecoder().decode(LauncherConfig.self, from: data).validated()
        } catch let error as LauncherError {
            throw error
        } catch {
            throw LauncherError.malformedConfiguration(error.localizedDescription)
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw LauncherError.lockFailed(String(cString: strerror(errno)))
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw LauncherError.lockFailed(String(cString: strerror(errno)))
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
