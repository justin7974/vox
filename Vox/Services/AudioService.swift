import AVFoundation

class AudioService {
    static let shared = AudioService()

    private let log = LogService.shared

    // MARK: - Recording

    private var audioRecorder: AVAudioRecorder?
    private var currentURL: URL?
    private var meteringTimer: Timer?
    private(set) var peakPower: Float = -160.0
    private(set) var currentPower: Float = -160.0
    var onAudioLevel: ((Float) -> Void)?

    func startRecording() {
        let timestamp = Int(Date().timeIntervalSince1970)
        let url = URL(fileURLWithPath: "/tmp/vox-\(timestamp).wav")
        currentURL = url
        peakPower = -160.0

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()

            meteringTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.audioRecorder?.updateMeters()
                let power = self?.audioRecorder?.averagePower(forChannel: 0) ?? -160.0
                self?.currentPower = power
                if power > (self?.peakPower ?? -160.0) {
                    self?.peakPower = power
                }
                self?.onAudioLevel?(power)
            }
        } catch {
            log.error("Recording failed: \(error)")
        }
    }

    var hasAudio: Bool {
        peakPower > -50.0
    }

    @discardableResult
    func stopRecording(backup: Bool = true) -> URL? {
        meteringTimer?.invalidate()
        meteringTimer = nil
        audioRecorder?.stop()
        audioRecorder = nil
        let url = currentURL
        if backup, let url = url {
            saveBackup(audioURL: url)
        }
        return url
    }

    // MARK: - Backup

    private let maxBackups = 5
    private let backupDir = NSHomeDirectory() + "/.vox/audio"

    struct Backup: Comparable {
        let url: URL
        let timestamp: Date
        let durationSeconds: Int

        static func < (lhs: Backup, rhs: Backup) -> Bool {
            lhs.timestamp > rhs.timestamp
        }
    }

    private func ensureBackupDir() {
        try? FileManager.default.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
    }

    @discardableResult
    private func saveBackup(audioURL: URL) -> URL? {
        ensureBackupDir()
        let timestamp = Int(Date().timeIntervalSince1970)
        let dest = URL(fileURLWithPath: "\(backupDir)/vox-\(timestamp).wav")
        do {
            try FileManager.default.copyItem(at: audioURL, to: dest)
            log.debug("Audio backed up → \(dest.lastPathComponent)")
            cleanupBackups()
            return dest
        } catch {
            log.error("Audio backup failed: \(error.localizedDescription)")
            return nil
        }
    }

    func getBackups() -> [Backup] {
        ensureBackupDir()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: backupDir) else { return [] }
        return files
            .filter { $0.hasSuffix(".wav") }
            .compactMap { filename -> Backup? in
                let path = "\(backupDir)/\(filename)"
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let size = attrs[.size] as? Int,
                      let modified = attrs[.modificationDate] as? Date else { return nil }
                let duration = max(1, size / 32000)
                return Backup(url: URL(fileURLWithPath: path), timestamp: modified, durationSeconds: duration)
            }
            .sorted()
    }

    private func cleanupBackups() {
        let backups = getBackups()
        if backups.count > maxBackups {
            for backup in backups.dropFirst(maxBackups) {
                try? FileManager.default.removeItem(at: backup.url)
                log.debug("Removed old backup \(backup.url.lastPathComponent)")
            }
        }
    }
}
