import Foundation

/// A notification carries only the backup's leaf name and mode, never a path or transcript.
struct RetryRecordingRequest {
    static let category = "vox.retry-recording"
    let filename: String
    let translateMode: Bool

    init(audioURL: URL, translateMode: Bool) {
        self.filename = audioURL.lastPathComponent
        self.translateMode = translateMode
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let filename = userInfo["backup"] as? String,
              filename == (filename as NSString).lastPathComponent,
              filename.hasPrefix("vox-"), filename.hasSuffix(".wav"),
              let translate = userInfo["translate"] as? Bool else { return nil }
        self.filename = filename
        self.translateMode = translate
    }

    static func notificationBody(fallbackAlreadyPasted: Bool) -> String {
        fallbackAlreadyPasted ? "原文已贴；点此再贴一份润色版" : "这段没处理成功，点此重试"
    }

    var userInfo: [AnyHashable: Any] { ["backup": filename, "translate": translateMode] }
    func resolve(in backups: [URL]) -> URL? { backups.first { $0.lastPathComponent == filename } }
}
