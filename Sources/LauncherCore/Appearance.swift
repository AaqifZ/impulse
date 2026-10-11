import Foundation

/// Persisted look choice. Unknown or unreadable values fall back to Signal + volt.
public struct AppearanceSettings: Codable, Equatable, Sendable {
    public static let themes = ["signal", "glass", "raycast"]
    public static let accents = ["volt", "cyan", "orange", "violet"]
    public static let standard = AppearanceSettings(theme: "signal", accent: "volt")

    public var theme: String
    public var accent: String

    public init(theme: String, accent: String) {
        self.theme = Self.themes.contains(theme) ? theme : Self.standard.theme
        self.accent = Self.accents.contains(accent) ? accent : Self.standard.accent
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            theme: (try? values.decode(String.self, forKey: .theme)) ?? Self.standard.theme,
            accent: (try? values.decode(String.self, forKey: .accent)) ?? Self.standard.accent
        )
    }

    public static func load(from url: URL) -> AppearanceSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(AppearanceSettings.self, from: data) else { return standard }
        return settings
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: [.atomic])
    }
}

/// Presentation-only text shaping. Execution keeps the full-precision values.
public enum DisplayFormat {
    /// Rounds the first number in `text`: two decimals at or above 1, else four significant digits.
    public static func rounded(_ text: String, fractionDigits: Int = 2) -> String {
        var parts = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard let index = parts.firstIndex(where: { Double($0) != nil }),
              let value = Double(parts[index]), value.isFinite,
              !parts[index].lowercased().contains("e") else { return text }
        parts[index] = format(value, fractionDigits: fractionDigits)
        return parts.joined(separator: " ")
    }

    /// Rounds every plain number in `text` (dates and words are left alone).
    public static func roundedAll(_ text: String, fractionDigits: Int = 4) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false).map { token -> String in
            let word = String(token)
            guard let value = Double(word), value.isFinite, !word.lowercased().contains("e") else { return word }
            return format(value, fractionDigits: fractionDigits)
        }.joined(separator: " ")
    }

    /// Splits "6.21 mi" into ("6.21", "mi"); a value with no unit gives an empty unit.
    public static func valueAndUnit(_ text: String) -> (value: String, unit: String) {
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, Double(parts[0]) != nil else { return (text, "") }
        return (parts[0], parts[1])
    }

    static func format(_ value: Double, fractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        if value != 0 && abs(value) < 1 {
            formatter.usesSignificantDigits = true
            formatter.maximumSignificantDigits = 4
        } else {
            formatter.maximumFractionDigits = fractionDigits
        }
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Drops a leading "<alias> - " so the alias is not shown twice ("gh - GitHub" → "GitHub").
    public static func cleanName(_ name: String, aliases: [String]) -> String {
        for alias in aliases {
            let prefix = alias + " - "
            if name.count > prefix.count, name.lowercased().hasPrefix(prefix.lowercased()) {
                return String(name.dropFirst(prefix.count))
            }
        }
        return name
    }

    /// Short name for a query-mode chip ("YouTube Search" → "YouTube").
    public static func modeName(_ name: String, aliases: [String]) -> String {
        let clean = cleanName(name, aliases: aliases)
        for suffix in [" Search", " search"] where clean.hasSuffix(suffix) && clean.count > suffix.count {
            return String(clean.dropLast(suffix.count))
        }
        return clean
    }
}
