import Foundation

/// Loads user-defined proper-noun vocabulary from ~/.vox/dictionary.json.
/// File format: JSON array of strings, e.g. ["Claude", "红杉", "MiniMax"].
/// Injected into Qwen ASR system context (layer 1) and LLM system prompt (layer 2)
/// to reduce recognition errors on high-frequency proper nouns.
final class DictionaryService {
    static let shared = DictionaryService()

    private let log = LogService.shared
    private let dictDir = NSHomeDirectory() + "/.vox"
    var dictPath: String { dictDir + "/dictionary.json" }

    private static let seedContent = """
    [
      "Claude",
      "红杉",
      "Sequoia",
      "MiniMax",
      "Term Sheet",
      "Cap Table",
      "LLM",
      "ARR",
      "MRR"
    ]
    """

    private init() {
        ensureFileExists()
    }

    /// Reads the dictionary file fresh every call — cheap (<1KB) and keeps manual edits
    /// taking effect without needing a reload trigger.
    var terms: [String] {
        guard let data = FileManager.default.contents(atPath: dictPath),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return arr
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Comma-joined string ready to append to a prompt. Empty when no terms.
    var formatted: String {
        terms.joined(separator: ", ")
    }

    /// Seed an example file on first run so users have something to edit.
    private func ensureFileExists() {
        if FileManager.default.fileExists(atPath: dictPath) { return }
        try? FileManager.default.createDirectory(atPath: dictDir, withIntermediateDirectories: true)
        try? DictionaryService.seedContent.write(toFile: dictPath, atomically: true, encoding: .utf8)
        log.debug("Seeded dictionary.json at \(dictPath)")
    }
}
