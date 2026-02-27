import AVFoundation

class AudioRecorder {
    private var audioRecorder: AVAudioRecorder?
    private var currentURL: URL?
    private var meteringTimer: Timer?
    private(set) var peakPower: Float = -160.0 // Track peak audio level
    private(set) var currentPower: Float = -160.0 // Real-time level
    var onAudioLevel: ((Float) -> Void)?

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

            // Sample audio level every 100ms for smooth visualization + silence detection
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
