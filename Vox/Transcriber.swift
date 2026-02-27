import Foundation

enum Transcriber {
    private static let whisperPath = "/opt/homebrew/bin/whisper-cli"
    private static let modelPath = NSHomeDirectory() + "/.cache/whisper-cpp/ggml-large-v3-turbo.bin"

    // MARK: - Config

    private struct ASRConfig {
        let provider: String  // "whisper" or "qwen"
        let apiKey: String
    }

    private static func loadASRConfig() -> ASRConfig {
        let configPath = NSHomeDirectory() + "/.voiceinput/config.json"
        guard let data = FileManager.default.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let asr = json["asr"] as? String else {
            return ASRConfig(provider: "whisper", apiKey: "")
        }

        if asr == "qwen", let qwenConfig = json["qwen-asr"] as? [String: Any],
           let apiKey = qwenConfig["apiKey"] as? String {
            return ASRConfig(provider: "qwen", apiKey: apiKey)
        }

        return ASRConfig(provider: "whisper", apiKey: "")
    }

    // MARK: - Public API

    static func transcribe(audioFile: URL) -> String {
        let config = loadASRConfig()
        if config.provider == "qwen" {
            NSLog("Vox: Using Qwen ASR")
            return transcribeWithQwen(audioFile: audioFile, apiKey: config.apiKey)
        } else {
            NSLog("Vox: Using local Whisper")
            return transcribeWithWhisper(audioFile: audioFile)
        }
    }

    // MARK: - Qwen ASR (Alibaba DashScope)

    private static func transcribeWithQwen(audioFile: URL, apiKey: String) -> String {
        guard let audioData = try? Data(contentsOf: audioFile) else {
            NSLog("Vox: Failed to read audio file")
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
            NSLog("Vox: Failed to serialize Qwen ASR request")
            return ""
        }
        request.httpBody = httpBody

        let semaphore = DispatchSemaphore(value: 0)
        var result = ""

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error = error {
                NSLog("Vox: Qwen ASR error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    AppDelegate.showNotification(title: "Vox", message: "ASR network error: \(error.localizedDescription)")
                }
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                NSLog("Vox: Qwen ASR HTTP status: \(httpResponse.statusCode)")
            }

            guard let data = data else {
                NSLog("Vox: Qwen ASR no response data")
                return
            }

            let rawResponse = String(data: data, encoding: .utf8) ?? "???"
            NSLog("Vox: Qwen ASR raw response: \(String(rawResponse.prefix(500)))")

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("Vox: Qwen ASR failed to parse JSON")
                return
            }

            // Check for error
            if let errorInfo = json["error"] as? [String: Any],
               let message = errorInfo["message"] as? String {
                NSLog("Vox: Qwen ASR API error: \(message)")
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
                NSLog("Vox: Qwen ASR result: [\(result)]")
            }
        }

        task.resume()
        semaphore.wait()

        if isHallucination(result) {
            NSLog("Vox: Filtered hallucination: \(result)")
            return ""
        }

        return result
    }

    // MARK: - Local Whisper

    private static func transcribeWithWhisper(audioFile: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
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
            NSLog("Vox: Whisper failed: \(error)")
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
            NSLog("Vox: Filtered hallucination: \(result)")
            return ""
        }

        return result
    }

    // MARK: - Hallucination Filter

    private static func isHallucination(_ text: String) -> Bool {
        let hallucinations = [
            "优优独播剧场", "YoYo Television", "字幕", "字幕由",
            "请不吝点赞", "订阅", "小铃铛", "感谢观看",
            "Thank you for watching", "Subscribe", "Like and subscribe",
            "Subtitles by", "字幕组", "翻译", "校对",
            "www.", "http", ".com", ".cn",
            "謝謝觀看", "歡迎訂閱", "下集预告",
            "Music", "♪", "Amara.org",
        ]

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.count < 2 { return true }

        for pattern in hallucinations {
            if trimmed.contains(pattern) { return true }
        }

        if trimmed.count > 2 {
            let chars = Set(trimmed)
            if chars.count == 1 { return true }
        }

        return false
    }
}
