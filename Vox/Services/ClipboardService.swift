import Cocoa

/// Monitors NSPasteboard for changes and maintains a clipboard history.
final class ClipboardService {
    static let shared = ClipboardService()

    private(set) var history: [ClipboardItem] = []
    private var maxItems = 50
    private var timer: Timer?
    private var lastChangeCount: Int

    private init() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    // MARK: - Public API

    func startMonitoring() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkForChanges()
        }
        NSLog("Vox: ClipboardService monitoring started")
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    /// Paste a specific clipboard item to the current cursor position.
    func paste(item: ClipboardItem) {
        PasteService.shared.paste(text: item.text)
    }

    func setMaxItems(_ count: Int) {
        maxItems = count
        if history.count > maxItems {
            history = Array(history.prefix(maxItems))
        }
    }

    func clearHistory() {
        history.removeAll()
    }

    // MARK: - Polling

    private func checkForChanges() {
        let pb = NSPasteboard.general
        let currentCount = pb.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        guard let text = pb.string(forType: .string), !text.isEmpty else { return }

        // Don't add duplicates of the most recent item
        if let latest = history.first, latest.text == text { return }

        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
        let item = ClipboardItem(text: text, sourceApp: sourceApp)
        history.insert(item, at: 0)

        // Trim to max
        if history.count > maxItems {
            history = Array(history.prefix(maxItems))
        }
    }
}
