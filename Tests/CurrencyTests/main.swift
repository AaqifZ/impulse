import Foundation
import LauncherCore

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private final class IntBox: @unchecked Sendable {
    var value = 0
}

private final class URLBox: @unchecked Sendable {
    var value: URL?
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw TestFailure(description: message) }
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func response(_ rate: String, date: String = "2026-09-11", base: String = "USD", quote: String = "AUD") -> Data {
    Data("[{\"date\":\"\(date)\",\"base\":\"\(base)\",\"quote\":\"\(quote)\",\"rate\":\(rate)}]".utf8)
}

private func cache(_ rate: String, date: String = "2026-09-10", fetchedAt: String = "2020-01-01T00:00:00Z") -> Data {
    Data("{\"version\":1,\"rates\":{\"USD/AUD\":{\"base\":\"USD\",\"quote\":\"AUD\",\"rate\":\"\(rate)\",\"date\":\"\(date)\",\"fetchedAt\":\"\(fetchedAt)\"}}}".utf8)
}

@main
struct CurrencyTestRunner {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("recognizes explicit ISO forms", testRecognizesExplicitForms),
            ("rejects ambiguous currency symbols", testRejectsAmbiguousSymbols),
            ("builds code-only Frankfurter request", testRequest),
            ("multiplies and records source date", testConversion),
            ("writes amount-free cache", testCache),
            ("uses fresh cache without network", testFreshCache),
            ("falls back to stale offline cache", testStaleOffline),
            ("returns error for malformed response", testMalformedResponse),
            ("rejects invalid source dates", testInvalidSourceDate),
            ("rejects future source dates", testFutureSourceDate),
            ("rejects future cached source dates", testFutureCachedSourceDate),
            ("rejects overflowing finite conversion", testOverflow),
            ("returns nil for non-currency input", testNonCurrency),
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
        print("PASS \(tests.count) Currency tests")
    }

    private static func testRecognizesExplicitForms() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = IntBox()
        let converter = CurrencyConverter { request in
            calls.value += 1
            return (response("1.5"), 200)
        }
        try expect(converter.convert("100 USD in AUD", cacheURL: directory.appendingPathComponent("rates.json"))?.isError == false, "in form not recognized")
        try expect(converter.convert("fx 100 USD AUD", cacheURL: directory.appendingPathComponent("other.json"))?.isError == false, "fx form not recognized")
        try expect(calls.value == 2, "expected two injected requests")
    }

    private static func testRejectsAmbiguousSymbols() throws {
        let converter = CurrencyConverter { _ in
            throw TestFailure(description: "transport should not run")
        }
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try expect(converter.convert("$100 in AUD", cacheURL: cacheURL) == nil, "currency symbol was accepted")
        try expect(converter.convert("100 USD in $", cacheURL: cacheURL) == nil, "currency symbol quote was accepted")
    }

    private static func testRequest() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheURL = directory.appendingPathComponent("rates.json")
        let captured = URLBox()
        let converter = CurrencyConverter { request in
            captured.value = request.url
            return (response("1.5"), 200)
        }
        _ = converter.convert("100 USD in AUD", cacheURL: cacheURL)
        guard let url = captured.value, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw TestFailure(description: "request was not captured")
        }
        try expect(components.host == "api.frankfurter.dev", "wrong Frankfurter host")
        try expect(components.path == "/v2/rates", "wrong v2 endpoint")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        try expect(query["base"] == "USD" && query["quotes"] == "AUD", "request did not contain only ISO currency parameters")
        try expect(!query.values.contains(where: { $0.contains("100") }), "amount leaked into request")
    }

    private static func testConversion() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let converter = CurrencyConverter { _ in (response("1.2345"), 200) }
        let result = converter.convert("100 USD in AUD", cacheURL: directory.appendingPathComponent("rates.json"))
        try expect(result?.value == "123.45 AUD", "unexpected converted value: \(result?.value ?? "nil")")
        try expect(result?.detail.contains("Frankfurter reference 2026-09-11") == true, "source date missing")
        try expect(result?.detail.contains("fetched now") == true, "fresh state missing")
        try expect(result?.isError == false, "successful conversion marked as error")
    }

    private static func testCache() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheURL = directory.appendingPathComponent("nested/rates.json")
        let converter = CurrencyConverter { _ in (response("1.5"), 200) }
        _ = converter.convert("100 USD in AUD", cacheURL: cacheURL)
        let data = try Data(contentsOf: cacheURL)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let serialized = String(decoding: data, as: UTF8.self)
        try expect(object["version"] as? Int == 1, "cache version missing")
        try expect(serialized.contains("fetchedAt") && serialized.contains("date"), "cache timestamps missing")
        try expect(!serialized.contains("100"), "requested amount was persisted in cache")
    }

    private static func testFreshCache() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheURL = directory.appendingPathComponent("rates.json")
        try cache("1.5", fetchedAt: ISO8601DateFormatter().string(from: Date())) .write(to: cacheURL)
        let converter = CurrencyConverter { _ in
            throw TestFailure(description: "network should not run for fresh cache")
        }
        let result = converter.convert("100 USD in AUD", cacheURL: cacheURL)
        try expect(result?.value == "150 AUD", "fresh cache value not used")
        try expect(result?.detail.contains("cached") == true, "cached state missing")
    }

    private static func testStaleOffline() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheURL = directory.appendingPathComponent("rates.json")
        try cache("1.5").write(to: cacheURL)
        let converter = CurrencyConverter { _ in
            throw TestFailure(description: "offline")
        }
        let result = converter.convert("100 USD in AUD", cacheURL: cacheURL)
        try expect(result?.value == "150 AUD", "stale cache value not used")
        try expect(result?.detail.contains("stale/offline cache") == true, "stale/offline state missing")
        try expect(result?.isError == false, "stale cache incorrectly marked as hard error")
    }

    private static func testMalformedResponse() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let converter = CurrencyConverter { _ in (Data("{\"not\":\"rates\"}".utf8), 200) }
        let result = converter.convert("100 USD in AUD", cacheURL: directory.appendingPathComponent("rates.json"))
        try expect(result?.isError == true, "malformed response was accepted")
        try expect(result?.detail.contains("USD/AUD") == true, "error did not identify currency pair")
    }

    private static func testInvalidSourceDate() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let converter = CurrencyConverter { _ in
            (response("1.5", date: "2026-02-30"), 200)
        }
        let result = converter.convert("100 USD in AUD", cacheURL: directory.appendingPathComponent("rates.json"))
        try expect(result?.isError == true, "invalid Gregorian source date was accepted")
    }

    private static func testFutureSourceDate() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let converter = CurrencyConverter { _ in
            (response("1.5", date: utcDateString(offsetDays: 1)), 200)
        }
        let cacheURL = directory.appendingPathComponent("rates.json")
        let result = converter.convert("100 USD in AUD", cacheURL: cacheURL)
        try expect(result?.isError == true, "future network source date was accepted")
        try expect(!FileManager.default.fileExists(atPath: cacheURL.path), "future rate was written to cache")
    }

    private static func testFutureCachedSourceDate() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheURL = directory.appendingPathComponent("rates.json")
        try cache("1.5", date: utcDateString(offsetDays: 1)).write(to: cacheURL)
        let converter = CurrencyConverter { _ in
            throw TestFailure(description: "offline")
        }
        let result = converter.convert("100 USD in AUD", cacheURL: cacheURL)
        try expect(result?.isError == true, "future cached source date was trusted offline")
    }

    private static func utcDateString(offsetDays: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(byAdding: .day, value: offsetDays, to: Date())!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }

    private static func testOverflow() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let huge = "1" + String(repeating: "0", count: 127)
        let converter = CurrencyConverter { _ in
            (response(huge), 200)
        }
        let result = converter.convert(
            huge + " USD in AUD",
            cacheURL: directory.appendingPathComponent("rates.json")
        )
        try expect(
            result?.isError == true,
            "finite operands that overflowed Decimal were accepted: " + String(describing: result)
        )
        try expect(
            result?.value == "Error",
            "overflow did not return an error value: " + String(describing: result)
        )
    }

    private static func testNonCurrency() throws {
        let converter = CurrencyConverter { _ in
            throw TestFailure(description: "transport should not run")
        }
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try expect(converter.convert("100 USD", cacheURL: cacheURL) == nil, "missing quote was recognized")
        try expect(converter.convert("what is USD in AUD", cacheURL: cacheURL) == nil, "free text was recognized")
    }
}
