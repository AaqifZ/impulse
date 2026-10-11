import AppKit
import ImageIO
import UniformTypeIdentifiers
import LauncherCore

/// Icons for result rows. Catalog icons preload in the background; rows read them from memory.
final class IconProvider {
    typealias Completion = (_ representedKey: String, _ image: NSImage?) -> Void

    private enum Source {
        case website(actionID: String, target: String)
        case bundleID(String)
        case localPath(String)
    }

    private let iconsDirectory: URL
    /// The catalog bounds the keys; this cap only guards against runaway growth.
    private let maximumCacheCount: Int
    private let loaderQueue = DispatchQueue(label: "local.impulse.icons", qos: .userInitiated)
    private let preloadQueue = DispatchQueue(label: "local.impulse.icons.preload", qos: .utility)
    private let lock = NSLock()
    private var images: [String: NSImage] = [:]
    private var negativeKeys = Set<String>()
    private var inFlight: [String: [Completion]] = [:]
    /// Read once at start; loads on several threads only read them.
    private var hostMapping: [String: String] = [:]
    private var actionMapping: [String: String] = [:]
    private var loadAttempts = 0
    /// Rows that had to wait for an icon. Design captures expect zero.
    private(set) var missCount = 0

    /// Actions that run inside another app show that app's icon.
    private static let hostApps: [ActionKind: String] = [
        .system: "com.apple.systempreferences",
        .terminal: "com.apple.Terminal",
        .shortcut: "com.apple.shortcuts",
    ]

    init(iconsDirectory: URL, maximumCacheCount: Int = 1_024) {
        self.iconsDirectory = iconsDirectory.standardizedFileURL
        self.maximumCacheCount = max(1, maximumCacheCount)
        hostMapping = loadHostMapping()
        actionMapping = loadActionMapping()
    }

    func representedKey(for action: LauncherAction) -> String? {
        switch action.kind {
        case .url:
            guard let host = Self.hostname(from: action.target) else { return nil }
            return "website:\(host):\(action.id)"
        case .app:
            let bundleID = action.target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleID.isEmpty else { return nil }
            return "bundle:\(bundleID)"
        case .system, .terminal, .shortcut:
            return Self.hostApps[action.kind].map { "bundle:\($0)" }
        case .application:
            guard Self.safeLocalPath(action.target, requireApplication: true) != nil else { return nil }
            return "application:\((action.target as NSString).standardizingPath)"
        case .file:
            guard Self.safeLocalPath(action.target, requireApplication: false) != nil else { return nil }
            return "file:\((action.target as NSString).standardizingPath)"
        case .workspace, .snippet, .webSearch, .laptopSearch, .emoji, .calculation, .error, .clipboard, .dictation, .local, .theme, .accent, .stats:
            return nil
        }
    }

    func cachedImage(for representedKey: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        return images[representedKey]
    }

    func loadIcon(for action: LauncherAction, completion: @escaping Completion) {
        guard let key = representedKey(for: action), let source = source(for: action) else {
            return
        }

        lock.lock()
        if let image = images[key] {
            lock.unlock()
            DispatchQueue.main.async { completion(key, image) }
            return
        }
        if negativeKeys.contains(key) {
            lock.unlock()
            DispatchQueue.main.async { completion(key, nil) }
            return
        }
        missCount += 1
        // A second request for a key in flight waits for the first load.
        if inFlight[key] != nil {
            inFlight[key]?.append(completion)
            lock.unlock()
            return
        }
        inFlight[key] = [completion]
        lock.unlock()

        loaderQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.loadAttempts += 1
            self.lock.unlock()
            let image = self.load(source: source)

            self.lock.lock()
            let completions = self.inFlight.removeValue(forKey: key) ?? []
            self.storeLocked(image, for: key)
            self.lock.unlock()

            DispatchQueue.main.async {
                for callback in completions { callback(key, image) }
            }
        }
    }

    /// Loads every catalog icon in the background, so rows find them in the cache.
    func preload(_ actions: [LauncherAction], completion: (() -> Void)? = nil) {
        var pending: [(String, Source)] = []
        var seen = Set<String>()
        for action in actions {
            guard let key = representedKey(for: action), seen.insert(key).inserted,
                  let source = source(for: action) else { continue }
            pending.append((key, source))
        }
        preloadQueue.async { [weak self] in
            guard let self else { return }
            // Icon loads are independent; spread them across the cores.
            DispatchQueue.concurrentPerform(iterations: pending.count) { index in
                let (key, source) = pending[index]
                self.lock.lock()
                let known = self.images[key] != nil || self.negativeKeys.contains(key)
                if !known { self.loadAttempts += 1 }
                self.lock.unlock()
                if known { return }
                let image = self.load(source: source)
                self.lock.lock()
                if self.images[key] == nil { self.storeLocked(image, for: key) }
                self.lock.unlock()
            }
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    private static var typeIcons: [String: NSImage] = [:]

    /// The macOS icon for a file's type. One lookup per type, so file rows never wait.
    static func typeIcon(forPath path: String) -> NSImage {
        let url = URL(fileURLWithPath: path)
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension) ?? .data
        if let cached = typeIcons[type.identifier] { return cached }
        let icon = NSWorkspace.shared.icon(for: type)
        let image = rasterized(icon) ?? icon
        typeIcons[type.identifier] = image
        return image
    }

    private func storeLocked(_ image: NSImage?, for key: String) {
        if let image {
            if images.count >= maximumCacheCount { images.removeAll() }
            images[key] = image
            negativeKeys.remove(key)
        } else {
            if negativeKeys.count >= maximumCacheCount { negativeKeys.removeAll() }
            negativeKeys.insert(key)
        }
    }

    private func source(for action: LauncherAction) -> Source? {
        switch action.kind {
        case .url: return .website(actionID: action.id, target: action.target)
        case .app: return .bundleID(action.target)
        case .system, .terminal, .shortcut: return Self.hostApps[action.kind].map { .bundleID($0) }
        case .application:
            guard let path = Self.safeLocalPath(action.target, requireApplication: true) else { return nil }
            return .localPath(path)
        case .file:
            guard let path = Self.safeLocalPath(action.target, requireApplication: false) else { return nil }
            return .localPath(path)
        case .workspace, .snippet, .webSearch, .laptopSearch, .emoji, .calculation, .error, .clipboard, .dictation, .local, .theme, .accent, .stats: return nil
        }
    }

    private func load(source: Source) -> NSImage? {
        switch source {
        case .website(let actionID, let target):
            // A "host/section" entry (for example google.com/maps) wins over the bare host.
            let section = URLComponents(string: target)?.path.split(separator: "/").first.map { "/" + $0.lowercased() } ?? ""
            guard let host = Self.hostname(from: target) else { return nil }
            // A site with no saved logo gets its first letter, never a generic symbol.
            guard let filename = actionMapping[actionID] ?? hostMapping[host + section] ?? hostMapping[host]
            else { return Self.letterTile(for: host) }
            guard let url = safePNGURL(filename: filename) else { return nil }
            return Self.loadPNG(url)
        case .bundleID(let bundleID):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
                  Self.safeLocalPath(url.path, requireApplication: true) != nil
            else { return nil }
            return Self.rasterized(NSWorkspace.shared.icon(forFile: url.path))
        case .localPath(let path):
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return Self.rasterized(NSWorkspace.shared.icon(forFile: path))
        }
    }

    /// hosts.json: "host" or "host/section" to a PNG name. Unsafe entries are dropped.
    private func loadHostMapping() -> [String: String] {
        let decoded = loadFlatMapping(filename: "hosts.json")
        var normalized: [String: String] = [:]
        for rawHost in decoded.keys.sorted() {
            let parts = rawHost.split(separator: "/", maxSplits: 1).map(String.init)
            let section = parts.count == 2 ? parts[1].lowercased() : ""
            guard let host = parts.first.flatMap(Self.normalizedHostname),
                  section.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" }),
                  let filename = decoded[rawHost],
                  Self.isSafePNGBasename(filename)
            else { continue }
            let key = section.isEmpty ? host : host + "/" + section
            guard normalized[key] == nil else { continue }
            normalized[key] = filename
        }
        return normalized
    }

    /// actions.json: an action ID to a PNG name, for actions whose host is not enough.
    private func loadActionMapping() -> [String: String] {
        loadFlatMapping(filename: "actions.json").filter { actionID, filename in
            !actionID.isEmpty && actionID.utf8.count <= 256 && Self.isSafePNGBasename(filename)
        }
    }

    private func loadFlatMapping(filename: String) -> [String: String] {
        let url = iconsDirectory.appendingPathComponent(filename, isDirectory: false)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size <= 262_144,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    private func safePNGURL(filename: String) -> URL? {
        guard Self.isSafePNGBasename(filename) else { return nil }
        let base = iconsDirectory.resolvingSymlinksInPath().standardizedFileURL
        let candidate = iconsDirectory
            .appendingPathComponent(filename, isDirectory: false)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard candidate.deletingLastPathComponent() == base else { return nil }
        return candidate
    }

    private static func hostname(from target: String) -> String? {
        guard let components = URLComponents(string: target),
              let host = components.host
        else { return nil }
        return normalizedHostname(host)
    }

    private static func normalizedHostname(_ value: String) -> String? {
        var host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty,
              host.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-"
              }),
              !host.hasPrefix("."),
              !host.contains("..")
        else { return nil }
        return host
    }

    private static func isSafePNGBasename(_ value: String) -> Bool {
        guard value.utf8.count <= 128,
              value.lowercased().hasSuffix(".png"),
              !value.hasPrefix("."),
              value == (value as NSString).lastPathComponent,
              !value.contains("/"),
              !value.contains("\\")
        else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "." || scalar == "-" || scalar == "_"
        }
    }

    private static func safeLocalPath(_ rawPath: String, requireApplication: Bool) -> String? {
        let path = (rawPath as NSString).standardizingPath
        guard (path as NSString).isAbsolutePath,
              path != "/",
              !path.hasPrefix("/Volumes/"),
              !path.hasPrefix("/Network/"),
              (!requireApplication || path.lowercased().hasSuffix(".app"))
        else { return nil }
        return path
    }

    private static func loadPNG(_ url: URL) -> NSImage? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= 4_194_304,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              (CGImageSourceGetType(source) as String?) == "public.png",
              let image = thumbnail(from: source)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: 22, height: 22))
    }

    /// The first letter of the site name as a template image; the row tints it.
    static func letterTile(for host: String) -> NSImage? {
        let name = host.hasPrefix("www.") ? host.dropFirst(4) : Substring(host)
        guard let first = name.first(where: { $0.isLetter || $0.isNumber }) else { return nil }
        let letter = String(first).uppercased() as NSString
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.black]
            let size = letter.size(withAttributes: attributes)
            letter.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Draws the icon once at 44 px; macOS picks the nearest stored size.
    private static func rasterized(_ image: NSImage) -> NSImage? {
        guard let context = CGContext(
            data: nil, width: 44, height: 44, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: 44, height: 44))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage().map { NSImage(cgImage: $0, size: NSSize(width: 22, height: 22)) }
    }

    private static func thumbnail(from source: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 44,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    fileprivate var diagnostics: (loads: Int, cached: Int, negative: Int, inFlight: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (loadAttempts, images.count, negativeKeys.count, inFlight.count)
    }
}

extension IconProvider {
    static func runChecks() throws {
        struct CheckFailure: Error, CustomStringConvertible { let description: String }
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            guard condition() else { throw CheckFailure(description: label) }
        }
        func awaitIcon(
            _ provider: IconProvider,
            action: LauncherAction,
            expectedCallbacks: Int = 1
        ) throws -> [NSImage?] {
            var values: [NSImage?] = []
            for _ in 0..<expectedCallbacks {
                provider.loadIcon(for: action) { _, image in values.append(image) }
            }
            let deadline = Date().addingTimeInterval(3)
            while values.count < expectedCallbacks && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            try check(values.count == expectedCallbacks, "icon callback timeout")
            return values
        }

        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("impulse-icons-\(UUID().uuidString)", isDirectory: true)
        let icons = root.appendingPathComponent("icons", isDirectory: true)
        try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        bitmap.setColor(
            NSColor(deviceRed: 0.1, green: 0.4, blue: 0.9, alpha: 1),
            atX: 0,
            y: 0
        )
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: icons.appendingPathComponent("good.png"), options: .atomic)
        try Data("not a png".utf8)
            .write(to: icons.appendingPathComponent("corrupt.png"), options: .atomic)
        let mapping = [
            "Example.COM.": "corrupt.png",
            "host-only.example": "good.png",
            "section.example/maps": "good.png",
            "missing.example": "missing.png",
            "corrupt.example": "corrupt.png",
            "escape.example": "../outside.png",
        ]
        try JSONEncoder().encode(mapping)
            .write(to: icons.appendingPathComponent("hosts.json"), options: .atomic)

        let override = ["icon.example.com": "good.png"]
        try JSONEncoder().encode(override)
            .write(to: icons.appendingPathComponent("actions.json"), options: .atomic)

        let provider = IconProvider(iconsDirectory: icons, maximumCacheCount: 2)
        func action(_ host: String) -> LauncherAction {
            LauncherAction(
                id: "icon.\(host)",
                name: host,
                aliases: [host],
                kind: .url,
                target: "https://\(host)/search?q={query}"
            )
        }

        let good = action("example.com")
        let coldStart = DispatchTime.now().uptimeNanoseconds
        let simultaneous = try awaitIcon(provider, action: good, expectedCallbacks: 2)
        let coldNanos = DispatchTime.now().uptimeNanoseconds - coldStart
        try check(simultaneous.allSatisfy { $0 != nil }, "valid local PNG load")
        try check(provider.diagnostics.loads == 1, "in-flight request deduplication")
        guard let key = provider.representedKey(for: good) else {
            throw CheckFailure(description: "valid represented key")
        }
        let warmStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<1_000 { try check(provider.cachedImage(for: key) != nil, "warm cache lookup") }
        let warmNanos = DispatchTime.now().uptimeNanoseconds - warmStart
        _ = try awaitIcon(provider, action: good)
        try check(provider.diagnostics.loads == 1, "warm request avoided repeated load")

        let hostFallback = try awaitIcon(provider, action: action("host-only.example"))
        try check(hostFallback.first! != nil, "hostname mapping fallback")
        let sectioned = LauncherAction(id: "s", name: "s", aliases: [], kind: .url, target: "https://section.example/maps/search?q={query}")
        let sectionedIcon = try awaitIcon(provider, action: sectioned)
        try check(sectionedIcon.first! != nil, "host and section mapping")
        let unsectioned = LauncherAction(id: "u", name: "u", aliases: [], kind: .url, target: "https://section.example/other")
        let unsectionedIcon = try awaitIcon(provider, action: unsectioned)
        try check(unsectionedIcon.first??.isTemplate == true, "section mapping stays in its section")
        let unmapped = try awaitIcon(provider, action: action("www.notion.so"))
        try check(unmapped.first??.isTemplate == true, "unmapped site gets a letter tile")

        // An unsafe entry is dropped, so the site falls back to its letter and never reads the file.
        let escaped = try awaitIcon(provider, action: action("escape.example"))
        try check(escaped.first??.isTemplate == true, "unsafe mapping falls back to a letter tile")
        for missingAction in [action("missing.example"), action("corrupt.example")] {
            let firstMissing = try awaitIcon(provider, action: missingAction)
            try check(firstMissing.first! == nil, "safe missing icon fallback")
            let loads = provider.diagnostics.loads
            let secondMissing = try awaitIcon(provider, action: missingAction)
            try check(secondMissing.first! == nil, "negative cache fallback")
            try check(provider.diagnostics.loads == loads, "negative cache avoided repeated load")
        }

        let row = ResultRowView(frame: NSRect(x: 0, y: 0, width: 660, height: 51))
        row.configure(name: good.name, aliases: good.aliases, detail: "Search", fallbackSymbol: "magnifyingglass", iconKey: "old")
        let missing = action("missing.example")
        row.configure(name: missing.name, aliases: missing.aliases, detail: "Search", fallbackSymbol: "magnifyingglass", iconKey: "new")
        let currentFallback = row.iconImageView.image
        try check(!row.applyLoadedIcon(simultaneous[0]!, for: "old"), "reused row rejected stale icon")
        try check(row.iconImageView.image === currentFallback, "stale icon did not change row")
        try check(row.applyLoadedIcon(simultaneous[0]!, for: "new"), "current row accepted matching icon")
        try check(row.iconImageView.contentTintColor == nil, "loaded icons are not tinted")

        // Actions that run in another app resolve to that app.
        let settings = LauncherAction(id: "system.settings", name: "System Settings", aliases: [], kind: .system, target: "system-settings")
        let shortcut = LauncherAction(id: "shortcut.x", name: "X", aliases: [], kind: .shortcut, target: "X")
        try check(provider.representedKey(for: settings) == "bundle:com.apple.systempreferences", "system host app key")
        try check(provider.representedKey(for: shortcut) == "bundle:com.apple.shortcuts", "shortcut host app key")

        // Preload fills the cache, so rows never wait.
        let warm = IconProvider(iconsDirectory: icons)
        var preloaded = false
        warm.preload([good, settings, shortcut, good]) { preloaded = true }
        let preloadDeadline = Date().addingTimeInterval(5)
        while !preloaded && Date() < preloadDeadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        try check(preloaded, "preload finished")
        for item in [good, settings, shortcut] {
            try check(warm.representedKey(for: item).flatMap(warm.cachedImage(for:)) != nil, "preloaded \(item.kind) icon")
        }
        try check(warm.diagnostics.loads == 3, "preload loads each key once")
        try check(warm.missCount == 0, "preload leaves no misses")

        // File rows use one icon per type, at once.
        let swiftFile = root.appendingPathComponent("a.swift")
        try Data().write(to: swiftFile)
        let swiftIcon = IconProvider.typeIcon(forPath: swiftFile.path)
        try check(IconProvider.typeIcon(forPath: root.appendingPathComponent("b.swift").path) === swiftIcon, "type icon cached per type")
        try check(IconProvider.typeIcon(forPath: root.path) !== swiftIcon, "folder gets its own type icon")

        let diagnostics = provider.diagnostics
        try check(diagnostics.cached <= 2, "bounded positive cache")
        try check(diagnostics.inFlight == 0, "no abandoned in-flight requests")
        let coldMS = Double(coldNanos) / 1_000_000
        let warmMicros = Double(warmNanos) / 1_000
        print(
            String(
                format: "PASS isolated icon checks; cold %.3f ms, 1000 warm lookups %.3f µs, %d disk/system loads",
                coldMS,
                warmMicros,
                diagnostics.loads
            )
        )
    }
}
