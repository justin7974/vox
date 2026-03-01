import Foundation

final class LogService {
    static let shared = LogService()

    private let logPath: String
    private let queue = DispatchQueue(label: "com.vox.log", qos: .utility)

    private init() {
        logPath = NSHomeDirectory() + "/.vox/debug.log"
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
        let ts = ISO8601DateFormatter().string(from: Date())
        let prefix = tag.map { "[\($0) \(ts)]" } ?? "[\(ts)]"
        let line = "\(prefix) \(msg)\n"
        NSLog("Vox: \(msg)")

        queue.async { [logPath] in
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: logPath) {
                if let fh = FileHandle(forWritingAtPath: logPath) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    fh.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: logPath, contents: data)
            }
        }
    }
}
