import Foundation

final class LogService {
    static let shared = LogService()

    private let logPath: String
    private let queue = DispatchQueue(label: "com.vox.log", qos: .utility)

    // ISO8601DateFormatter isn't thread-safe to configure but safe for string(from:);
    // hold a single shared instance to avoid allocating one per log call.
    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // Rotation thresholds.
    private let maxLogBytes: Int = 5 * 1024 * 1024  // 5 MB triggers rotation
    private let rotatedSuffix = ".1"

    private init() {
        logPath = NSHomeDirectory() + "/.vox/debug.log"
        rotateIfNeeded()
    }

    func debug(_ msg: String, tag: String? = nil) {
        log(msg, level: "DEBUG", tag: tag)
    }

    func info(_ msg: String, tag: String? = nil) {
        log(msg, level: "INFO", tag: tag)
    }

    func warning(_ msg: String, tag: String? = nil) {
        log(msg, level: "WARN", tag: tag)
    }

    func error(_ msg: String, tag: String? = nil) {
        log(msg, level: "ERROR", tag: tag)
    }

    private func log(_ msg: String, level: String, tag: String?) {
        let ts = LogService.timestampFormatter.string(from: Date())
        let prefix = tag.map { "[\($0) \(ts)]" } ?? "[\(ts)]"
        let line = "\(prefix) \(msg)\n"
        NSLog("Vox: \(msg)")

        queue.async { [logPath, maxLogBytes, rotatedSuffix] in
            guard let data = line.data(using: .utf8) else { return }
            let fm = FileManager.default
            if fm.fileExists(atPath: logPath) {
                // Cheap size check; rotate in-place so the live handle gets a fresh file.
                if let attrs = try? fm.attributesOfItem(atPath: logPath),
                   let size = attrs[.size] as? Int, size > maxLogBytes {
                    let rotated = logPath + rotatedSuffix
                    try? fm.removeItem(atPath: rotated)
                    try? fm.moveItem(atPath: logPath, toPath: rotated)
                }
                if !fm.fileExists(atPath: logPath) {
                    fm.createFile(atPath: logPath, contents: data)
                } else if let fh = FileHandle(forWritingAtPath: logPath) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    fh.closeFile()
                }
            } else {
                fm.createFile(atPath: logPath, contents: data)
            }
        }
    }

    /// One-shot rotation check at init time in case the previous run left a large file.
    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: logPath),
              let size = attrs[.size] as? Int, size > maxLogBytes else { return }
        let rotated = logPath + rotatedSuffix
        try? fm.removeItem(atPath: rotated)
        try? fm.moveItem(atPath: logPath, toPath: rotated)
    }
}
