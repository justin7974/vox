import Foundation
import Darwin

/// A protected old backup reproduces a real cleanup failure without touching Trash.
@main struct BackupCleanupFailure {
    enum TestFailure: Error { case setup, regression }

    static func main() {
        do { try run() }
        catch { fputs("backup cleanup regression failed\n", stderr); exit(1) }
    }

    static func run() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("vox325-cleanup-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let protected = directory.appendingPathComponent("config-backup-protected.json")
        defer {
            _ = chflags(protected.path, 0)
            try? fm.removeItem(at: directory)
        }
        try Data("{}".utf8).write(to: protected)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: protected.path)
        for index in 0..<JSONBackupStore.retention {
            try Data("{}".utf8).write(to: directory.appendingPathComponent("config-backup-fixture-\(index).json"))
        }
        guard chflags(protected.path, UInt32(UF_IMMUTABLE)) == 0 else { throw TestFailure.setup }
        let configFile = directory.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: ["fixture": ["model": "fake", "apiKey": ""]]).write(to: configFile)
        var key = "OLD-TEST-KEY"
        var writes: [String] = []
        var errors: [String] = []
        let config = ConfigService(directory: directory.path,
            getKey: { _ in key },
            setKey: { _, value in key = value; writes.append(value); return true },
            reportError: { errors.append($0) })
        let saved = config.write(values: ["fixture": ["apiKey": "NEW-TEST-KEY", "model": "new-model"]])
        let disk = try JSONSerialization.jsonObject(with: Data(contentsOf: configFile)) as! [String: Any]
        let fixture = disk["fixture"] as? [String: Any]
        let checks: [(Bool, String)] = [
            (saved, "cleanup failure does not fail settings save"),
            (key == "NEW-TEST-KEY" && writes == ["NEW-TEST-KEY"], "cleanup failure does not roll back fake Keychain"),
            (fixture?["model"] as? String == "new-model" && fixture?["apiKey"] as? String == "", "config commits without plaintext key"),
            (errors.isEmpty && fm.fileExists(atPath: protected.path), "uncleanable old backup remains without a save error")
        ]
        for (passed, name) in checks { print("\(passed ? "PASS" : "FAIL"): \(name)") }
        guard checks.allSatisfy({ $0.0 }) else { throw TestFailure.regression }
        print("backup cleanup regression: 4/4 passed")
    }
}
