import Foundation
import AVFoundation

// MARK: - Protocol

// nil means request/tool failure; "" means a successful silent segment.
protocol STTProvider {
    var name: String { get }
    var maxAudioFileBytes: Int? { get }
    func transcribe(audioFile: URL) async -> String?
}

extension STTProvider {
    var maxAudioFileBytes: Int? { nil }
    static func requestTimeout(audioBytes: Int) -> TimeInterval { min(300, max(60, 60 + Double(audioBytes) / 32_000)) }
}

// MARK: - WhisperLocalProvider

struct WhisperLocalProvider: STTProvider {
    let name = "whisper-local"
    private let log = LogService.shared
    private let execPath: String
    private let modelPath: String

    init(execPath: String, modelPath: String) {
        self.execPath = execPath
        self.modelPath = modelPath
    }

    func transcribe(audioFile: URL) async -> String? {
        let result = await ProcessRunner.run(executable: execPath, arguments: [
            "-m", modelPath, "-l", "zh", "-t", "4", "--no-timestamps", "-f", audioFile.path
        ], timeout: Self.executionTimeout(audioDuration: Self.audioDuration(audioFile)))
        guard result.status == 0, !result.stopped else {
            log.debug("Whisper process failed or stopped (status=\(result.status))")
            return nil
        }
        return parseWhisperOutput(String(data: result.data, encoding: .utf8) ?? "")
    }

    static func audioDuration(_ url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    static func executionTimeout(audioDuration: TimeInterval?) -> TimeInterval {
        guard let duration = audioDuration, duration.isFinite, duration > 0 else { return 300 }
        return min(6 * 3600, max(180, duration * 1.5 + 120))
    }

    private func parseWhisperOutput(_ output: String) -> String {
        let lines = output.components(separatedBy: .newlines)
        var textParts: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if trimmed.hasPrefix("whisper_") || trimmed.hasPrefix("system_info") { continue }

            if trimmed.hasPrefix("[") && trimmed.contains("-->") {
                if let closeBracket = trimmed.firstIndex(of: "]") {
                    let text = String(trimmed[trimmed.index(after: closeBracket)...])
                        .trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty {
                        textParts.append(text)
                    }
                }
            } else {
                textParts.append(trimmed)
            }
        }

        return textParts.joined(separator: "")
    }
}

// MARK: - QwenASRProvider

struct QwenASRProvider: STTProvider {
    let name = "qwen"
    let maxAudioFileBytes: Int? = 7_000_000 // base64 inflates ~1.37x, keep under 10MB data-uri limit
    private let log = LogService.shared
    private let apiKey: String
    private let session: URLSession

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    func transcribe(audioFile: URL) async -> String? {
        guard let audioData = try? Data(contentsOf: audioFile) else {
            log.debug("Failed to read audio file")
            return nil
        }
        let base64Audio = audioData.base64EncodedString()

        let ext = audioFile.pathExtension.lowercased()
        let mime: String
        switch ext {
        case "ogg": mime = "audio/ogg"
        case "mp3": mime = "audio/mp3"
        case "wav": mime = "audio/wav"
        default:    mime = "audio/wav"
        }
        let dataURI = "data:\(mime);base64,\(base64Audio)"

        guard let url = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout(audioBytes: audioData.count)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // NOTE: qwen3-asr-flash via chat/completions REJECTS system role messages with
        // `InternalError.Algo.InvalidParameter: does not support this input`. Dictionary
        // hints are applied only at the LLM post-processing layer (LLMService.buildSystemPrompt).
        // If we later switch to DashScope's native ASR API, it has a `vocabulary_id` field.
        let body: [String: Any] = [
            "model": "qwen3-asr-flash",
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "input_audio",
                            "input_audio": ["data": dataURI]
                        ]
                    ]
                ]
            ],
            "stream": false,
            "asr_options": [
                "enable_itn": true,
                "language": "zh"
            ]
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            log.debug("Failed to serialize Qwen ASR request")
            return nil
        }
        request.httpBody = httpBody
        log.debug("Qwen ASR request body size: \(httpBody.count) bytes")

        let data: Data
        do {
            let (responseData, response) = try await session.data(for: request)
            data = responseData
            if let httpResponse = response as? HTTPURLResponse {
                log.debug("Qwen ASR HTTP status: \(httpResponse.statusCode)")
                guard (200..<300).contains(httpResponse.statusCode) else { return nil }
            }
        } catch {
            log.debug("Qwen ASR network error: \((error as NSError).code)")
            DispatchQueue.main.async {
                AppDelegate.showNotification(title: "Vox", message: "ASR network error: \((error as NSError).code)")
            }
            return nil
        }

        log.debug("Qwen ASR response bytes=\(data.count)")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log.debug("Qwen ASR failed to parse JSON")
            return nil
        }

        if let errorInfo = json["error"] as? [String: Any],
           let message = errorInfo["message"] as? String {
            log.debug("Qwen ASR API returned an error")
            let shortMsg = message.contains("invalid_api_key") ? "Invalid API key. Check Settings." : "ASR API error."
            DispatchQueue.main.async {
                AppDelegate.showNotification(title: "Vox", message: shortMsg)
            }
            return nil
        }

        if let choices = json["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let content = message["content"] as? String {
            let result = content.trimmingCharacters(in: .whitespacesAndNewlines)
            log.debug("Qwen ASR result characters=\(result.count)")
            if result.isEmpty {
                log.debug("Qwen ASR returned empty result")
            }
            return result
        } else {
            log.debug("Qwen ASR: no content in response (unexpected format)")
            return nil
        }
    }
}

// MARK: - WhisperAPIProvider (OpenAI Whisper API compatible)

struct WhisperAPIProvider: STTProvider {
    let name = "custom"
    private let log = LogService.shared
    private let baseURL: String
    private let apiKey: String
    private let model: String
    private let session: URLSession

    init(baseURL: String, apiKey: String, model: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    func transcribe(audioFile: URL) async -> String? {
        guard let audioData = try? Data(contentsOf: audioFile) else {
            log.debug("Failed to read audio file")
            return nil
        }

        guard let url = URL(string: baseURL) else {
            log.debug("Invalid custom ASR URL")
            return nil
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout(audioBytes: audioData.count)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var body = Data()
        let filename = audioFile.lastPathComponent
        let ext = audioFile.pathExtension.lowercased()
        let mime: String
        switch ext {
        case "ogg": mime = "audio/ogg"
        case "mp3": mime = "audio/mpeg"
        case "wav": mime = "audio/wav"
        case "m4a": mime = "audio/m4a"
        case "flac": mime = "audio/flac"
        default:    mime = "audio/wav"
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(model)\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body
        log.debug("Custom ASR request body size: \(body.count) bytes")

        let data: Data
        do {
            let (responseData, response) = try await session.data(for: request)
            data = responseData
            if let httpResponse = response as? HTTPURLResponse {
                log.debug("Custom ASR HTTP status: \(httpResponse.statusCode)")
                guard (200..<300).contains(httpResponse.statusCode) else { return nil }
            }
        } catch {
            log.debug("Custom ASR network error: \((error as NSError).code)")
            DispatchQueue.main.async {
                AppDelegate.showNotification(title: "Vox", message: "ASR network error: \((error as NSError).code)")
            }
            return nil
        }

        log.debug("Custom ASR response bytes=\(data.count)")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log.debug("Custom ASR failed to parse JSON")
            return nil
        }

        if json["error"] != nil {
            log.debug("Custom ASR API returned an error")
            DispatchQueue.main.async {
                AppDelegate.showNotification(title: "Vox", message: "ASR request failed. Check Settings.")
            }
            return nil
        }

        if let text = json["text"] as? String {
            let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
            log.debug("Custom ASR result characters=\(result.count)")
            if result.isEmpty {
                log.debug("Custom ASR returned empty result")
            }
            return result
        } else {
            log.debug("Custom ASR: no 'text' field in response")
            return nil
        }
    }
}

// MARK: - STTService

class STTService {
    static let shared = STTService()

    private let log = LogService.shared
    private let config = ConfigService.shared

    private var provider: STTProvider {
        switch config.asrProvider {
        case "qwen":
            return QwenASRProvider(apiKey: config.qwenASRApiKey ?? "")
        case "custom":
            if let custom = config.customASRConfig {
                return WhisperAPIProvider(baseURL: custom.baseURL, apiKey: custom.apiKey, model: custom.model)
            }
            log.debug("Custom ASR config missing, falling back to whisper")
            return WhisperLocalProvider(execPath: config.whisperExecPath, modelPath: config.whisperModelPath)
        default:
            return WhisperLocalProvider(execPath: config.whisperExecPath, modelPath: config.whisperModelPath)
        }
    }

    private let chunkDurationSeconds = 180

    func transcribe(audioFile: URL) async -> String {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioFile.path)[.size] as? Int) ?? 0
        log.debug("Audio file: \(audioFile.lastPathComponent), size: \(fileSize) bytes")

        let p = provider
        log.debug("Using STT provider: \(p.name)")

        let result: String
        if let maxBytes = p.maxAudioFileBytes, fileSize > maxBytes {
            log.debug("File \(fileSize) exceeds provider limit \(maxBytes), chunking")
            result = await transcribeChunked(audioFile: audioFile, provider: p)
        } else {
            result = await p.transcribe(audioFile: audioFile) ?? ""
        }

        // Hallucination filter (only for local whisper — cloud ASR doesn't hallucinate)
        if p.name == "whisper-local" {
            return Self.filterHallucination(result)
        }

        // Cloud providers: only filter truly empty results — short answers like "好"/"是" are legitimate.
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            log.debug("\(p.name) returned empty result")
            return ""
        }

        return result
    }

    // MARK: - Audio Chunking

    private func transcribeChunked(audioFile: URL, provider p: STTProvider) async -> String {
        let chunkDir = FileManager.default.temporaryDirectory.appendingPathComponent("vox-chunks-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: chunkDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: chunkDir)
        }

        let chunkPattern = chunkDir.appendingPathComponent("chunk-%03d.wav").path
        let splitSuccess = await splitAudio(input: audioFile.path, outputPattern: chunkPattern)
        guard splitSuccess else {
            log.debug("ffmpeg chunking failed; refusing an oversized partial request")
            return ""
        }

        let chunks = (try? FileManager.default.contentsOfDirectory(at: chunkDir, includingPropertiesForKeys: nil))?.filter {
            $0.pathExtension == "wav"
        }.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        log.debug("Split into \(chunks.count) chunks")

        return await Self.transcribeChunks(chunks, provider: p) { index, count in
            DispatchQueue.main.async {
                AppDelegate.showNotification(title: "Vox", message: "Could not transcribe segment \(index)/\(count) after retry. No partial text was pasted.")
            }
        }
    }

    // One failed segment invalidates the whole recording. Retry only that segment once.
    static func transcribeChunks(_ chunks: [URL], provider: STTProvider,
                                 onFailure: (Int, Int) -> Void) async -> String {
        guard !chunks.isEmpty else { onFailure(0, 0); return "" }
        var results: [String] = []
        for (index, chunk) in chunks.enumerated() {
            guard !Task.isCancelled else { return "" }
            var text = await provider.transcribe(audioFile: chunk)
            if text == nil, !Task.isCancelled { text = await provider.transcribe(audioFile: chunk) }
            guard !Task.isCancelled, let text = text else {
                onFailure(index + 1, chunks.count)
                return ""
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { results.append(trimmed) } // successful silence needs no retry
        }
        return results.joined(separator: " ")
    }

    private func splitAudio(input: String, outputPattern: String) async -> Bool {
        let result = await ProcessRunner.run(
            executable: STTService.resolveBinary(name: "ffmpeg", fallback: "/opt/homebrew/bin/ffmpeg"),
            arguments: ["-i", input, "-f", "segment", "-segment_time", "\(chunkDurationSeconds)", "-c", "copy", "-y", outputPattern],
            timeout: 120)
        return result.status == 0 && !result.stopped
    }

    /// Resolve a binary by checking standard Homebrew locations on both Apple Silicon (/opt/homebrew)
    /// and Intel (/usr/local), then /usr/bin, before falling back. Returns the first existing path.
    static func resolveBinary(name: String, fallback: String) -> String {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        let fm = FileManager.default
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        return fallback
    }

    // MARK: - Hallucination Filter

    static func filterHallucination(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(of: "♪", with: "")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.count < 2 { return "" }

        if trimmed.count > 2 {
            let chars = Set(trimmed)
            if chars.count == 1 { return "" }
        }

        let alwaysFilter = [
            "优优独播剧场", "YoYo Television", "Amara.org",
        ]
        for pattern in alwaysFilter {
            if trimmed.contains(pattern) {
                return ""
            }
        }

        if trimmed.count < 30 {
            let shortTextPatterns = [
                "字幕", "字幕由", "字幕组",
                "请不吝点赞", "订阅", "小铃铛", "感谢观看",
                "Thank you for watching", "Subscribe", "Like and subscribe",
                "Subtitles by", "翻译", "校对",
                "www.", "http", ".com", ".cn",
                "謝謝觀看", "歡迎訂閱", "下集预告",
                "Music",
            ]
            for pattern in shortTextPatterns {
                if trimmed.contains(pattern) {
                        return ""
                }
            }
        }

        return cleaned
    }
}
