import Foundation
import Darwin

/// Backups restore settings structure, never credentials. Retain only the newest five.
enum JSONBackupStore {
    static let retention = 5

    static func redacted(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, value) in dictionary {
                result[key] = key.lowercased() == "apikey" ? "" : redacted(value)
            }
            return result
        }
        if let array = value as? [Any] { return array.map(redacted) }
        return value
    }

    static func backup(_ original: Data, directory: URL, prefix: String) throws {
        let object = try JSONSerialization.jsonObject(with: original)
        let data = try JSONSerialization.data(withJSONObject: redacted(object), options: [.prettyPrinted, .sortedKeys])
        let backup = directory.appendingPathComponent("\(prefix)\(UUID().uuidString).json")
        try atomicWrite(data, to: backup)
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a == b ? $0.lastPathComponent > $1.lastPathComponent : a > b
            }
        for old in files.dropFirst(retention) {
            // Tests use only their own temporary directory; production deletions use Trash.
            let temporaryRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
            if old.resolvingSymlinksInPath().path.hasPrefix(temporaryRoot) {
                try FileManager.default.removeItem(at: old)
            } else { try FileManager.default.trashItem(at: old, resultingItemURL: nil) }
        }
    }

    /// Set permissions before committing: no error after rename can undo a committed secret change.
    static func atomicWrite(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".vox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        guard rename(temporary.path, url.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}
