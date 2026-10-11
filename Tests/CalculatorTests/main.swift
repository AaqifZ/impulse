import Foundation
import LauncherCore

private struct TestFailure: Error, CustomStringConvertible { let description: String }

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw TestFailure(description: message) }
}

private func success(_ input: String) throws -> CalculationResult {
    guard let result = Calculator.evaluate(input) else { throw TestFailure(description: "nil result for \(input)") }
    try expect(!result.isError, "unexpected error for \(input): \(result.detail)")
    return result
}

private func expectValue(_ input: String, _ expected: String) throws {
    let result = try success(input)
    try expect(result.value == expected, "\(input): expected \(expected), got \(result.value)")
}

private func expectError(_ input: String, contains message: String) throws {
    guard let result = Calculator.evaluate(input) else { throw TestFailure(description: "nil instead of error for \(input)") }
    try expect(result.isError, "expected error for \(input), got \(result.value)")
    try expect(result.detail.contains(message), "wrong error for \(input): \(result.detail)")
}

@main
struct CalculatorTestRunner {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("operator precedence", precedence),
            ("parentheses", parentheses),
            ("unary and right-associative power", unaryPower),
            ("postfix percent", percent),
            ("scientific notation", scientificNotation),
            ("division by zero", divisionByZero),
            ("malformed input", malformed),
            ("numeric overflow", overflow),
            ("ordinary text ignored", ordinaryText),
            ("length conversion", length),
            ("temperature conversion", temperature),
            ("mass conversion", mass),
            ("time conversion", time),
            ("data conversion", data),
            ("unit aliases", aliases),
            ("unit errors", unitErrors),
            ("copyable result details", resultShape),
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
        print("PASS \(tests.count) Calculator tests")
    }

    private static func precedence() throws {
        try expectValue("2 + 3 * 4", "14")
        try expectValue("20 / 5 + 7", "11")
        try expectValue("6 × 7 - 2", "40")
    }

    private static func parentheses() throws {
        try expectValue("(2 + 3) * 4", "20")
        try expectValue("2 * (3 + (4 - 1))", "12")
    }

    private static func unaryPower() throws {
        try expectValue("-2^2", "-4")
        try expectValue("2^-2", "0.25")
        try expectValue("2^3^2", "512")
        try expectValue("2**8", "256")
    }

    private static func percent() throws {
        try expectValue("50%", "0.5")
        try expectValue("200 * 5%", "10")
    }

    private static func scientificNotation() throws {
        try expectValue("1e3 + .5", "1000.5")
    }

    private static func divisionByZero() throws {
        try expectError("1 / 0", contains: "Division by zero")
        try expectError("0^-1", contains: "Division by zero")
    }

    private static func malformed() throws {
        try expectError("2 +", contains: "Malformed")
        try expectError("(2 + 3", contains: "Malformed")
        try expectError("2 + system(3)", contains: "Malformed")
    }

    private static func overflow() throws {
        try expectError("1e308 * 1e308", contains: "supported numeric range")
        try expectError("(-1)^0.5", contains: "supported numeric range")
    }

    private static func ordinaryText() throws {
        try expect(Calculator.evaluate("hello world") == nil, "ordinary words became a calculation")
        try expect(Calculator.evaluate("project 2026-09") == nil, "ordinary numbered text became a calculation")
        try expect(Calculator.evaluate("10 people in room") == nil, "ordinary phrase became a conversion")
        try expect(Calculator.evaluate("2026-10-04") == nil, "ISO date became a calculation")
        try expect(Calculator.evaluate("04-10-2026") == nil, "day-first date became a calculation")
        try expectValue("2026-10-4-1", "2011")
        try expectValue("2026 - 10 - 04", "2012")
    }

    private static func length() throws {
        try expectValue("10 km in miles", "6.21371192237 mi")
    }

    private static func temperature() throws {
        try expectValue("100 f to c", "37.7777777778 °C")
        try expectValue("0 c to f", "32 °F")
        try expectValue("273.15 k to c", "0 °C")
    }

    private static func mass() throws {
        try expectValue("1 kg to lb", "2.20462262185 lb")
    }

    private static func time() throws {
        try expectValue("2 hours to min", "120 min")
    }

    private static func data() throws {
        try expectValue("1 GiB to MB", "1073.741824 MB")
    }

    private static func aliases() throws {
        try expectValue("12 inches to cm", "30.48 cm")
        try expectValue("1 foot to in", "12 in")
    }

    private static func unitErrors() throws {
        try expectError("1 kg to km", contains: "different things")
        try expectError("1 blarg to kg", contains: "Unknown unit")
        try expectError("-500 c to f", contains: "absolute zero")
    }

    private static func resultShape() throws {
        let result = try success("60 min to hours")
        try expect(result.value == "1 h", "result is not directly copyable")
        try expect(result.detail == "60 min → 1 h", "detail does not describe the conversion")
    }
}
