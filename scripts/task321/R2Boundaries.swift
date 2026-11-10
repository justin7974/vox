import Foundation

final class LastSilent: STTProvider {
    let name = "fixture"
    var calls = 0
    #if BASELINE_R1
    func transcribe(audioFile: URL) async -> String {
        calls += 1
        return audioFile.lastPathComponent == "silent" ? "" : "speech"
    }
    #else
    func transcribe(audioFile: URL) async -> String? {
        calls += 1
        return audioFile.lastPathComponent == "silent" ? "" : "speech"
    }
    #endif
}
@main struct R2Boundaries {
    static func main() async throws {
        var failures = 0
        func verify(_ value: Bool, _ name: String) { print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        let provider = LastSilent()
        let text = await STTService.transcribeChunks([URL(fileURLWithPath:"speech"),URL(fileURLWithPath:"silent")],provider:provider){_,_ in}
        verify(text == "speech" && provider.calls == 2,"successful silent tail preserves speech without retry")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vox321-r2-boundary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        try JSONSerialization.data(withJSONObject:["legacy":["apiKey":"SECRET-FIXTURE","model":"fake"]]).write(to:dir.appendingPathComponent("config.json"))
        let config = ConfigService(directory:dir.path,getKey:{_ in nil},setKey:{_,_ in true},reportError:{_ in})
        let first = try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix("config-backup-")}
        verify(try first.count == 1 && (first.allSatisfy { !(String(data:try Data(contentsOf:$0),encoding:.utf8)!).contains("SECRET-FIXTURE") }),"first migration backup excludes plaintext key")
        for i in 0..<8 { _ = config.write(key:"counter",value:i) }
        let retained = try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix("config-backup-")}
        verify(retained.count <= 5,"backup count bounded")
        print("r2 boundaries: \(3-failures)/3 passed")
        exit(failures == 0 ? 0 : 1)
    }
}
