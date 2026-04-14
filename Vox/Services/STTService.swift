import Foundation

// MARK: - Protocol

protocol STTProvider {
    var name: String { get }
    var maxAudioFileBytes: Int? { get }
    func transcribe(audioFile: URL) async -> String
}

extension STTProvider {
    var maxAudioFileBytes: Int? { nil }
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

    func transcribe(audioFile: URL) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: execPath)
        process.arguments = [
            "-m", modelPath,
            "-l", "zh",
            "-t", "4",
            "--no-timestamps",
            "-f", audioFile.path
        ]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        // Drain stderr in parallel so whisper-cli doesn't block on a full pipe buffer.
        let errorPipe = Pipe()
        process.standardError = errorPipe
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                errorPipe.fileHandleForReading.readabilityHandler = nil
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: self.parseWhisperOutput(output))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                self.log.debug("Whisper failed: \(error)")
                continuation.resume(returning: "")
            }
        }
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

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func transcribe(audioFile: URL) async -> String {
        guard let audioData = try? Data(contentsOf: audioFile) else {
            log.debug("Failed to read audio file")
            return ""
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
            return ""
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
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
            return ""
        }
        request.httpBody = httpBody
        log.debug("Qwen ASR request body size: \(httpBody.count) bytes")

        let data: Data
        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            data = responseData
            if let httpResponse = response as? HTTPURLResponse {
                log.debug("Qwen ASR HTTP status: \(httpResponse.statusCode)")
            }
        } catch {
            log.debug("Qwen ASR network error: \(error.localizedDescription)")
            DispatchQueue.main.async {
                AppDelegate.showNotification(title: "Vox", message: "ASR network error: \(error.localizedDescription)")
            }
            return ""
        }

        let rawResponse = String(data: data, encoding: .utf8) ?? "???"
        log.debug("Qwen ASR raw response: \(String(rawResponse.prefix(500)))")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log.debug("Qwen ASR failed to parse JSON")
            return ""
        }

        if let errorInfo = json["error"] as? [String: Any],
           let message = errorInfo["message"] as? String {
            log.debug("Qwen ASR API error: \(message)")
            let shortMsg = message.contains("invalid_api_key") ? "Invalid API key. Check Settings." : "ASR API error."
            DispatchQueue.main.async {
                AppDelegate.showNotification(title: "Vox", message: shortMsg)
            }
            return ""
        }

        if let choices = json["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let content = message["content"] as? String {
            let result = content.trimmingCharacters(in: .whitespacesAndNewlines)
            log.debug("Qwen ASR result: [\(result)]")
            if result.isEmpty {
                log.debug("Qwen ASR returned empty result")
            }
            return result
        } else {
            log.debug("Qwen ASR: no content in response (unexpected format)")
            return ""
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

    init(baseURL: String, apiKey: String, model: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }

    func transcribe(audioFile: URL) async -> String {
        guard let audioData = try? Data(contentsOf: audioFile) else {
            log.debug("Failed to read audio file")
            return ""
        }

        guard let url = URL(string: baseURL) else {
            log.debug("Invalid custom ASR URL: \(baseURL)")
            return ""
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
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
        log.debug("Custom ASR request: \(baseURL), model: \(model), body size: \(body.count) bytes")

        let data: Data
        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            data = responseData
            if let httpResponse = response as? HTTPURLResponse {
                log.debug("Custom ASR HTTP status: \(httpResponse.statusCode)")
            }
        } catch {
            log.debug("Custom ASR network error: \(error.localizedDescription)")
            DispatchQueue.main.async {
                AppDelegate.showNotification(title: "Vox", message: "ASR network error: \(error.localizedDescription)")
            }
            return ""
        }

        let rawResponse = String(data: data, encoding: .utf8) ?? "???"
        log.debug("Custom ASR raw response: \(String(rawResponse.prefix(500)))")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log.debug("Custom ASR failed to parse JSON")
            return ""
        }

        if let errorInfo = json["error"] as? [String: Any],
           let message = errorInfo["message"] as? String {
            log.debug("Custom ASR API error: \(message)")
            DispatchQueue.main.async {
                AppDelegate.showNotification(title: "Vox", message: "ASR error: \(message)")
            }
            return ""
        }

        if let text = json["text"] as? String {
            let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
            log.debug("Custom ASR result: [\(result)]")
            if result.isEmpty {
                log.debug("Custom ASR returned empty result")
            }
            return result
        } else {
            log.debug("Custom ASR: no 'text' field in response")
            return ""
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
            result = await p.transcribe(audioFile: audioFile)
        }

        // Hallucination filter (only for local whisper — cloud ASR doesn't hallucinate)
        if p.name == "whisper-local" {
            return filterHallucination(result)
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
            log.debug("ffmpeg chunking failed, falling back to single request")
            return await p.transcribe(audioFile: audioFile)
        }

        let chunks = (try? FileManager.default.contentsOfDirectory(at: chunkDir, includingPropertiesForKeys: nil))?.filter {
            $0.pathExtension == "wav"
        }.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        log.debug("Split into \(chunks.count) chunks")

        var results: [String] = []
        for (i, chunk) in chunks.enumerated() {
            let chunkSize = (try? FileManager.default.attributesOfItem(atPath: chunk.path)[.size] as? Int) ?? 0
            log.debug("Transcribing chunk \(i+1)/\(chunks.count), size: \(chunkSize) bytes")
            let text = await p.transcribe(audioFile: chunk)
            if !text.isEmpty {
                results.append(text)
            }
        }

        // Use a space separator: Chinese segments still read fine with a space, but English segments
        // would otherwise collide ("meetingfinished" instead of "meeting finished").
        let combined = results.joined(separator: " ")
        log.debug("Chunked transcription done: \(results.count) segments, \(combined.count) chars")
        return combined
    }

    private func splitAudio(input: String, outputPattern: String) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: STTService.resolveBinary(name: "ffmpeg", fallback: "/opt/homebrew/bin/ffmpeg"))
        process.arguments = [
            "-i", input,
            "-f", "segment",
            "-segment_time", "\(chunkDurationSeconds)",
            "-c", "copy",
            "-y",
            outputPattern
        ]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Drain both pipes so ffmpeg doesn't stall on a full buffer for a long recording.
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: proc.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                self.log.debug("ffmpeg split failed: \(error)")
                continuation.resume(returning: false)
            }
        }
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

    private func filterHallucination(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.count < 2 { return "" }

        if trimmed.count > 2 {
            let chars = Set(trimmed)
            if chars.count == 1 { return "" }
        }

        let alwaysFilter = [
            "优优独播剧场", "YoYo Television", "Amara.org",
            "♪",
        ]
        for pattern in alwaysFilter {
            if trimmed.contains(pattern) {
                log.debug("Filtered hallucination: [\(trimmed)]")
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
                    log.debug("Filtered hallucination: [\(trimmed)]")
                    return ""
                }
            }
        }

        return text
    }
}
