import Foundation

/// Finds personal data and secrets in recognized text, so they can be covered before a screenshot is shared.
public enum SensitiveText {
    public enum Kind: String, CaseIterable {
        case phone = "手机号", email = "邮箱", idCard = "身份证号", bankCard = "银行卡号", secret = "密钥"
    }

    public struct Match: Equatable {
        public var kind: Kind
        public var range: Range<String.Index>
    }

    private static let sources: [(Kind, String)] = [
        (.email, #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#),
        (.secret, #"\b(?:sk|pk|rk|ghp|gho|ghs|xox[abpr])[-_][A-Za-z0-9_-]{16,}\b|\bAKIA[0-9A-Z]{16}\b"#),
        (.idCard, #"(?<![0-9])[1-9][0-9]{5}(?:19|20)[0-9]{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12][0-9]|3[01])[0-9]{3}[0-9Xx](?![0-9])"#),
        (.bankCard, #"(?<![0-9])(?:[0-9][ -]?){15,18}[0-9](?![0-9])"#),
        (.phone, #"(?<![0-9])(?:\+?86[- ]?)?1[3-9][0-9](?:[- ]?[0-9]{4}){2}(?![0-9])|(?<![0-9A-Za-z])\+[1-9][0-9]{0,2}[- ]?\(?[0-9]{2,4}\)?[- ]?[0-9]{3,4}[- ]?[0-9]{3,4}(?![0-9])"#),
    ]
    private static let patterns = sources.map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    /// Non-overlapping matches, earlier kinds in `patterns` winning (an ID number is not also a bank card).
    public static func matches(in text: String) -> [Match] {
        var found: [Match] = []
        let whole = NSRange(text.startIndex..., in: text)
        for (kind, regex) in patterns {
            for result in regex.matches(in: text, range: whole) {
                guard let range = Range(result.range, in: text) else { continue }
                if kind == .bankCard, !luhn(text[range]) { continue }
                if found.contains(where: { $0.range.overlaps(range) }) { continue }
                found.append(Match(kind: kind, range: range))
            }
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Card numbers carry a Luhn check digit; this keeps order numbers and timestamps from being taken for cards.
    static func luhn(_ s: Substring) -> Bool {
        let digits = s.compactMap { $0.wholeNumberValue }
        guard digits.count >= 16 else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += d
            }
        }
        return sum % 10 == 0
    }
}
