import Foundation

/// Main-thread recording only. These are handler durations, not screen presentation times.
final class PerformanceMetrics {
    enum Operation: String, CaseIterable { case openHandler, resultsHandler, enterHandler }
    private var samples: [Operation: [Double]] = [:]
    private var counts: [Operation: Int] = [:]
    private let writer = DispatchQueue(label: "local.impulse.timings", qos: .utility)
    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    func record(_ operation: Operation, since start: UInt64) {
        let elapsed = Double(Self.now() - start) / 1_000_000
        counts[operation, default: 0] += 1
        samples[operation, default: []].append(elapsed)
        if samples[operation, default: []].count > 256 { samples[operation]?.removeFirst() }
    }

    func summary() -> [String: Any] {
        var operations: [String: Any] = [:]
        for operation in Operation.allCases {
            let sorted = (samples[operation] ?? []).sorted()
            guard !sorted.isEmpty else { continue }
            operations[operation.rawValue] = [
                "totalCount": counts[operation, default: 0], "sampleCount": sorted.count,
                "medianMs": sorted[(sorted.count - 1) / 2],
                "p95Ms": sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)],
                "maxMs": sorted.last!
            ]
        }
        return ["version": 1, "scope": "current-session-last-256-per-operation", "measurement": "synchronous-handler-not-frame-or-destination-ready", "operations": operations]
    }

    func flush(to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: summary(), options: [.sortedKeys, .prettyPrinted]) else { return }
        writer.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
