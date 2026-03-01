import Foundation

// MARK: - Protocol

protocol STTProvider {
    var name: String { get }
    func transcribe(audioFile: URL) -> String
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

    func transcribe(audioFile: URL) -> String {
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

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log.debug("Whisper failed: \(error)")
            return ""
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        return parseWhisperOutput(output)
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
    private let log = LogService.shared
    private let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func transcribe(audioFile: URL) -> String {
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

        let semaphore = DispatchSemaphore(value: 0)
        var result = ""

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error = error {
                log.debug("Qwen ASR network error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    AppDelegate.showNotification(title: "Vox", message: "ASR network error: \(error.localizedDescription)")
                }
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                log.debug("Qwen ASR HTTP status: \(httpResponse.statusCode)")
            }

            guard let data = data else {
                log.debug("Qwen ASR no response data")
                return
            }

            let rawResponse = String(data: data, encoding: .utf8) ?? "???"
            log.debug("Qwen ASR raw response: \(String(rawResponse.prefix(500)))")

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                log.debug("Qwen ASR failed to parse JSON")
                return
            }

            if let errorInfo = json["error"] as? [String: Any],
               let message = errorInfo["message"] as? String {
                log.debug("Qwen ASR API error: \(message)")
                let shortMsg = message.contains("invalid_api_key") ? "Invalid API key. Check Settings." : "ASR API error."
                DispatchQueue.main.async {
                    AppDelegate.showNotification(title: "Vox", message: shortMsg)
                }
                return
            }

            if let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String {
                result = content.trimmingCharacters(in: .whitespacesAndNewlines)
                log.debug("Qwen ASR result: [\(result)]")
            } else {
                log.debug("Qwen ASR: no content in response (unexpected format)")
            }
        }

        task.resume()
        semaphore.wait()

        if result.isEmpty {
            log.debug("Qwen ASR returned empty result")
        }

        return result
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

    func transcribe(audioFile: URL) -> String {
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

        let semaphore = DispatchSemaphore(value: 0)
        var result = ""

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error = error {
                log.debug("Custom ASR network error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    AppDelegate.showNotification(title: "Vox", message: "ASR network error: \(error.localizedDescription)")
                }
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                log.debug("Custom ASR HTTP status: \(httpResponse.statusCode)")
            }

            guard let data = data else {
                log.debug("Custom ASR no response data")
                return
            }

            let rawResponse = String(data: data, encoding: .utf8) ?? "???"
            log.debug("Custom ASR raw response: \(String(rawResponse.prefix(500)))")

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                log.debug("Custom ASR failed to parse JSON")
                return
            }

            if let errorInfo = json["error"] as? [String: Any],
               let message = errorInfo["message"] as? String {
                log.debug("Custom ASR API error: \(message)")
                DispatchQueue.main.async {
                    AppDelegate.showNotification(title: "Vox", message: "ASR error: \(message)")
                }
                return
            }

            if let text = json["text"] as? String {
                result = text.trimmingCharacters(in: .whitespacesAndNewlines)
                log.debug("Custom ASR result: [\(result)]")
            } else {
                log.debug("Custom ASR: no 'text' field in response")
            }
        }

        task.resume()
        semaphore.wait()

        if result.isEmpty {
            log.debug("Custom ASR returned empty result")
        }

        return result
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

    func transcribe(audioFile: URL) -> String {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioFile.path)[.size] as? Int) ?? 0
        log.debug("Audio file: \(audioFile.lastPathComponent), size: \(fileSize) bytes")

        let p = provider
        log.debug("Using STT provider: \(p.name)")

        let result = p.transcribe(audioFile: audioFile)

        // Hallucination filter (only for local whisper — cloud ASR doesn't hallucinate)
        if p.name == "whisper-local" {
            return filterHallucination(result)
        }

        // Cloud providers: only filter truly empty/whitespace
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 2 {
            log.debug("\(p.name) result too short, discarding: [\(result)]")
            return ""
        }

        return result
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
