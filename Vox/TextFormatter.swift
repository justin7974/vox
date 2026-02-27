import Foundation

enum TextFormatter {
    static func format(_ text: String) -> String {
        var result = text
        result = addCJKSpacing(result)
        result = normalizePunctuation(result)
        result = normalizeWhitespace(result)
        return result
    }

    // MARK: - Pangu Spacing (中英文之间加空格)

    private static func addCJKSpacing(_ text: String) -> String {
        var result = text

        // CJK followed by ASCII letter/digit → insert space
        // CJK range: \u4e00-\u9fff (common), \u3400-\u4dbf (ext A), \uf900-\ufaff (compat)
        let cjkBeforeASCII = try! NSRegularExpression(
            pattern: "([\\u4e00-\\u9fff\\u3400-\\u4dbf\\uf900-\\ufaff])([A-Za-z0-9])"
        )
        result = cjkBeforeASCII.stringByReplacingMatches(
            in: result, range: NSRange(result.startIndex..., in: result),
            withTemplate: "$1 $2"
        )

        // ASCII letter/digit followed by CJK → insert space
        let asciiBeforeCJK = try! NSRegularExpression(
            pattern: "([A-Za-z0-9])([\\u4e00-\\u9fff\\u3400-\\u4dbf\\uf900-\\ufaff])"
        )
        result = asciiBeforeCJK.stringByReplacingMatches(
            in: result, range: NSRange(result.startIndex..., in: result),
            withTemplate: "$1 $2"
        )

        return result
    }

    // MARK: - Punctuation Normalization

    private static func normalizePunctuation(_ text: String) -> String {
        var result = text

        // In CJK context, use fullwidth punctuation
        let replacements: [(String, String)] = [
            // Only fix common mismatches: halfwidth punct in Chinese context
            ("(?<=[\\u4e00-\\u9fff]),(?=[\\u4e00-\\u9fff])", "\u{ff0c}"),   // , → ，
            ("(?<=[\\u4e00-\\u9fff])\\.(?=[\\u4e00-\\u9fff])", "\u{3002}"), // . → 。
            ("(?<=[\\u4e00-\\u9fff])!(?=[\\u4e00-\\u9fff\\s])", "\u{ff01}"), // ! → ！
            ("(?<=[\\u4e00-\\u9fff])\\?(?=[\\u4e00-\\u9fff\\s])", "\u{ff1f}"), // ? → ？
            ("(?<=[\\u4e00-\\u9fff]):(?=[\\u4e00-\\u9fff])", "\u{ff1a}"),   // : → ：
            ("(?<=[\\u4e00-\\u9fff]);(?=[\\u4e00-\\u9fff])", "\u{ff1b}"),   // ; → ；
        ]

        for (pattern, replacement) in replacements {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                result = regex.stringByReplacingMatches(
                    in: result, range: NSRange(result.startIndex..., in: result),
                    withTemplate: replacement
                )
            }
        }

        return result
    }

    // MARK: - Whitespace Cleanup

    private static func normalizeWhitespace(_ text: String) -> String {
        var result = text

        // Collapse multiple spaces into one
        if let regex = try? NSRegularExpression(pattern: " {2,}") {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: " "
            )
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
