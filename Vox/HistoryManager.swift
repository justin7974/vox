import Foundation

/// Manages voice input history records — saves polished results with timestamps,
/// auto-cleans expired entries based on user-configured retention period.
class HistoryManager {
    static let shared = HistoryManager()

    struct Record: Codable {
        let text: String
        let timestamp: Date
        var originalText: String?    // Original Chinese (translation mode only)
        var isTranslation: Bool?     // Whether this was a translation

        var translationMode: Bool { isTranslation ?? false }
    }

    private let historyFilePath = NSHomeDirectory() + "/.vox/history.json"
    private var records: [Record] = []

    // MARK: - Settings (via ConfigService)

    var isEnabled: Bool {
        get { ConfigService.shared.historyEnabled }
        set { ConfigService.shared.historyEnabled = newValue }
    }

    var retentionDays: Int {
        get { ConfigService.shared.historyRetentionDays }
        set { ConfigService.shared.historyRetentionDays = newValue }
    }

    // MARK: - Init

    private init() {
        loadRecords()
        cleanExpired()
    }

    // MARK: - Public API

    /// Add a new record (with optional translation info)
    func addRecord(text: String, originalText: String? = nil, isTranslation: Bool = false) {
        guard isEnabled, !text.isEmpty else { return }
        let record = Record(
            text: text,
            timestamp: Date(),
            originalText: originalText,
            isTranslation: isTranslation ? true : nil
        )
        records.insert(record, at: 0) // newest first
        saveRecords()
        NSLog("Vox: History record added (\(records.count) total)")
    }

    /// Get all records (newest first), cleaning expired ones first
    func getRecords() -> [Record] {
        cleanExpired()
        return records
    }

    /// Delete a single record by index
    func deleteRecord(at index: Int) {
        guard index >= 0 && index < records.count else { return }
        records.remove(at: index)
        saveRecords()
        NSLog("Vox: History record deleted (\(records.count) remaining)")
    }

    /// Clear all history
    func clearAll() {
        records.removeAll()
        saveRecords()
        NSLog("Vox: History cleared")
    }

    /// Number of records
    var count: Int { records.count }

    // MARK: - Persistence

    private func loadRecords() {
        guard FileManager.default.fileExists(atPath: historyFilePath),
              let data = FileManager.default.contents(atPath: historyFilePath) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let loaded = try? decoder.decode([Record].self, from: data) {
            records = loaded
        }
    }

    private func saveRecords() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(records) else { return }
        let dir = NSHomeDirectory() + "/.vox"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: historyFilePath))
    }

    // MARK: - Cleanup

    private func cleanExpired() {
        // retentionDays == 0 means "forever" — skip cleanup
        guard retentionDays > 0 else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date()
        let before = records.count
        records.removeAll { $0.timestamp < cutoff }
        if records.count < before {
            saveRecords()
            NSLog("Vox: Cleaned \(before - records.count) expired history records")
        }
    }

}
