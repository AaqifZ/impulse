import Foundation

/// A small, deterministic currency conversion action.
///
/// The live API request contains only the two ISO currency codes. Amounts are
/// multiplied locally and the response is cached without storing the amount
/// that was requested.
public struct CurrencyConverter: Sendable {
    public typealias Transport = @Sendable (_ request: URLRequest) throws -> (data: Data, statusCode: Int)

    private struct Request: Equatable, Sendable {
        let amount: Decimal
        let base: String
        let quote: String
    }

    private struct RateRow: Codable, Equatable, Sendable {
        let date: String
        let base: String
        let quote: String
        let rate: Decimal

        enum CodingKeys: String, CodingKey {
            case date, base, quote, rate
        }

        init(date: String, base: String, quote: String, rate: Decimal) {
            self.date = date
            self.base = base
            self.quote = quote
            self.rate = rate
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            date = try container.decode(String.self, forKey: .date)
            base = try container.decode(String.self, forKey: .base)
            quote = try container.decode(String.self, forKey: .quote)

            if let decoded = try? container.decode(Decimal.self, forKey: .rate) {
                rate = decoded
            } else {
                let encoded = try container.decode(String.self, forKey: .rate)
                guard let decoded = Decimal(string: encoded, locale: Locale(identifier: "en_US_POSIX")) else {
                    throw CurrencyError.malformedResponse
                }
                rate = decoded
            }
        }
    }

    private struct CachedRate: Codable, Equatable, Sendable {
        let base: String
        let quote: String
        let rate: String
        let date: String
        let fetchedAt: Date

        init(base: String, quote: String, rate: Decimal, date: String, fetchedAt: Date) {
            self.base = base
            self.quote = quote
            self.rate = NSDecimalNumber(decimal: rate).stringValue
            self.date = date
            self.fetchedAt = fetchedAt
        }

        var decimalRate: Decimal? {
            Decimal(string: rate, locale: Locale(identifier: "en_US_POSIX"))
        }
    }

    private struct CacheFile: Codable, Equatable, Sendable {
        let version: Int
        var rates: [String: CachedRate]
    }

    private enum CurrencyError: Error {
        case invalidRequest
        case timedOut
        case httpStatus(Int)
        case malformedResponse
        case mismatchedResponse
        case invalidRate
    }

    private enum CacheState {
        case fresh
        case cached
        case staleOffline
    }

    private final class ResponseBox: @unchecked Sendable {
        var data: Data?
        var statusCode: Int?
    }

    private static let endpoint = URL(string: "https://api.frankfurter.dev/v2/rates")!
    private static let cacheTTL: TimeInterval = 12 * 60 * 60
    private let transport: Transport

    /// Uses the live Frankfurter v2 endpoint.
    public init() {
        self.transport = Self.liveTransport
    }

    /// Injectable transport for deterministic tests and local verification.
    public init(transport: @escaping Transport) {
        self.transport = transport
    }

    /// Converts an explicit ISO-code expression, or returns nil when the
    /// input is not a currency expression.
    ///
    /// Supported forms include `100 USD in AUD` and `fx 100 USD AUD`.
    /// The synchronous call is bounded at the network layer and should be
    /// invoked away from the palette's main/UI thread.
    public static func convert(_ input: String, cacheURL: URL) -> CalculationResult? {
        CurrencyConverter().convert(input, cacheURL: cacheURL)
    }

    /// Instance form used by callers that need an injected transport.
    public func convert(_ input: String, cacheURL: URL) -> CalculationResult? {
        guard let request = Self.parse(input) else { return nil }

        let now = Date()
        let key = Self.cacheKey(base: request.base, quote: request.quote)
        let existing = Self.readCache(at: cacheURL)?[key]
        let usableExisting = existing.flatMap { cached -> CachedRate? in
            guard cached.base == request.base,
                  cached.quote == request.quote,
                  let rate = cached.decimalRate,
                  Self.validRate(rate),
                  Self.validSourceDate(cached.date, now: now) else { return nil }
            return cached
        }

        if let cached = usableExisting,
           now.timeIntervalSince(cached.fetchedAt) >= 0,
           now.timeIntervalSince(cached.fetchedAt) <= Self.cacheTTL,
           let rate = cached.decimalRate {
            return Self.result(for: request, rate: rate, date: cached.date, state: .cached)
        }

        do {
            let row = try Self.fetch(
                base: request.base,
                quote: request.quote,
                transport: transport,
                now: now
            )
            let cacheEntry = CachedRate(
                base: request.base,
                quote: request.quote,
                rate: row.rate,
                date: row.date,
                fetchedAt: now
            )
            Self.writeCache(cacheEntry, key: key, at: cacheURL)
            return Self.result(for: request, rate: row.rate, date: row.date, state: .fresh)
        } catch {
            guard let cached = usableExisting, let rate = cached.decimalRate else {
                return Self.failure(for: request, detail: "Frankfurter rate unavailable")
            }
            return Self.result(for: request, rate: rate, date: cached.date, state: .staleOffline)
        }
    }

    private static let liveTransport: Transport = { request in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3.2
        configuration.timeoutIntervalForResource = 3.2
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let semaphore = DispatchSemaphore(value: 0)
        let response = ResponseBox()

        let task = session.dataTask(with: request) { data, urlResponse, _ in
            response.data = data
            response.statusCode = (urlResponse as? HTTPURLResponse)?.statusCode
            semaphore.signal()
        }
        task.resume()

        guard semaphore.wait(timeout: .now() + 3.6) == .success else {
            task.cancel()
            throw CurrencyError.timedOut
        }
        guard let data = response.data, let statusCode = response.statusCode else {
            throw CurrencyError.malformedResponse
        }
        return (data, statusCode)
    }

    private static func parse(_ input: String) -> Request? {
        let words = input.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return nil }

        let tokens: [String]
        if words.first?.lowercased() == "fx" {
            tokens = Array(words.dropFirst())
        } else {
            tokens = words
        }

        guard tokens.count == 3 || tokens.count == 4,
              let amount = parseAmount(tokens[0]),
              let base = parseCurrencyCode(tokens[1]) else { return nil }

        let quote: String
        if tokens.count == 3 {
            guard let parsed = parseCurrencyCode(tokens[2]) else { return nil }
            quote = parsed
        } else {
            guard ["in", "to", "into", "as"].contains(tokens[2].lowercased()),
                  let parsed = parseCurrencyCode(tokens[3]) else { return nil }
            quote = parsed
        }

        return Request(amount: amount, base: base, quote: quote)
    }

    private static func parseAmount(_ value: String) -> Decimal? {
        let pattern = #"^[+-]?(?:(?:\d{1,3}(?:,\d{3})+)|\d+)(?:\.\d+)?$|^[+-]?\.\d+$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let normalized = value.replacingOccurrences(of: ",", with: "")
        guard let amount = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")),
              amount.isFinite else { return nil }
        return amount
    }

    private static func parseCurrencyCode(_ value: String) -> String? {
        guard value.unicodeScalars.count == 3,
              value.unicodeScalars.allSatisfy({
                  ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122)
              }) else { return nil }
        return value.uppercased()
    }

    private static func fetch(
        base: String,
        quote: String,
        transport: Transport,
        now: Date
    ) throws -> RateRow {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "base", value: base),
            URLQueryItem(name: "quotes", value: quote),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 3.2
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, statusCode) = try transport(request)
        guard (200..<300).contains(statusCode) else { throw CurrencyError.httpStatus(statusCode) }
        let rows: [RateRow]
        do {
            rows = try JSONDecoder().decode([RateRow].self, from: data)
        } catch {
            throw CurrencyError.malformedResponse
        }
        guard let row = rows.first(where: {
            $0.base.uppercased() == base && $0.quote.uppercased() == quote
        }),
        Self.validSourceDate(row.date, now: now),
        Self.validRate(row.rate) else {
            throw CurrencyError.mismatchedResponse
        }
        return RateRow(date: row.date, base: base, quote: quote, rate: row.rate)
    }

    /// Frankfurter's source date is a UTC calendar date. Keep the check
    /// deliberately strict: only zero-padded Gregorian `YYYY-MM-DD` values
    /// that are not later than today are trusted, whether they came from the
    /// network or from the local cache.
    private static func validSourceDate(_ value: String, now: Date) -> Bool {
        guard value.utf8.count == 10 else { return false }
        let bytes = Array(value.utf8)
        guard bytes[4] == 45, bytes[7] == 45,
              bytes[0...3].allSatisfy({ $0 >= 48 && $0 <= 57 }),
              bytes[5...6].allSatisfy({ $0 >= 48 && $0 <= 57 }),
              bytes[8...9].allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
            return false
        }

        let year = bytes[0...3].reduce(into: 0) { $0 = ($0 * 10) + Int($1 - 48) }
        let month = bytes[5...6].reduce(into: 0) { $0 = ($0 * 10) + Int($1 - 48) }
        let day = bytes[8...9].reduce(into: 0) { $0 = ($0 * 10) + Int($1 - 48) }
        guard year >= 1, month >= 1, day >= 1 else { return false }

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return false
        }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard components.year == year, components.month == month, components.day == day else {
            return false
        }

        return date <= calendar.startOfDay(for: now)
    }

    private static func validRate(_ rate: Decimal) -> Bool {
        rate > 0 && rate.isFinite
    }

    private static func cacheKey(base: String, quote: String) -> String {
        "\(base)/\(quote)"
    }

    private static func readCache(at url: URL) -> [String: CachedRate]? {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder.iso8601.decode(CacheFile.self, from: data),
              file.version == 1 else { return nil }
        return file.rates
    }

    private static func writeCache(_ entry: CachedRate, key: String, at url: URL) {
        var rates = readCache(at: url) ?? [:]
        rates[key] = entry
        let file = CacheFile(version: 1, rates: rates)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.iso8601.encode(file)
            try data.write(to: url, options: [.atomic])
        } catch {
            // A fresh network result remains useful even if the optional cache
            // cannot be written (for example, a read-only test directory).
        }
    }

    private static func result(for request: Request, rate: Decimal, date: String, state: CacheState) -> CalculationResult {
        var converted = Decimal()
        var amount = request.amount
        var multiplier = rate
        let multiplicationError = NSDecimalMultiply(&converted, &amount, &multiplier, .plain)
        guard multiplicationError == .noError, converted.isFinite else {
            return Self.failure(for: request, detail: "conversion result out of range")
        }
        let amountText = format(request.amount)
        let convertedText = format(converted)
        let stateText: String
        switch state {
        case .fresh: stateText = "fetched now"
        case .cached: stateText = "cached"
        case .staleOffline: stateText = "stale/offline cache"
        }
        return CalculationResult(
            value: "\(convertedText) \(request.quote)",
            detail: "\(amountText) \(request.base) → \(convertedText) \(request.quote) · Frankfurter reference \(date) · \(stateText)",
            isError: false
        )
    }

    private static func failure(for request: Request, detail: String) -> CalculationResult {
        CalculationResult(
            value: "Error",
            detail: "\(request.base)/\(request.quote): \(detail)",
            isError: true
        )
    }

    private static func format(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: value))
            ?? NSDecimalNumber(decimal: value).stringValue
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension Decimal {
    var isFinite: Bool {
        NSDecimalNumber(decimal: self).doubleValue.isFinite
    }
}
