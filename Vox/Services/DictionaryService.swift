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

    // MARK: - Mutations

    /// Returns true if the term was added; false if empty or already present (case-insensitive).
    @discardableResult
    func addTerm(_ term: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var current = terms
        if current.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return false
        }
        current.append(trimmed)
        writeTerms(current)
        return true
    }

    /// Add multiple terms at once; returns count actually added (after dedup).
    @discardableResult
    func addTerms(_ incoming: [String]) -> Int {
        var current = terms
        var added = 0
        for raw in incoming {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if current.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) { continue }
            current.append(t)
            added += 1
        }
        if added > 0 { writeTerms(current) }
        return added
    }

    func removeTerm(at index: Int) {
        var current = terms
        guard index >= 0 && index < current.count else { return }
        current.remove(at: index)
        writeTerms(current)
    }

    /// Updates the term at index; returns false on dedupe conflict or empty.
    @discardableResult
    func updateTerm(at index: Int, to newValue: String) -> Bool {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var current = terms
        guard !trimmed.isEmpty, index >= 0 && index < current.count else { return false }
        if current.enumerated().contains(where: { $0.offset != index && $0.element.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return false
        }
        current[index] = trimmed
        writeTerms(current)
        return true
    }

    private func writeTerms(_ list: [String]) {
        do {
            try FileManager.default.createDirectory(atPath: dictDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted])
            try data.write(to: URL(fileURLWithPath: dictPath), options: .atomic)
        } catch {
            log.debug("DictionaryService write failed: \(error.localizedDescription)")
        }
    }

    /// Seed an example file on first run so users have something to edit.
    private func ensureFileExists() {
        if FileManager.default.fileExists(atPath: dictPath) { return }
        try? FileManager.default.createDirectory(atPath: dictDir, withIntermediateDirectories: true)
        try? DictionaryService.seedContent.write(toFile: dictPath, atomically: true, encoding: .utf8)
        log.debug("Seeded dictionary.json at \(dictPath)")
    }
}
