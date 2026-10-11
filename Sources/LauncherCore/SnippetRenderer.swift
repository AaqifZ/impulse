import Foundation

enum SnippetRenderer {
    private static let dateExpression = try! NSRegularExpression(
        pattern: #"\{date\s+format="([^"]+)"\}"#
    )
    private static let dynamicPrefixExpression = try! NSRegularExpression(
        pattern: #"\{(?:date|time|cursor|clipboard|argument|selection)\b[^{}]*\}"#,
        options: [.caseInsensitive]
    )

    static func validate(_ template: String) throws {
        let cursorCount = template.components(separatedBy: "{cursor}").count - 1
        guard cursorCount <= 1 else {
            throw LauncherError.invalidSnippetTemplate("only one {cursor} placeholder is allowed")
        }

        let range = NSRange(template.startIndex..<template.endIndex, in: template)
        let supportedDates = Set(dateExpression.matches(in: template, range: range).map(\.range))
        for match in dynamicPrefixExpression.matches(in: template, range: range) {
            guard supportedDates.contains(match.range) ||
                    (Range(match.range, in: template).map { String(template[$0]) } == "{cursor}") else {
                let token = Range(match.range, in: template).map { String(template[$0]) } ?? "placeholder"
                throw LauncherError.invalidSnippetTemplate("unsupported or malformed placeholder \(token)")
            }
        }
    }

    static func render(
        _ template: String,
        now: Date,
        timeZone: TimeZone
    ) throws -> (value: String, cursorOffset: Int?) {
        try validate(template)
        var rendered = template
        let originalRange = NSRange(rendered.startIndex..<rendered.endIndex, in: rendered)
        let matches = dateExpression.matches(in: rendered, range: originalRange).reversed()
        for match in matches {
            guard let tokenRange = Range(match.range(at: 0), in: rendered),
                  let formatRange = Range(match.range(at: 1), in: rendered) else { continue }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = timeZone
            formatter.dateFormat = String(rendered[formatRange])
            rendered.replaceSubrange(tokenRange, with: formatter.string(from: now))
        }

        guard let cursorRange = rendered.range(of: "{cursor}") else {
            return (rendered, nil)
        }
        let offset = rendered.distance(from: rendered.startIndex, to: cursorRange.lowerBound)
        rendered.removeSubrange(cursorRange)
        return (rendered, offset)
    }
}
