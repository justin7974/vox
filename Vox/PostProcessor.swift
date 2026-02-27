import Foundation

enum PostProcessor {

    // MARK: - Debug logging

    private static func debugLog(_ msg: String) {
        let logPath = NSHomeDirectory() + "/.voiceinput/debug.log"
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[PP \(ts)] \(msg)\n"
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

    // MARK: - System Prompt (based on Typeless architecture analysis)

    private static let systemPrompt = """
    你是一位语音转文字的语义重构引擎。将口语化的语音转录重构为用户真正想表达的书面文字。

    ## 核心处理流程

    ### 第一步：清理
    - 剔除所有填充词和语气词（嗯、啊、那个、就是说、然后呢、对吧、你知道吗、就是、这个、额、呃、所以说、反正）
    - 口头重复只保留一次（"就是就是"→一次）
    - 自我纠正时只保留最终表达（"周三...不对周四"→"周四"；"三百万...啊不是五百万"→"500万"）

    ### 第二步：纠错
    - 修正 ASR 同音/近音错误，结合上下文推断正确词汇（如"投产"→"投资"、"鸿杉"→"红杉"、"平替"→"平替"）
    - 英文专有名词修正大小写：AI、GitHub、Claude、GPT、iPhone、MiniMax、Term Sheet、Cap Table、OKR、KPI、LLM、API

    ### 第三步：中英文处理
    - 用户说英文时保持英文，不翻译（"这个 term sheet"保持原样）
    - 中英文之间加空格（"用Claude写代码"→"用 Claude 写代码"）

    ### 第四步：格式化
    - 添加合适的中文标点（逗号、句号、问号、感叹号、顿号）
    - 口语数字转书面格式（"三百万"→"300万"、"百分之五"→"5%"、"两千零二十六年"→"2026年"）
    - 多要点自动分行：当用户说"第一"/"首先"/"一是"等列举信号词时，用换行分点呈现
    - 长段落按语义自然分段（超过3句话时考虑分段）

    ### 第五步：语气校准
    - 保持用户的原始语气和意图
    - 不过度正式化口语表达（"挺好的"不改成"非常好"）
    - 不添加用户没说的内容
    - 不改变用户的观点和立场

    ## 输出规则
    - 直接输出最终文字，无任何前缀、解释或引号包裹
    - 保持原意为最高优先级，宁可少改不多改
    """

    // MARK: - Config

    enum APIFormat {
        case anthropic  // /messages endpoint: x-api-key header, system field, content[].text response
        case openai     // /chat/completions endpoint: Bearer auth, system in messages, choices[].message.content response
    }

    private struct APIConfig {
        let baseURL: String
        let apiKey: String
        let model: String
        let userContext: String
        let format: APIFormat
    }

    private static func detectFormat(baseURL: String, explicit: String?) -> APIFormat {
        if let explicit = explicit {
            if explicit == "openai" { return .openai }
            if explicit == "anthropic" { return .anthropic }
        }
        // Auto-detect from URL path
        if baseURL.contains("/chat/completions") { return .openai }
        return .anthropic  // /messages or anything else defaults to Anthropic
    }

    private static func loadConfig() -> APIConfig? {
        let configPath = NSHomeDirectory() + "/.voiceinput/config.json"
        guard let data = FileManager.default.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let provider = json["provider"] as? String,
              let providerConfig = json[provider] as? [String: Any],
              let baseURL = providerConfig["baseURL"] as? String,
              let apiKey = providerConfig["apiKey"] as? String,
              let model = providerConfig["model"] as? String else {
            NSLog("Vox: Failed to load config from ~/.voiceinput/config.json")
            return nil
        }

        let userContext = json["userContext"] as? String ?? ""
        let explicitFormat = providerConfig["format"] as? String
        let format = detectFormat(baseURL: baseURL, explicit: explicitFormat)
        return APIConfig(baseURL: baseURL, apiKey: apiKey, model: model, userContext: userContext, format: format)
    }

    private static func buildSystemPrompt(userContext: String) -> String {
        var prompt = systemPrompt
        if !userContext.isEmpty {
            prompt += "\n\n用户背景：\(userContext)"
        }
        return prompt
    }

    // MARK: - API Call

    /// Whether LLM post-processing is configured and active
    static var isConfigured: Bool {
        return loadConfig() != nil
    }

    static func process(rawText: String) -> String {
        guard let config = loadConfig() else {
            debugLog("No LLM config, skipping post-processing")
            return rawText
        }

        debugLog("Using API: \(config.baseURL) model: \(config.model)")
        let result = callAPI(rawText: rawText, config: config)
        if result.isEmpty {
            debugLog("LLM failed, returning raw text")
            DispatchQueue.main.async {
                AppDelegate.showNotification(title: "Vox", message: "LLM post-processing failed. Using raw transcription.")
            }
            return rawText
        }
        return result
    }

    private static func callAPI(rawText: String, config: APIConfig) -> String {
        guard let url = URL(string: config.baseURL) else {
            debugLog("Invalid API URL: \(config.baseURL)")
            return ""
        }

        let finalPrompt = buildSystemPrompt(userContext: config.userContext)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any]

        switch config.format {
        case .anthropic:
            debugLog("Using Anthropic format")
            request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": config.model,
                "max_tokens": 2048,
                "system": finalPrompt,
                "messages": [
                    ["role": "user", "content": rawText]
                ]
            ]

        case .openai:
            debugLog("Using OpenAI format")
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            body = [
                "model": config.model,
                "max_tokens": 2048,
                "enable_thinking": false,  // Disable thinking for Qwen 3.5+ models (26s → 1s)
                "messages": [
                    ["role": "system", "content": finalPrompt],
                    ["role": "user", "content": rawText]
                ]
            ]
        }

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            debugLog("Failed to serialize request body")
            return ""
        }
        request.httpBody = httpBody

        let semaphore = DispatchSemaphore(value: 0)
        var result = ""

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error = error {
                debugLog("API error: \(error.localizedDescription)")
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                debugLog("API HTTP status: \(httpResponse.statusCode)")
            }

            guard let data = data else {
                debugLog("No response data")
                return
            }

            let rawResponse = String(data: data, encoding: .utf8) ?? "???"
            debugLog("API raw response: \(String(rawResponse.prefix(500)))")

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                debugLog("Failed to parse JSON")
                return
            }

            if let errorInfo = json["error"] as? [String: Any],
               let message = errorInfo["message"] as? String {
                debugLog("API returned error: \(message)")
                return
            }

            // Parse response based on format
            switch config.format {
            case .anthropic:
                if let content = json["content"] as? [[String: Any]] {
                    // Find the "text" type block (skip "thinking" blocks from providers like MiniMax)
                    let textBlock = content.first(where: { ($0["type"] as? String) == "text" }) ?? content.first
                    if let text = textBlock?["text"] as? String {
                        result = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        debugLog("API result: [\(result)]")
                    } else {
                        debugLog("Could not extract text from Anthropic content blocks")
                    }
                } else {
                    debugLog("Could not extract content array from Anthropic response")
                }

            case .openai:
                if let choices = json["choices"] as? [[String: Any]],
                   let message = choices.first?["message"] as? [String: Any],
                   let text = message["content"] as? String {
                    result = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    debugLog("API result: [\(result)]")
                } else {
                    debugLog("Could not extract choices[0].message.content from OpenAI response")
                }
            }
        }

        task.resume()
        semaphore.wait()

        return result
    }

}
