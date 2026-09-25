import Foundation

/// File names like `Snap {yyyy-MM-dd HH.mm.ss}` or `{app}_{yyyyMMdd}`: `{app}` is the app that was in front,
/// anything else in braces is a date pattern. Characters Finder can't take in a name are replaced.
public enum FileNameTemplate {
    public static let `default` = "Snap {yyyy-MM-dd HH.mm.ss}"

    public static func expand(_ template: String, date: Date, appName: String?, timeZone: TimeZone = .current) -> String {
        var result = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else {
                result += rest[open...]
                rest = ""
                break
            }
            let token = String(rest[rest.index(after: open)..<close])
            if token.lowercased() == "app" {
                result += appName ?? "Snap"
            } else if !token.isEmpty {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = timeZone
                formatter.dateFormat = token
                result += formatter.string(from: date)
            }
            rest = rest[rest.index(after: close)...]
        }
        result += rest
        let cleaned = result
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "Snap" : cleaned
    }
}
