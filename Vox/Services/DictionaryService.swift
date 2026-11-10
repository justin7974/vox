import Foundation

/// The on-disk array remains authoritative. Unknown array entries are retained when
/// editing known string terms, and malformed files are never replaced by an empty list.
final class DictionaryService {
    static let shared = DictionaryService()
    private let directory: URL
    private let lock = NSRecursiveLock()
    private var storedLastError: String?
    private(set) var lastError: String? {
        get { lock.lock(); defer { lock.unlock() }; return storedLastError }
        set { lock.lock(); defer { lock.unlock() }; storedLastError = newValue }
    }
    var dictPath: String { directory.appendingPathComponent("dictionary.json").path }

    private static let seedContent = ["Claude", "红杉", "Sequoia", "MiniMax", "Term Sheet", "Cap Table", "LLM", "ARR", "MRR"]
    private convenience init() { self.init(directory: NSHomeDirectory() + "/.vox") }
    init(directory: String, seedIfMissing: Bool = true) {
        self.directory = URL(fileURLWithPath: directory)
        if seedIfMissing && !FileManager.default.fileExists(atPath: dictPath) {
            do {
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                try JSONBackupStore.atomicWrite(JSONSerialization.data(withJSONObject: Self.seedContent, options: [.prettyPrinted]), to: URL(fileURLWithPath: dictPath))
            } catch { lastError = "Could not create dictionary.json." }
        }
    }

    private func readDocument() throws -> (Data, [Any]) {
        let data = try Data(contentsOf: URL(fileURLWithPath: dictPath))
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [Any] else { throw CocoaError(.fileReadCorruptFile) }
        return (data, rows)
    }

    /// Throwing read lets unattended updates distinguish an empty dictionary from corruption.
    func readTerms() throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        return try readDocument().1.compactMap { $0 as? String }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    var terms: [String] {
        do { return try readTerms() }
        catch { lastError = "dictionary.json is unreadable or malformed; its bytes were preserved."; return [] }
    }
    var formatted: String { terms.joined(separator: ", ") }

    private func mutate(_ transform: (inout [Any]) -> Bool) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let (original, document) = try readDocument()
        var rows = document
        guard transform(&rows) else { return false }
        let url = URL(fileURLWithPath: dictPath)
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        guard try Data(contentsOf: url) == original else { throw CocoaError(.fileWriteUnknown) }
        try JSONBackupStore.backup(original, directory: directory, prefix: "dictionary-backup-")
        guard try Data(contentsOf: url) == original else { throw CocoaError(.fileWriteUnknown) }
        try JSONBackupStore.atomicWrite(data, to: url)
        lastError = nil
        return true
    }

    @discardableResult func addTermsSafely(_ incoming: [String]) throws -> [String] {
        var added: [String] = []
        _ = try mutate { rows in
            var existing = rows.compactMap { $0 as? String }
            for raw in incoming {
                let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !term.isEmpty, !existing.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else { continue }
                existing.append(term); rows.append(term); added.append(term)
            }
            return !added.isEmpty
        }
        return added
    }
    @discardableResult func addTerm(_ term: String) -> Bool { addTerms([term]) == 1 }
    @discardableResult func addTerms(_ incoming: [String]) -> Int {
        do { return try addTermsSafely(incoming).count }
        catch { lastError = "Cannot save dictionary.json. Check its JSON and permissions; existing bytes were preserved."; return 0 }
    }
    func removeTerm(at index: Int) {
        do {
            _ = try mutate { rows in
                let indices = rows.indices.filter { index in (rows[index] as? String).map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false }
                guard indices.indices.contains(index) else { return false }
                rows.remove(at: indices[index]); return true
            }
        } catch { lastError = "Cannot save dictionary.json; existing bytes were preserved." }
    }
    @discardableResult func updateTerm(at index: Int, to newValue: String) -> Bool {
        do {
            return try mutate { rows in
                let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let indices = rows.indices.filter { index in (rows[index] as? String).map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false }
                guard !value.isEmpty, indices.indices.contains(index), !indices.enumerated().contains(where: { $0.offset != index && (rows[$0.element] as! String).caseInsensitiveCompare(value) == .orderedSame }) else { return false }
                rows[indices[index]] = value; return true
            }
        } catch { lastError = "Cannot save dictionary.json; existing bytes were preserved."; return false }
    }
}
