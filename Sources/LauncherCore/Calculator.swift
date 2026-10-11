import Foundation

public struct CalculationResult: Codable, Equatable, Sendable {
    public let value: String
    public let detail: String
    public let isError: Bool

    public init(value: String, detail: String, isError: Bool) {
        self.value = value
        self.detail = detail
        self.isError = isError
    }
}

public enum Calculator {
    public static func evaluate(_ input: String) -> CalculationResult? {
        let expression = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty else { return nil }

        if let conversion = Conversion.parse(expression) {
            return conversion.evaluate()
        }
        if Conversion.looksLikeConversion(expression) { return nil }
        guard !looksLikeDate(expression),
              Arithmetic.looksLikeExpression(expression) else { return nil }

        do {
            var arithmetic = try Arithmetic(expression)
            let number = try arithmetic.evaluate()
            let rendered = format(number)
            return CalculationResult(value: rendered, detail: "\(expression) = \(rendered)", isError: false)
        } catch let error as CalculationError {
            return failure(error.message)
        } catch {
            return failure("Malformed expression")
        }
    }

    // "2026-10-04" or "04-10-2026" is a date, not subtraction.
    private static let date = try! NSRegularExpression(
        pattern: #"^(\d{4}-\d{1,2}-\d{1,2}|\d{1,2}-\d{1,2}-\d{4})$"#
    )

    private static func looksLikeDate(_ input: String) -> Bool {
        date.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) != nil
    }

    private static func failure(_ detail: String) -> CalculationResult {
        CalculationResult(value: "Error", detail: detail, isError: true)
    }

    fileprivate static func format(_ value: Double) -> String {
        let normalized = abs(value) < 5e-15 ? 0 : value
        return String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), normalized)
    }
}

private enum CalculationError: Error {
    case malformed
    case divisionByZero
    case overflow
    case unknownUnit(String)
    case incompatibleUnits
    case belowAbsoluteZero

    var message: String {
        switch self {
        case .malformed: return "Malformed expression"
        case .divisionByZero: return "Division by zero"
        case .overflow: return "Result is outside the supported numeric range"
        case .unknownUnit(let unit): return "Unknown unit: \(unit)"
        case .incompatibleUnits: return "Those units measure different things"
        case .belowAbsoluteZero: return "Temperature cannot be below absolute zero"
        }
    }
}

private struct Arithmetic {
    private enum Token: Equatable {
        case number(Double)
        case plus, minus, multiply, divide, power, percent, leftParen, rightParen, end
    }

    private let source: String
    private var tokens: [Token] = []
    private var position = 0
    private var nesting = 0

    init(_ source: String) throws {
        self.source = source
        self.tokens = try Self.tokenize(source)
    }

    static func looksLikeExpression(_ source: String) -> Bool {
        guard source.contains(where: { $0.isNumber }) else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789.eE+-*/^%() ×÷\t\n\r")
        if source.unicodeScalars.allSatisfy({ allowed.contains($0) }) { return true }
        guard let first = source.first,
              first.isNumber || ".+-(".contains(first) else { return false }
        return source.contains(where: { "+-*/^%×÷".contains($0) })
    }

    mutating func evaluate() throws -> Double {
        let value = try parseAddition()
        guard current == .end else { throw CalculationError.malformed }
        return try Self.checked(value)
    }

    private mutating func parseAddition() throws -> Double {
        var value = try parseMultiplication()
        while true {
            if consume(.plus) {
                value = try Self.checked(value + parseMultiplication())
            } else if consume(.minus) {
                value = try Self.checked(value - parseMultiplication())
            } else {
                return value
            }
        }
    }

    private mutating func parseMultiplication() throws -> Double {
        var value = try parseUnary()
        while true {
            if consume(.multiply) {
                value = try Self.checked(value * parseUnary())
            } else if consume(.divide) {
                let divisor = try parseUnary()
                guard divisor != 0 else { throw CalculationError.divisionByZero }
                value = try Self.checked(value / divisor)
            } else {
                return value
            }
        }
    }

    private mutating func parseUnary() throws -> Double {
        if consume(.plus) { return try parseUnary() }
        if consume(.minus) { return try Self.checked(-(parseUnary())) }
        return try parsePower()
    }

    private mutating func parsePower() throws -> Double {
        let base = try parsePostfix()
        guard consume(.power) else { return base }
        let exponent = try parseUnary()
        if base == 0 && exponent < 0 { throw CalculationError.divisionByZero }
        return try Self.checked(pow(base, exponent))
    }

    private mutating func parsePostfix() throws -> Double {
        var value = try parsePrimary()
        while consume(.percent) {
            value = try Self.checked(value / 100)
        }
        return value
    }

    private mutating func parsePrimary() throws -> Double {
        if case .number(let value) = current {
            advance()
            return value
        }
        if consume(.leftParen) {
            nesting += 1
            guard nesting <= 64 else { throw CalculationError.malformed }
            let value = try parseAddition()
            guard consume(.rightParen) else { throw CalculationError.malformed }
            nesting -= 1
            return value
        }
        throw CalculationError.malformed
    }

    private var current: Token { tokens[position] }

    private mutating func consume(_ token: Token) -> Bool {
        guard current == token else { return false }
        advance()
        return true
    }

    private mutating func advance() {
        if position < tokens.count - 1 { position += 1 }
    }

    private static func checked(_ value: Double) throws -> Double {
        guard value.isFinite else { throw CalculationError.overflow }
        return value
    }

    private static func tokenize(_ source: String) throws -> [Token] {
        guard source.count <= 1024 else { throw CalculationError.malformed }
        let characters = Array(source)
        var result: [Token] = []
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace { index += 1; continue }
            if character.isNumber || character == "." {
                let start = index
                var digits = 0
                while index < characters.count, characters[index].isNumber { index += 1; digits += 1 }
                if index < characters.count, characters[index] == "." {
                    index += 1
                    while index < characters.count, characters[index].isNumber { index += 1; digits += 1 }
                }
                guard digits > 0 else { throw CalculationError.malformed }
                if index < characters.count, characters[index] == "e" || characters[index] == "E" {
                    index += 1
                    if index < characters.count, characters[index] == "+" || characters[index] == "-" { index += 1 }
                    let exponentStart = index
                    while index < characters.count, characters[index].isNumber { index += 1 }
                    guard exponentStart < index else { throw CalculationError.malformed }
                }
                guard let value = Double(String(characters[start..<index])), value.isFinite else {
                    throw CalculationError.overflow
                }
                result.append(.number(value))
            } else {
                switch character {
                case "+": result.append(.plus)
                case "-": result.append(.minus)
                case "*":
                    if index + 1 < characters.count, characters[index + 1] == "*" {
                        result.append(.power); index += 1
                    } else { result.append(.multiply) }
                case "×": result.append(.multiply)
                case "/", "÷": result.append(.divide)
                case "^": result.append(.power)
                case "%": result.append(.percent)
                case "(": result.append(.leftParen)
                case ")": result.append(.rightParen)
                default: throw CalculationError.malformed
                }
                index += 1
            }
            guard result.count <= 512 else { throw CalculationError.malformed }
        }
        result.append(.end)
        return result
    }
}

private struct Conversion {
    private enum Dimension { case length, mass, temperature, time, data }

    private struct UnitDefinition {
        let dimension: Dimension
        let symbol: String
        let scale: Double
        let offset: Double
    }

    private let amount: Double
    private let sourceText: String
    private let targetText: String
    private let source: UnitDefinition?
    private let target: UnitDefinition?

    private static let expression = try! NSRegularExpression(
        pattern: #"^\s*([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)\s*([A-Za-z°]+)\s+(?:in|to)\s+([A-Za-z°]+)\s*$"#,
        options: [.caseInsensitive]
    )
    private static let conversionHint = try! NSRegularExpression(
        pattern: #"^\s*[+-]?(?:\d|\.\d).+\s+(?:in|to)\s+.+$"#,
        options: [.caseInsensitive]
    )

    static func parse(_ input: String) -> Conversion? {
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        guard let match = expression.firstMatch(in: input, range: range),
              let amountRange = Range(match.range(at: 1), in: input),
              let sourceRange = Range(match.range(at: 2), in: input),
              let targetRange = Range(match.range(at: 3), in: input),
              let amount = Double(input[amountRange]),
              amount.isFinite else { return nil }
        let sourceText = String(input[sourceRange])
        let targetText = String(input[targetRange])
        let source = units[normalize(sourceText)]
        let target = units[normalize(targetText)]
        guard source != nil || target != nil else { return nil }
        return Conversion(amount: amount, sourceText: sourceText, targetText: targetText, source: source, target: target)
    }

    static func looksLikeConversion(_ input: String) -> Bool {
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return conversionHint.firstMatch(in: input, range: range) != nil
    }

    func evaluate() -> CalculationResult {
        do {
            guard let source else { throw CalculationError.unknownUnit(sourceText) }
            guard let target else { throw CalculationError.unknownUnit(targetText) }
            guard source.dimension == target.dimension else { throw CalculationError.incompatibleUnits }
            let base = try checked(amount * source.scale + source.offset)
            if source.dimension == .temperature && base < -273.15 - 1e-10 {
                throw CalculationError.belowAbsoluteZero
            }
            let converted = try checked((base - target.offset) / target.scale)
            let rendered = Calculator.format(converted)
            return CalculationResult(
                value: "\(rendered) \(target.symbol)",
                detail: "\(Calculator.format(amount)) \(source.symbol) → \(rendered) \(target.symbol)",
                isError: false
            )
        } catch let error as CalculationError {
            return CalculationResult(value: "Error", detail: error.message, isError: true)
        } catch {
            return CalculationResult(value: "Error", detail: "Conversion failed", isError: true)
        }
    }

    private func checked(_ value: Double) throws -> Double {
        guard value.isFinite else { throw CalculationError.overflow }
        return value
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private static let units: [String: UnitDefinition] = {
        var result: [String: UnitDefinition] = [:]
        func add(_ aliases: [String], _ dimension: Dimension, _ symbol: String, _ scale: Double, _ offset: Double = 0) {
            let unit = UnitDefinition(dimension: dimension, symbol: symbol, scale: scale, offset: offset)
            for alias in aliases { result[normalize(alias)] = unit }
        }

        add(["m", "meter", "meters", "metre", "metres"], .length, "m", 1)
        add(["km", "kilometer", "kilometers", "kilometre", "kilometres"], .length, "km", 1_000)
        add(["cm", "centimeter", "centimeters", "centimetre", "centimetres"], .length, "cm", 0.01)
        add(["mm", "millimeter", "millimeters", "millimetre", "millimetres"], .length, "mm", 0.001)
        add(["in", "inch", "inches"], .length, "in", 0.0254)
        add(["ft", "foot", "feet"], .length, "ft", 0.3048)
        add(["yd", "yard", "yards"], .length, "yd", 0.9144)
        add(["mi", "mile", "miles"], .length, "mi", 1_609.344)

        add(["kg", "kilogram", "kilograms"], .mass, "kg", 1)
        add(["g", "gram", "grams"], .mass, "g", 0.001)
        add(["mg", "milligram", "milligrams"], .mass, "mg", 0.000_001)
        add(["lb", "lbs", "pound", "pounds"], .mass, "lb", 0.453_592_37)
        add(["oz", "ounce", "ounces"], .mass, "oz", 0.028_349_523_125)
        add(["t", "tonne", "tonnes"], .mass, "t", 1_000)

        add(["c", "°c", "celsius"], .temperature, "°C", 1)
        add(["f", "°f", "fahrenheit"], .temperature, "°F", 5.0 / 9.0, -160.0 / 9.0)
        add(["k", "kelvin"], .temperature, "K", 1, -273.15)

        add(["s", "sec", "secs", "second", "seconds"], .time, "s", 1)
        add(["min", "mins", "minute", "minutes"], .time, "min", 60)
        add(["h", "hr", "hrs", "hour", "hours"], .time, "h", 3_600)
        add(["d", "day", "days"], .time, "d", 86_400)
        add(["wk", "wks", "week", "weeks"], .time, "wk", 604_800)

        add(["b", "byte", "bytes"], .data, "B", 1)
        add(["kb", "kilobyte", "kilobytes"], .data, "KB", 1_000)
        add(["mb", "megabyte", "megabytes"], .data, "MB", 1_000_000)
        add(["gb", "gigabyte", "gigabytes"], .data, "GB", 1_000_000_000)
        add(["tb", "terabyte", "terabytes"], .data, "TB", 1_000_000_000_000)
        add(["kib", "kibibyte", "kibibytes"], .data, "KiB", 1_024)
        add(["mib", "mebibyte", "mebibytes"], .data, "MiB", 1_048_576)
        add(["gib", "gibibyte", "gibibytes"], .data, "GiB", 1_073_741_824)
        return result
    }()
}
