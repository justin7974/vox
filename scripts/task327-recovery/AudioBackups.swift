import Foundation
final class LogService { static let shared = LogService(); func debug(_ s: String) {}; func error(_ s: String) {} }
@main struct BackupTests {
    static func main() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vox327-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let one = dir.appendingPathComponent("vox-older.wav"), two = dir.appendingPathComponent("vox-newer.wav")
        try Data(repeating: 0, count: 32000).write(to: one)
        try Data(repeating: 0, count: 64000).write(to: two)
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:100)],ofItemAtPath:one.path)
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:200)],ofItemAtPath:two.path)
        try FileManager.default.createSymbolicLink(at:dir.appendingPathComponent("vox-link.wav"),withDestinationURL:one)
        try Data().write(to:dir.appendingPathComponent("other.txt"))
        let audio = AudioService(backupDirectory:dir)
        let backups = audio.getBackups()
        precondition(backups.count == 2 && backups[0].url == two && backups[1].url == one)
        precondition(backups[0].durationSeconds == 2)
        let req = RetryRecordingRequest(audioURL:one,translateMode:false)
        precondition(req.resolve(in:backups.map { $0.url }) == one)
        precondition(audio.stopRecording() == nil && audio.lastBackupURL == nil)
        precondition(FileManager.default.fileExists(atPath:one.path))
        print("PASS: 5 real AudioService backup checks; injected temporary directory, no microphone")
    }
}
