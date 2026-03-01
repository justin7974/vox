import Foundation

struct ClipboardItem: Identifiable {
    let id: UUID
    let text: String
    let sourceApp: String?
    let timestamp: Date

    init(text: String, sourceApp: String? = nil) {
        self.id = UUID()
        self.text = text
        self.sourceApp = sourceApp
        self.timestamp = Date()
    }
}
