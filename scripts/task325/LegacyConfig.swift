import Foundation
@main struct LegacyConfigTests {
    static func main() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vox325-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.json")
        let original = Data("{\"editWindowEnabled\":true,\"editWindowDuration\":3,\"unknown\":99}".utf8)
        try original.write(to: file)
        let c = ConfigService(directory: dir.path, getKey: { _ in nil }, setKey: { _, _ in fatalError("No key operation expected") }, reportError: { _ in fatalError("Unexpected config error") })
        guard try Data(contentsOf: file) == original else { fatalError("Initialization rewrote legacy config") }
        guard c.write(key: "hotkeyMode", value: "hold") else { fatalError("Independent config update failed") }
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        guard saved["editWindowEnabled"] as? Bool == true, saved["editWindowDuration"] as? Int == 3,
              saved["unknown"] as? Int == 99 else { fatalError("Unknown legacy fields were lost") }
        print("PASS: 2 legacy config checks; no startup rewrite, unknown fields retained")
    }
}
