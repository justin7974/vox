import Foundation

final class IntentService {
    static let shared = IntentService()

    private let log = LogService.shared
    private let llm = LLMService.shared
    private let actionService = ActionService.shared
    private let confidenceThreshold: Double = 0.7

    private init() {}

    // MARK: - Public API

    /// Match user text to an action. Returns nil if no match found.
    /// Layer 1: Regex fast path (< 1ms)
    /// Layer 2: LLM intent matching (200-2000ms)
    func match(text: String, context: ContextService.AppContext? = nil) async -> IntentMatch? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let actions = actionService.getActions()
        guard !actions.isEmpty else {
            log.warning("IntentService: No actions loaded")
            return nil
        }

        // Layer 1: Regex fast path
        if let regexMatch = regexMatch(text: trimmed, actions: actions) {
            log.info("IntentService: Regex match -> \(regexMatch.action.id) (conf: \(regexMatch.confidence))")
            return regexMatch
        }

        // Layer 2: LLM intent matching
        if llm.isConfigured {
            let llmMatch = await llmMatch(text: trimmed, actions: actions, context: context)
            if let match = llmMatch {
                log.info("IntentService: LLM match -> \(match.action.id) (conf: \(match.confidence))")
                if match.confidence >= confidenceThreshold {
                    return match
                } else {
                    log.info("IntentService: LLM confidence \(match.confidence) below threshold \(confidenceThreshold)")
                }
            } else {
                log.info("IntentService: LLM returned no match")
            }
        } else {
            log.debug("IntentService: LLM not configured, skipping Layer 2")
        }

        return nil
    }

    // MARK: - Layer 1: Regex Fast Path

    private func regexMatch(text: String, actions: [ActionDefinition]) -> IntentMatch? {
        let lower = text.lowercased()

        for action in actions {
            for trigger in action.triggers {
                let triggerLower = trigger.lowercased()

                // Check if text starts with or equals the trigger
                if lower == triggerLower {
                    // Exact match, no params (e.g. "静音", "锁屏", "剪贴板")
                    let params = extractSimpleParams(action: action, trigger: trigger, fullText: text)
                    return IntentMatch(action: action, params: params, confidence: 0.95)
                }

                if lower.hasPrefix(triggerLower) {
                    // Trigger at start with remaining text as param
                    let remaining = String(text.dropFirst(trigger.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !remaining.isEmpty {
                        let params = extractParamsFromRemaining(action: action, trigger: trigger, remaining: remaining)
                        return IntentMatch(action: action, params: params, confidence: 0.9)
                    }
                }

                // Check if trigger appears as a significant part of the text
                if lower.contains(triggerLower) && triggerLower.count >= 2 {
                    let remaining = lower.replacingOccurrences(of: triggerLower, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !remaining.isEmpty {
                        let params = extractParamsFromRemaining(action: action, trigger: trigger, remaining: remaining)
                        return IntentMatch(action: action, params: params, confidence: 0.85)
                    } else {
                        let params = extractSimpleParams(action: action, trigger: trigger, fullText: text)
                        return IntentMatch(action: action, params: params, confidence: 0.9)
                    }
                }
            }
        }

        return nil
    }

    private func extractSimpleParams(action: ActionDefinition, trigger: String, fullText: String) -> [String: String] {
        var params: [String: String] = [:]

        switch action.id {
        case "volume_control":
            let lower = trigger.lowercased()
            if lower.contains("静音") || lower.contains("mute") { params["action"] = "mute" }
            else if lower.contains("取消静音") || lower.contains("unmute") { params["action"] = "unmute" }
            else if lower.contains("调高") { params["action"] = "up" }
            else if lower.contains("调低") { params["action"] = "down" }
        case "do_not_disturb":
            let lower = trigger.lowercased()
            if lower.contains("开") { params["action"] = "on" }
            else if lower.contains("关") { params["action"] = "off" }
            else { params["action"] = "toggle" }
        default:
            break
        }

        return params
    }

    private func extractParamsFromRemaining(action: ActionDefinition, trigger: String, remaining: String) -> [String: String] {
        var params: [String: String] = [:]

        switch action.id {
        case "web_search":
            params["query"] = remaining
            // Detect engine from trigger
            let triggerLower = trigger.lowercased()
            if triggerLower.contains("youtube") || triggerLower.contains("油管") {
                params["engine"] = "youtube"
            } else if triggerLower.contains("github") {
                params["engine"] = "github"
            } else if triggerLower.contains("百度") {
                params["engine"] = "baidu"
            } else if triggerLower.contains("b站") || triggerLower.contains("bilibili") {
                params["engine"] = "bilibili"
            }
        case "launch_app", "kill_process":
            params["appName"] = remaining
        case "volume_control":
            let lower = trigger.lowercased()
            if lower.contains("调到") || lower.contains("volume") {
                params["action"] = "set"
                params["level"] = remaining.filter { $0.isNumber }
            } else if lower.contains("调高") {
                params["action"] = "up"
            } else if lower.contains("调低") {
                params["action"] = "down"
            }
        case "window_manage":
            params["position"] = remaining
        case "translate":
            params["targetLanguage"] = remaining
        case "text_modify", "selection_modify":
            params["instruction"] = remaining
        default:
            // Use first required param
            if let firstParam = action.params.first(where: { $0.required }) {
                params[firstParam.name] = remaining
            }
        }

        return params
    }

    // MARK: - Layer 2: LLM Intent Matching

    private func llmMatch(text: String, actions: [ActionDefinition], context: ContextService.AppContext?) async -> IntentMatch? {
        let systemPrompt = buildIntentSystemPrompt(actions: actions, context: context)
        let result = await llm.process(rawText: text, contextHint: nil, translateMode: false, customSystemPrompt: systemPrompt)

        // Parse LLM response as JSON
        return parseLLMResponse(result, actions: actions, originalText: text)
    }

    private func buildIntentSystemPrompt(actions: [ActionDefinition], context: ContextService.AppContext?) -> String {
        var prompt = """
        你是 Vox Launcher 的意图识别引擎。你的任务是分析用户的语音指令，匹配到正确的操作。

        ## 可用操作列表

        """

        for action in actions {
            let triggers = action.triggers.joined(separator: ", ")
            let paramDesc = action.params.map { "\($0.name)(\($0.type), \($0.required ? "必填" : "可选"))" }.joined(separator: ", ")
            prompt += """
            ### \(action.id): \(action.name)
            - 触发词: \(triggers)
            - 参数: \(paramDesc.isEmpty ? "无" : paramDesc)
            - 说明: \(action.description)

            """
        }

        prompt += """

        ## 匹配规则

        1. 优先精确匹配触发词
        2. 然后语义理解用户意图
        3. 从用户指令中提取参数
        4. confidence 为 0-1 的浮点数，表示匹配置信度
        5. 如果无法匹配任何操作，返回 action_id 为 "none"

        ## 输出格式

        严格输出 JSON，不要输出任何其他文字：
        {"action_id": "xxx", "params": {"key": "value"}, "confidence": 0.9}

        如果不匹配：
        {"action_id": "none", "params": {}, "confidence": 0.0}
        """

        if let ctx = context {
            prompt += "\n\n当前上下文：用户正在 \(ctx.appName) 中。"
            if let url = ctx.url {
                prompt += " 当前网页: \(url)"
            }
        }

        return prompt
    }

    private func parseLLMResponse(_ response: String, actions: [ActionDefinition], originalText: String) -> IntentMatch? {
        // Try to extract JSON from the response
        let jsonString = extractJSON(from: response)
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log.warning("IntentService: Failed to parse LLM response as JSON: \(response.prefix(200))")
            return nil
        }

        guard let actionId = json["action_id"] as? String, actionId != "none" else {
            return nil
        }

        let confidence = json["confidence"] as? Double ?? 0.0
        guard confidence > 0 else { return nil }

        guard let action = actionService.action(byId: actionId) else {
            log.warning("IntentService: LLM returned unknown action_id: \(actionId)")
            return nil
        }

        var params: [String: String] = [:]
        if let rawParams = json["params"] as? [String: Any] {
            for (key, value) in rawParams {
                params[key] = "\(value)"
            }
        }

        return IntentMatch(action: action, params: params, confidence: confidence)
    }

    private func extractJSON(from text: String) -> String {
        // Try to find JSON object in the response
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // If already valid JSON
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") {
            return trimmed
        }

        // Try to find JSON within markdown code blocks
        if let start = trimmed.range(of: "```json"),
           let end = trimmed.range(of: "```", range: start.upperBound..<trimmed.endIndex) {
            return String(trimmed[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Try to find first { ... } block
        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}") {
            return String(trimmed[start...end])
        }

        return trimmed
    }
}
