import AVFoundation

class AudioRecorder {
    private var audioRecorder: AVAudioRecorder?
    private var currentURL: URL?
    private var meteringTimer: Timer?
    private(set) var peakPower: Float = -160.0 // Track peak audio level

    func start() {
        let timestamp = Int(Date().timeIntervalSince1970)
        let url = URL(fileURLWithPath: "/tmp/voice-input-\(timestamp).wav")
        currentURL = url
        peakPower = -160.0

        // 16kHz mono 16-bit PCM WAV — exactly what whisper-cpp expects
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

            // Sample audio level every 200ms to detect silence
            meteringTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                self?.audioRecorder?.updateMeters()
                let power = self?.audioRecorder?.averagePower(forChannel: 0) ?? -160.0
                if power > (self?.peakPower ?? -160.0) {
                    self?.peakPower = power
                }
            }
        } catch {
            NSLog("VoiceInput: Recording failed: \(error)")
        }
    }

    /// Returns true if meaningful audio was detected (not just silence)
    var hasAudio: Bool {
        // -50 dB is a reasonable threshold: normal speech is -20 to -10 dB
        return peakPower > -50.0
    }

    @discardableResult
    func stop() -> URL? {
        meteringTimer?.invalidate()
        meteringTimer = nil
        audioRecorder?.stop()
        audioRecorder = nil
        return currentURL
    }
}
