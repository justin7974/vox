import Foundation

/// Shared by manual and unattended dictionary scans. Only a single enclosing
/// JSON/unlabelled Markdown fence is stripped; prose or malformed JSON still fails.
enum JSONResponseParser {
    static func data(from raw: String) throws -> Data {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return Data(trimmed.utf8) }
        var lines = trimmed.components(separatedBy: .newlines)
        guard lines.count >= 3,
              ["```", "```json"].contains(lines[0].trimmingCharacters(in: .whitespaces).lowercased()),
              lines.last?.trimmingCharacters(in: .whitespaces) == "```" else {
            throw CocoaError(.fileReadCorruptFile)
        }
        lines.removeFirst(); lines.removeLast()
        return Data(lines.joined(separator: "\n").utf8)
    }

    static func decode<T: Decodable>(_ type: T.Type, from raw: String) throws -> T {
        try JSONDecoder().decode(type, from: data(from: raw))
    }
}
