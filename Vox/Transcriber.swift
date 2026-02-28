import Foundation

enum Transcriber {
    private static let defaultWhisperPath = "/opt/homebrew/bin/whisper-cli"
    private static let defaultModelPath = NSHomeDirectory() + "/.cache/whisper-cpp/ggml-large-v3-turbo.bin"

    /// Write to debug.log for persistent diagnostics (NSLog goes to system console which is hard to retrieve)
    private static func debugLog(_ msg: String) {
        let logPath = NSHomeDirectory() + "/.vox/debug.log"
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[ASR \(ts)] \(msg)\n"
        NSLog("Vox: \(msg)")
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let fh = FileHandle(forWritingAtPath: logPath) {
                    fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: logPath, contents: data)
            }
        }
    }

    // MARK: - Config

    private struct ASRConfig {
        let provider: String  // "whisper", "qwen", or "custom"
        let apiKey: String
        let baseURL: String       // custom cloud ASR endpoint
        let model: String         // custom cloud ASR model name
        let whisperExec: String   // local whisper executable path
        let whisperModel: String  // local whisper model file path
    }

    private static func loadASRConfig() -> ASRConfig {
        let configPath = NSHomeDirectory() + "/.vox/config.json"
        guard let data = FileManager.default.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let asr = json["asr"] as? String else {
            return ASRConfig(provider: "whisper", apiKey: "", baseURL: "", model: "",
                             whisperExec: defaultWhisperPath, whisperModel: defaultModelPath)
        }

        if asr == "qwen", let qwenConfig = json["qwen-asr"] as? [String: Any],
           let apiKey = qwenConfig["apiKey"] as? String {
            return ASRConfig(provider: "qwen", apiKey: apiKey, baseURL: "", model: "",
                             whisperExec: defaultWhisperPath, whisperModel: defaultModelPath)
        }

        if asr == "custom", let customConfig = json["custom-asr"] as? [String: Any],
           let baseURL = customConfig["baseURL"] as? String,
           let apiKey = customConfig["apiKey"] as? String,
           let model = customConfig["model"] as? String {
            return ASRConfig(provider: "custom", apiKey: apiKey, baseURL: baseURL, model: model,
                             whisperExec: defaultWhisperPath, whisperModel: defaultModelPath)
        }

        // Local whisper — read custom paths or fall back to defaults
        let whisperConfig = json["whisper"] as? [String: Any]
        let exec = whisperConfig?["executablePath"] as? String ?? defaultWhisperPath
        let model = whisperConfig?["modelPath"] as? String ?? defaultModelPath
        return ASRConfig(provider: "whisper", apiKey: "", baseURL: "", model: "",
                         whisperExec: exec, whisperModel: model)
    }

    // MARK: - Public API

    static func transcribe(audioFile: URL) -> String {
        let config = loadASRConfig()
        // Log audio file size for diagnostics
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioFile.path)[.size] as? Int) ?? 0
        debugLog("Audio file: \(audioFile.lastPathComponent), size: \(fileSize) bytes")

        switch config.provider {
        case "qwen":
            debugLog("Using Qwen ASR")
            return transcribeWithQwen(audioFile: audioFile, apiKey: config.apiKey)
        case "custom":
            debugLog("Using custom ASR: \(config.baseURL) model: \(config.model)")
            return transcribeWithWhisperAPI(audioFile: audioFile, baseURL: config.baseURL,
                                            apiKey: config.apiKey, model: config.model)
        default:
            debugLog("Using local Whisper: \(config.whisperExec)")
            return transcribeWithWhisper(audioFile: audioFile, execPath: config.whisperExec,
                                         modelPath: config.whisperModel)
        }
    }

    // MARK: - Qwen ASR (Alibaba DashScope)

    private static func transcribeWithQwen(audioFile: URL, apiKey: String) -> String {
        guard let audioData = try? Data(contentsOf: audioFile) else {
            debugLog("Failed to read audio file")
            return ""
        }

        let base64Audio = audioData.base64EncodedString()

        // Determine MIME type from file extension
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
            debugLog("Failed to serialize Qwen ASR request")
            return ""
        }
        request.httpBody = httpBody
        debugLog("Qwen ASR request body size: \(httpBody.count) bytes")

        let semaphore = DispatchSemaphore(value: 0)
        var result = ""

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error = error {
                debugLog("Qwen ASR network error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    AppDelegate.showNotification(title: "Vox", message: "ASR network error: \(error.localizedDescription)")
                }
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                debugLog("Qwen ASR HTTP status: \(httpResponse.statusCode)")
            }

            guard let data = data else {
                debugLog("Qwen ASR no response data")
                return
            }

            let rawResponse = String(data: data, encoding: .utf8) ?? "???"
            debugLog("Qwen ASR raw response: \(String(rawResponse.prefix(500)))")

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                debugLog("Qwen ASR failed to parse JSON")
                return
            }

            // Check for error
            if let errorInfo = json["error"] as? [String: Any],
               let message = errorInfo["message"] as? String {
                debugLog("Qwen ASR API error: \(message)")
                let shortMsg = message.contains("invalid_api_key") ? "Invalid API key. Check Settings." : "ASR API error."
                DispatchQueue.main.async {
                    AppDelegate.showNotification(title: "Vox", message: shortMsg)
                }
                return
            }

            // Extract content from OpenAI-compatible response
            if let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String {
                result = content.trimmingCharacters(in: .whitespacesAndNewlines)
                debugLog("Qwen ASR result: [\(result)]")
            } else {
                debugLog("Qwen ASR: no content in response (unexpected format)")
            }
        }

        task.resume()
        semaphore.wait()

        if result.isEmpty {
            debugLog("Qwen ASR returned empty result")
        }

        // Qwen cloud ASR does not hallucinate like Whisper — skip hallucination filter
        // Only filter truly empty/whitespace results
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 2 {
            debugLog("Qwen ASR result too short, discarding: [\(result)]")
            return ""
        }

        return result
    }

    // MARK: - Custom Cloud ASR (OpenAI Whisper API compatible)

    private static func transcribeWithWhisperAPI(audioFile: URL, baseURL: String, apiKey: String, model: String) -> String {
        guard let audioData = try? Data(contentsOf: audioFile) else {
            debugLog("Failed to read audio file")
            return ""
        }

        guard let url = URL(string: baseURL) else {
            debugLog("Invalid custom ASR URL: \(baseURL)")
            return ""
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // Build multipart form body
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

        // file field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        // model field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(model)\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body
        debugLog("Custom ASR request: \(baseURL), model: \(model), body size: \(body.count) bytes")

        let semaphore = DispatchSemaphore(value: 0)
        var result = ""

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error = error {
                debugLog("Custom ASR network error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    AppDelegate.showNotification(title: "Vox", message: "ASR network error: \(error.localizedDescription)")
                }
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                debugLog("Custom ASR HTTP status: \(httpResponse.statusCode)")
            }

            guard let data = data else {
                debugLog("Custom ASR no response data")
                return
            }

            let rawResponse = String(data: data, encoding: .utf8) ?? "???"
            debugLog("Custom ASR raw response: \(String(rawResponse.prefix(500)))")

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                debugLog("Custom ASR failed to parse JSON")
                return
            }

            if let errorInfo = json["error"] as? [String: Any],
               let message = errorInfo["message"] as? String {
                debugLog("Custom ASR API error: \(message)")
                DispatchQueue.main.async {
                    AppDelegate.showNotification(title: "Vox", message: "ASR error: \(message)")
                }
                return
            }

            // Standard Whisper API response: {"text": "..."}
            if let text = json["text"] as? String {
                result = text.trimmingCharacters(in: .whitespacesAndNewlines)
                debugLog("Custom ASR result: [\(result)]")
            } else {
                debugLog("Custom ASR: no 'text' field in response")
            }
        }

        task.resume()
        semaphore.wait()

        if result.isEmpty {
            debugLog("Custom ASR returned empty result")
        }

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 2 {
            debugLog("Custom ASR result too short, discarding: [\(result)]")
            return ""
        }

        return result
    }

    // MARK: - Local Whisper

    private static func transcribeWithWhisper(audioFile: URL, execPath: String, modelPath: String) -> String {
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
            debugLog("Whisper failed: \(error)")
            return ""
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        return parseWhisperOutput(output)
    }

    private static func parseWhisperOutput(_ output: String) -> String {
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

        let result = textParts.joined(separator: "")

        if isHallucination(result) {
            debugLog("Filtered hallucination: [\(result)]")
            return ""
        }

        return result
    }

    // MARK: - Hallucination Filter

    private static func isHallucination(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Too short to be real speech
        if trimmed.count < 2 { return true }

        // Single repeated character
        if trimmed.count > 2 {
            let chars = Set(trimmed)
            if chars.count == 1 { return true }
        }

        // Patterns that are ALWAYS hallucinations regardless of text length
        let alwaysFilter = [
            "优优独播剧场", "YoYo Television", "Amara.org",
            "♪",
        ]
        for pattern in alwaysFilter {
            if trimmed.contains(pattern) { return true }
        }

        // Patterns that only indicate hallucination in SHORT text (< 30 chars)
        // Whisper hallucinates short subtitle credits like "字幕由xxx翻译" or "感谢观看"
        // but real speech can naturally contain words like "翻译", "订阅" in longer sentences
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
                if trimmed.contains(pattern) { return true }
            }
        }

        return false
    }
}
