import Foundation

/// Reads a color value typed or copied as text, the way Snipaste recognises colors on the clipboard.
public enum ColorText {
    public struct RGB: Equatable {
        public var red: Double, green: Double, blue: Double
        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        public var hex: String {
            String(format: "#%02X%02X%02X", Self.byte(red), Self.byte(green), Self.byte(blue))
        }

        public var bytes: (Int, Int, Int) { (Self.byte(red), Self.byte(green), Self.byte(blue)) }

        private static func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
    }

    /// Accepts `#RGB`, `#RRGGBB`, `#RRGGBBAA` (alpha ignored), `rgb(r, g, b)` / `rgba(…)`,
    /// three integers 0–255, or three decimals 0–1. The whole text must be the color.
    public static func parse(_ text: String) -> RGB? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 40 else { return nil }
        if s.hasPrefix("#") { return parseHex(String(s.dropFirst())) }

        var body = s.lowercased()
        for prefix in ["rgba(", "rgb("] where body.hasPrefix(prefix) {
            guard body.hasSuffix(")") else { return nil }
            body = String(body.dropFirst(prefix.count).dropLast())
            break
        }
        let parts = body.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" || $0 == "/" }).map(String.init)
        guard parts.count == 3 || (parts.count == 4 && s.lowercased().hasPrefix("rgba(")) else { return nil }
        let rgb = parts.prefix(3)
        let values = rgb.compactMap(Double.init)
        guard values.count == 3 else { return nil }
        if rgb.allSatisfy({ !$0.contains(".") }) {
            guard values.allSatisfy({ (0...255).contains($0) }) else { return nil }
            return RGB(red: values[0] / 255, green: values[1] / 255, blue: values[2] / 255)
        }
        guard values.allSatisfy({ (0...1).contains($0) }) else { return nil }
        return RGB(red: values[0], green: values[1], blue: values[2])
    }

    private static func parseHex(_ hex: String) -> RGB? {
        guard hex.allSatisfy(\.isHexDigit) else { return nil }
        let digits: String
        switch hex.count {
        case 3: digits = hex.map { "\($0)\($0)" }.joined()
        case 6: digits = hex
        case 8: digits = String(hex.prefix(6))
        default: return nil
        }
        guard let value = UInt32(digits, radix: 16) else { return nil }
        return RGB(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

public enum CodeText {
    /// Whether pasted text reads like source code, JSON or a log, so it should be shown in a monospaced font.
    public static func looksLikeCode(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return false }
        let first = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if first.hasPrefix("{") || first.hasPrefix("[") || first.hasPrefix("<") || first.hasPrefix("$ ") { return true }
        var signals = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("    ") || line.hasPrefix("\t") { signals += 1 }
            if let last = trimmed.last, ";{}):".contains(last) { signals += 1 }
            if ["func ", "def ", "class ", "import ", "let ", "var ", "const ", "return ", "if (", "for (", "#include", "//", "# "]
                .contains(where: { trimmed.hasPrefix($0) }) { signals += 1 }
        }
        return Double(signals) / Double(lines.count) >= 0.5
    }
}
