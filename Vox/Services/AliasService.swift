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
final class AliasService {
    static let shared = AliasService()

    private let log = LogService.shared
    private let dictDir = NSHomeDirectory() + "/.vox"
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
        case word        // Latin word-boundary (\b...\b)
        case substring   // exact substring (CJK or any)
        case regex       // user-supplied regex
    }

    struct Alias: Codable, Equatable {
        var from: String
        var to: String
        var matchMode: MatchMode
        var caseSensitive: Bool

        static func make(from: String, to: String, matchMode: MatchMode = .word, caseSensitive: Bool = false) -> Alias {
            Alias(from: from, to: to, matchMode: matchMode, caseSensitive: caseSensitive)
        }
    }

    private init() {
        ensureFileExists()
    }

    // MARK: - Read

    /// Fresh-read every call (mirror DictionaryService — file is small, manual
    /// edits take effect without restart).
    var aliases: [Alias] {
        guard let data = FileManager.default.contents(atPath: aliasPath),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { dict in
            guard let from = (dict["from"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !from.isEmpty,
                  let to = dict["to"] as? String else {
                return nil
            }
            // Skip no-op
            if from == to { return nil }
            let modeStr = (dict["matchMode"] as? String) ?? "word"
            let mode = MatchMode(rawValue: modeStr) ?? .word
            let caseSensitive = (dict["caseSensitive"] as? Bool) ?? false
            return Alias(from: from, to: to, matchMode: mode, caseSensitive: caseSensitive)
        }
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

        for entry in sorted {
            let alias = entry.alias
            let foundRanges = findRanges(of: alias, in: text, fullRange: fullRange)
            for r in foundRanges {
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
        let pattern = "\\b\(escaped)\\b"
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
        var options: NSRegularExpression.Options = []
        if !caseSensitive { options.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            // Invalid regex: skip this alias entirely (per spec)
            return []
        }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        return regex.matches(in: text, options: [], range: fullRange).map { $0.range }
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
    func addAlias(_ alias: Alias) -> Bool {
        let trimmedFrom = alias.from.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFrom.isEmpty, trimmedFrom != alias.to else { return false }
        var current = aliases
        // Dedupe by (from, matchMode) case-insensitive when caseSensitive=false
        let exists = current.contains { existing in
            existing.matchMode == alias.matchMode &&
                existing.from.compare(trimmedFrom, options: alias.caseSensitive ? [] : [.caseInsensitive]) == .orderedSame
        }
        if exists { return false }
        var normalized = alias
        normalized.from = trimmedFrom
        current.append(normalized)
        writeAliases(current)
        return true
    }

    func removeAlias(at index: Int) {
        var current = aliases
        guard index >= 0 && index < current.count else { return }
        current.remove(at: index)
        writeAliases(current)
    }

    @discardableResult
    func updateAlias(at index: Int, to alias: Alias) -> Bool {
        let trimmedFrom = alias.from.trimmingCharacters(in: .whitespacesAndNewlines)
        var current = aliases
        guard !trimmedFrom.isEmpty, trimmedFrom != alias.to,
              index >= 0 && index < current.count else { return false }
        // Allow keeping same `from` at this index; only conflict if another row matches
        let conflict = current.enumerated().contains { (offset, existing) in
            offset != index &&
                existing.matchMode == alias.matchMode &&
                existing.from.compare(trimmedFrom, options: alias.caseSensitive ? [] : [.caseInsensitive]) == .orderedSame
        }
        if conflict { return false }
        var normalized = alias
        normalized.from = trimmedFrom
        current[index] = normalized
        writeAliases(current)
        return true
    }

    private func writeAliases(_ list: [Alias]) {
        do {
            try FileManager.default.createDirectory(atPath: dictDir, withIntermediateDirectories: true)
            let raw: [[String: Any]] = list.map { a in
                [
                    "from": a.from,
                    "to": a.to,
                    "matchMode": a.matchMode.rawValue,
                    "caseSensitive": a.caseSensitive,
                ]
            }
            let data = try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted])
            try data.write(to: URL(fileURLWithPath: aliasPath), options: .atomic)
        } catch {
            log.debug("AliasService write failed: \(error.localizedDescription)")
        }
    }

    private func ensureFileExists() {
        if FileManager.default.fileExists(atPath: aliasPath) { return }
        try? FileManager.default.createDirectory(atPath: dictDir, withIntermediateDirectories: true)
        try? AliasService.seedContent.write(toFile: aliasPath, atomically: true, encoding: .utf8)
        log.debug("Seeded aliases.json at \(aliasPath)")
    }

    /// Overwrite aliases.json with the bundled default seed.
    func resetToDefaults() {
        try? FileManager.default.createDirectory(atPath: dictDir, withIntermediateDirectories: true)
        try? AliasService.seedContent.write(toFile: aliasPath, atomically: true, encoding: .utf8)
        log.debug("Reset aliases.json to defaults")
    }
}
