import Foundation

/// Loads user-defined alias rules from ~/.vox/aliases.json and applies them
/// as a deterministic pre-LLM substitution pass.
///
/// File format: JSON array of objects, e.g.
///   [
///     { "from": "cloud code", "to": "Claude Code", "matchMode": "word", "caseSensitive": false }
///   ]
///
/// Designed to fix ASR homophone errors (e.g. "cloud code" → "Claude Code")
/// that smaller LLM post-processors can't infer. Runs BEFORE the LLM call so
/// the model sees the corrected text. Also applies as a fallback when the
/// LLM is unconfigured / fails (deterministic path doesn't depend on LLM).
///
/// Invariants (per @鹰眼 spec v2 review):
///   - Single-pass, NO chain: matches computed against ORIGINAL text only.
///     Aliases A→B and B→C with input containing A produce B (not C).
///   - Non-overlapping ranges: longer aliases win; ties resolved by file order.
///   - Only invoked from normal dictation path (not translate / edit / custom).
// Mutable error state is locked; document data is fresh, immutable per read.
final class AliasService: @unchecked Sendable {
    static let shared = AliasService()

    private let dictDir: String
    private let errorLock = NSLock()
    private var error: String?
    private(set) var lastError: String? {
        get { errorLock.lock(); defer { errorLock.unlock() }; return error }
        set { errorLock.lock(); defer { errorLock.unlock() }; error = newValue }
    }
    var aliasPath: String { dictDir + "/aliases.json" }

    /// Conservative default seed (per @鹰眼 review). Only phrase-level entries
    /// safe for general distribution. Single-word `cloud → Claude` is too broad
    /// for default; users who want it add it themselves.
    private static let seedContent = """
    [
      {
        "from": "cloud code",
        "to": "Claude Code",
        "matchMode": "word",
        "caseSensitive": false
      }
    ]
    """

    enum MatchMode: String, Codable {
        case word        // ASCII Latin token boundary; CJK adjacency is permitted
        case substring   // exact substring (CJK or any)
        case regex       // user-supplied regex
    }

    struct Alias: Codable, Equatable {
        var from: String
        var to: String
        var matchMode: MatchMode
        var caseSensitive: Bool
        var sourceDocument: Data? = nil
        var sourceRow: Int? = nil

        static func make(from: String, to: String, matchMode: MatchMode = .word, caseSensitive: Bool = false) -> Alias {
            Alias(from: from, to: to, matchMode: matchMode, caseSensitive: caseSensitive)
        }
    }

    private convenience init() { self.init(directory: NSHomeDirectory() + "/.vox") }

    init(directory: String) {
        dictDir = directory
        ensureFileExists()
    }

    // MARK: - Read

    /// Fresh-read every call (mirror DictionaryService — file is small, manual
    /// edits take effect without restart).
    var aliases: [Alias] {
        do {
            let (data, rows) = try readDocument()
            lastError = nil
            return rows.enumerated().compactMap { index, row in
                guard let dict = row as? [String: Any], var alias = Self.decode(dict) else { return nil }
                alias.sourceDocument = data
                alias.sourceRow = index
                return alias
            }
        } catch {
            lastError = "aliases.json is unreadable or invalid. Fix its JSON before saving; the file has been preserved."
            return []
        }
    }

    private static func decode(_ dict: [String: Any]) -> Alias? {
        guard let from = (dict["from"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !from.isEmpty, let to = dict["to"] as? String, from != to,
              let mode = MatchMode(rawValue: dict["matchMode"] as? String ?? "word"),
              dict["caseSensitive"] == nil || dict["caseSensitive"] is Bool else { return nil }
        return Alias(from: from, to: to, matchMode: mode, caseSensitive: dict["caseSensitive"] as? Bool ?? false)
    }

    private func readDocument() throws -> (Data, [Any]) {
        let data = try Data(contentsOf: URL(fileURLWithPath: aliasPath))
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [Any] else { throw CocoaError(.fileReadCorruptFile) }
        return (data, rows)
    }

    // MARK: - Apply (core engine)

    /// Apply all aliases in a single pass over `text`.
    /// Computes non-overlapping match ranges against the ORIGINAL text first,
    /// then performs replacements in reverse offset order to keep indices stable.
    /// Same alias matched multiple times in non-overlapping locations: all replaced.
    func apply(_ text: String) -> String {
        return AliasService.apply(text, aliases: aliases)
    }

    /// Pure function for testability: takes aliases explicitly.
    static func apply(_ text: String, aliases: [Alias]) -> String {
        guard !text.isEmpty, !aliases.isEmpty else { return text }

        // Sort longest-from first so longer phrases win conflicts; preserve
        // file order on ties (use stable sort via index decoration).
        let indexed = aliases.enumerated().map { (idx: $0.offset, alias: $0.element) }
        let sorted = indexed.sorted { lhs, rhs in
            if lhs.alias.from.count != rhs.alias.from.count {
                return lhs.alias.from.count > rhs.alias.from.count
            }
            return lhs.idx < rhs.idx
        }

        // Find non-overlapping match ranges. Greedy: walk sorted aliases, claim
        // any range that doesn't overlap an already-claimed range.
        struct Match {
            let range: NSRange
            let replacement: String
        }
        var matches: [Match] = []
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        for entry in sorted {
            if ProcessInfo.processInfo.systemUptime > deadline { return text }
            let alias = entry.alias
            let foundRanges = findRanges(of: alias, in: text, fullRange: fullRange)
            for r in foundRanges {
                if ProcessInfo.processInfo.systemUptime > deadline { return text }
                if !overlapsAny(r, claimed: matches.map { $0.range }) {
                    matches.append(Match(range: r, replacement: alias.to))
                }
            }
        }

        if matches.isEmpty { return text }

        // Apply replacements in reverse offset order to keep earlier offsets stable.
        let sortedMatches = matches.sorted { $0.range.location > $1.range.location }
        let result = NSMutableString(string: text)
        for m in sortedMatches {
            result.replaceCharacters(in: m.range, with: m.replacement)
        }
        return result as String
    }

    // MARK: - Range finder per alias

    private static func findRanges(of alias: Alias, in text: String, fullRange: NSRange) -> [NSRange] {
        switch alias.matchMode {
        case .word:
            return findWordBoundaryRanges(from: alias.from, in: text, caseSensitive: alias.caseSensitive)
        case .substring:
            return findSubstringRanges(from: alias.from, in: text, caseSensitive: alias.caseSensitive)
        case .regex:
            return findRegexRanges(pattern: alias.from, in: text, caseSensitive: alias.caseSensitive)
        }
    }

    private static func findWordBoundaryRanges(from: String, in text: String, caseSensitive: Bool) -> [NSRange] {
        // Escape regex metacharacters in `from`, then wrap with \b...\b.
        let escaped = NSRegularExpression.escapedPattern(for: from)
        let pattern = "(?<![A-Za-z0-9_])\(escaped)(?![A-Za-z0-9_])"
        return findRegexRanges(pattern: pattern, in: text, caseSensitive: caseSensitive)
    }

    private static func findSubstringRanges(from: String, in text: String, caseSensitive: Bool) -> [NSRange] {
        let nsText = text as NSString
        var ranges: [NSRange] = []
        var searchStart = 0
        let opts: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        while searchStart < nsText.length {
            let r = nsText.range(of: from, options: opts, range: NSRange(location: searchStart, length: nsText.length - searchStart))
            if r.location == NSNotFound { break }
            ranges.append(r)
            searchStart = r.location + r.length
            if r.length == 0 { break }   // safety
        }
        return ranges
    }

    private static func findRegexRanges(pattern: String, in text: String, caseSensitive: Bool) -> [NSRange] {
        guard pattern.utf8.count <= 4096 else { return [] }
        var options: NSRegularExpression.Options = []
        if !caseSensitive { options.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            // Invalid regex: skip this alias entirely (per spec)
            return []
        }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.025
        var ranges: [NSRange] = []
        var aborted = false
        // reportProgress lets ICU interrupt catastrophic backtracking, even before a match.
        regex.enumerateMatches(in: text, options: [.reportProgress], range: fullRange) { result, flags, stop in
            if flags.contains(.internalError) || ProcessInfo.processInfo.systemUptime > deadline {
                aborted = true
                stop.pointee = true
            } else if let range = result?.range, range.location != NSNotFound, range.length > 0 {
                ranges.append(range)
            }
        }
        return aborted ? [] : ranges
    }

    private static func overlapsAny(_ range: NSRange, claimed: [NSRange]) -> Bool {
        for c in claimed {
            // Overlap iff start of one is before end of the other (and vice versa)
            if NSMaxRange(range) > c.location && NSMaxRange(c) > range.location {
                return true
            }
        }
        return false
    }

    // MARK: - Mutations (used by Settings UI)

    @discardableResult
    func addAlias(_ alias: Alias) -> Bool { mutate(expected: nil, replacement: alias) }

    @discardableResult
    func removeAlias(_ expected: Alias) -> Bool { mutate(expected: expected, replacement: nil) }

    @discardableResult
    func updateAlias(_ expected: Alias, to alias: Alias) -> Bool { mutate(expected: expected, replacement: alias) }

    private func mutate(expected: Alias?, replacement: Alias?) -> Bool {
        do {
            let (original, document) = try readDocument()
            var rows = document
            var index: Int? = nil
            if let expected = expected {
                guard expected.sourceDocument == original, let row = expected.sourceRow, rows.indices.contains(row) else {
                    lastError = "The file changed since this row was loaded. Reload and try again."
                    return false
                }
                index = row
            }
            if var alias = replacement {
                alias.from = alias.from.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !alias.from.isEmpty, alias.from != alias.to else {
                    lastError = "From must be nonempty and different from To."
                    return false
                }
                if alias.matchMode == .regex, alias.from.utf8.count > 4096 || (try? NSRegularExpression(pattern: alias.from)) == nil {
                    lastError = "The regular expression is invalid."
                    return false
                }
                let conflict = rows.enumerated().contains { offset, row in
                    guard offset != index, let dict = row as? [String: Any], let other = Self.decode(dict) else { return false }
                    return other.matchMode == alias.matchMode && other.from.compare(alias.from, options: (!alias.caseSensitive || !other.caseSensitive) ? [.caseInsensitive] : []) == .orderedSame
                }
                guard !conflict else { lastError = "This alias conflicts with an existing rule."; return false }
                var dict = index.flatMap { rows[$0] as? [String: Any] } ?? [:]
                dict.merge(["from": alias.from, "to": alias.to, "matchMode": alias.matchMode.rawValue, "caseSensitive": alias.caseSensitive]) { _, new in new }
                if let i = index { rows[i] = dict } else { rows.append(dict) }
            } else if let i = index { rows.remove(at: i) }
            return try writeDocument(rows, original: original)
        } catch {
            lastError = "Cannot save aliases.json. Check its JSON and permissions; the original file was preserved."
            return false
        }
    }

    private func writeDocument(_ rows: [Any], original: Data) throws -> Bool {
        let url = URL(fileURLWithPath: aliasPath)
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        // Detect a manual edit between fresh read and mutation instead of rewriting a stale view.
        guard try Data(contentsOf: url) == original else {
            lastError = "The file changed while saving. Reload and try again."
            return false
        }
        try JSONBackupStore.backup(original, directory: URL(fileURLWithPath: dictDir), prefix: "aliases-backup-")
        guard try Data(contentsOf: url) == original else { throw CocoaError(.fileWriteUnknown) }
        try JSONBackupStore.atomicWrite(data, to: url)
        lastError = nil
        return true
    }

    private func ensureFileExists() {
        if FileManager.default.fileExists(atPath: aliasPath) { return }
        do {
            try FileManager.default.createDirectory(atPath: dictDir, withIntermediateDirectories: true)
            try AliasService.seedContent.write(toFile: aliasPath, atomically: true, encoding: .utf8)
        } catch { lastError = "Could not create aliases.json." }
    }

    @discardableResult
    func resetToDefaults() -> Bool {
        do {
            let (original, _) = try readDocument()
            let rows = try JSONSerialization.jsonObject(with: Data(Self.seedContent.utf8)) as! [Any]
            return try writeDocument(rows, original: original)
        } catch { lastError = "Cannot reset malformed aliases.json. Fix its JSON first."; return false }
    }
}
