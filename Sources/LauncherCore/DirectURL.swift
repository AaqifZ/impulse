import Foundation

enum DirectURL {
    static let actionID = "runtime.open-url"

    /// A typed web address. `browser` is a bundle ID, or nil for the default browser.
    static func action(for input: String, browser: String? = nil) -> LauncherAction? {
        guard !input.isEmpty,
              input == input.trimmingCharacters(in: .whitespacesAndNewlines),
              !input.contains(where: { $0.isWhitespace }),
              !input.contains("\\") else { return nil }

        let isExplicit = input.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) != nil
        let candidate: String
        if isExplicit {
            guard input.lowercased().hasPrefix("https://") || input.lowercased().hasPrefix("http://") else { return nil }
            candidate = input
        } else {
            guard !input.contains("://"), !input.contains("@") else { return nil }
            candidate = "https://\(input)"
        }

        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased(),
              validDomain(host) else { return nil }
        if !isExplicit && components.port != nil { return nil }

        components.scheme = scheme
        components.host = host
        guard let normalized = components.url?.absoluteString else { return nil }
        return LauncherAction(
            id: actionID,
            name: "Open \(host)",
            aliases: [input],
            kind: .url,
            target: normalized,
            browser: browser
        )
    }

    private static func validDomain(_ host: String) -> Bool {
        guard host.count <= 253,
              host.contains("."),
              host.allSatisfy({ $0.isASCII }) else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for label in labels {
            guard !label.isEmpty,
                  label.count <= 63,
                  label.first != "-",
                  label.last != "-",
                  label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return false }
        }
        guard let topLevel = labels.last else { return false }
        return topLevel.count >= 2 && (
            topLevel.allSatisfy({ $0.isASCII && $0.isLetter }) ||
            (topLevel.hasPrefix("xn--") && topLevel.count > 4)
        )
    }
}
