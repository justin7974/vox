import Foundation

final class IntentService {
    static let shared = IntentService()

    private let log = LogService.shared
    private let llm = LLMService.shared
    private let actionService = ActionService.shared

    private init() {}

    // MARK: - Public API

    /// Match user voice text to an action via LLM.
    /// All intent recognition is handled by the LLM — no regex matching.
    /// The prompt is dynamically built from action .md files.
    func match(text: String, context: ContextService.AppContext? = nil) async -> IntentMatch? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard llm.isConfigured else {
            log.warning("IntentService: LLM not configured, cannot match intent")
            return nil
        }

        let actions = actionService.getActions()
        guard !actions.isEmpty else {
            log.warning("IntentService: No actions loaded")
            return nil
        }

        let systemPrompt = buildPrompt(actions: actions, context: context)
        log.debug("IntentService: Sending to LLM: '\(trimmed)'")

        let response = await llm.process(
            rawText: trimmed,
            customSystemPrompt: systemPrompt
        )

        guard let match = parseResponse(response, actions: actions) else {
            log.info("IntentService: No match for '\(trimmed)'")
            return nil
        }

        log.info("IntentService: Matched '\(trimmed)' -> \(match.action.id) (conf: \(match.confidence))")
        return match
    }

    // MARK: - Prompt Generation

    /// Build the intent recognition prompt from action definitions.
    /// This is the single source of truth — edit .md files to change behavior.
    private func buildPrompt(actions: [ActionDefinition], context: ContextService.AppContext?) -> String {
        var prompt = """
        你是 Vox 语音指令路由器。用户通过语音发出指令，经 ASR 转写后交给你判断意图。

        你的唯一任务：理解用户意图 → 匹配操作 → 提取参数 → 返回 JSON。

        ## 可用操作

        """

        for action in actions {
            let paramList = action.params.map { p in
                "\(p.name): \(p.type)\(p.required ? "" : ", 可选")"
            }.joined(separator: "; ")

            prompt += """
            **\(action.id)** — \(action.name)
            \(action.description)
            参数: \(paramList.isEmpty ? "无" : paramList)

            """
        }

        // Installed apps for launch_app / kill_process recognition
        let apps = actionService.installedAppNames
        if !apps.isEmpty {
            prompt += """

            ## 已安装应用
            \(apps.joined(separator: ", "))

            """
        }

        prompt += """

        ## 规则

        ### 口语处理
        忽略所有口语前缀（帮我、请、我想、能不能、麻烦 等），聚焦核心意图。

        ### ASR 纠错（极其重要）
        语音转文字经常出错，你必须根据已安装应用列表智能纠正。常见错误模式：
        - 发音相似：cloud → Claude, dress → Drafts, know → Notes, car → Kar, chrome → Chrome
        - 缺字少字：claud → Claude, draf → Drafts, safa → Safari
        - 中英混淆：克劳德 → Claude, 飞书 → Feishu
        - 大小写丢失：claude → Claude, safari → Safari
        收到疑似应用名时，始终在已安装列表中找发音最接近的匹配。宁可猜测匹配也不要返回 none。

        ### launch_app / kill_process
        appName 必须是已安装列表中的真实应用名（区分大小写）。
        中文别名：浏览器→Safari、终端→Terminal、备忘录→Notes、微信→WeChat、设置→System Settings、邮件→Mail、日历→Calendar、计算器→Calculator、文件管理器→Finder

        ### web_search vs open_url
        区分"搜索"和"打开网站"：
        - "在YouTube搜索xxx" → web_search（有搜索意图）
        - "打开YouTube" → open_url（只想打开网站）
        - "搜索xxx" → web_search
        - "打开GitHub" → open_url

        引擎检测：
        - YouTube/油管/看视频 → engine: "youtube"
        - B站/bilibili/哔哩哔哩 → engine: "bilibili"
        - GitHub → engine: "github"
        - 百度 → engine: "baidu"
        - 知乎 → engine: "zhihu"
        - 小红书 → engine: "xiaohongshu"
        - 淘宝 → engine: "taobao"
        - 京东 → engine: "jd"
        - Amazon/亚马逊 → engine: "amazon"
        - Reddit → engine: "reddit"
        - StackOverflow → engine: "stackoverflow"
        - Twitter/X → engine: "twitter"
        - Wikipedia/维基百科 → engine: "wikipedia"
        - 未指定 → 不传 engine（默认 Google）

        **query 必须是优化后的搜索关键词**，不是用户原话。你要像搜索引擎助手一样重构 query：
        - 去掉口语动词（搜索、搜一下、找、看、查）
        - 去掉无意义修饰（最新的、帮我找、有没有）
        - 提取核心搜索意图，转化为搜索引擎友好的关键词
        - 中文人名/专有名词如果在英文平台搜索，应翻译为英文
        例如：
        - "用YouTube搜索詹姆斯最新的视频" → query: "LeBron James highlights 2025", engine: "youtube"
        - "帮我在油管上搜一下怎么做蛋糕" → query: "how to bake a cake tutorial", engine: "youtube"
        - "搜索macOS Sequoia有什么新功能" → query: "macOS Sequoia new features"
        - "百度一下附近有什么好吃的" → query: "附近美食推荐", engine: "baidu"
        - "在B站找一下原神攻略" → query: "原神攻略", engine: "bilibili"

        ### open_url
        url 参数必须是完整 URL（含 https://）。常见映射参见 action 描述。

        ### open_folder
        folder 参数使用关键词：desktop, downloads, documents, home, applications, pictures, music, movies, trash, icloud, dropbox。

        ### file_search
        用户想找本地文件时使用，通过 Spotlight 搜索。query 是文件名或关键词，去掉口语修饰。
        常见说法："找一下 readme"、"合同在哪"、"帮我找那个报告"。

        ### quick_answer（重要）
        对于简单查询（计算、换算、查词、时区、简单事实），用 quick_answer 直接回答。
        answer 参数中直接给出简洁答案（1-2句话）。
        时区查询：根据上面给出的当前北京时间，计算出目标城市的实际时间并直接回答（如"纽约现在是 14:30"）。
        如果问题太复杂无法简短回答（需要长篇讨论、实时数据、主观判断），返回 action_id: "none"。

        ### timer
        seconds 参数是秒数整数。"5分钟" → 300，"一个半小时" → 5400。

        ### 其他参数
        - volume_control 的 action：mute / unmute / up / down / set（set 时需 level 0-100）
        - window_manage 的 position：left / right / fullscreen / minimize
        - do_not_disturb 的 action：on / off / toggle
        - 无法匹配任何操作 → action_id: "none"

        ## 示例

        "帮我打开Safari" → {"action_id":"launch_app","params":{"appName":"Safari"},"confidence":0.95}
        "打开cloud" → {"action_id":"launch_app","params":{"appName":"Claude"},"confidence":0.9}
        "打开cloud code" → {"action_id":"launch_app","params":{"appName":"Claude"},"confidence":0.85}
        "打开dress" → {"action_id":"launch_app","params":{"appName":"Drafts"},"confidence":0.85}
        "打开Claud" → {"action_id":"launch_app","params":{"appName":"Claude"},"confidence":0.9}
        "用YouTube搜索詹姆斯最新的视频" → {"action_id":"web_search","params":{"query":"LeBron James latest highlights","engine":"youtube"},"confidence":0.95}
        "帮我在油管搜一下怎么做蛋糕" → {"action_id":"web_search","params":{"query":"how to bake a cake tutorial","engine":"youtube"},"confidence":0.95}
        "搜索Swift并发编程" → {"action_id":"web_search","params":{"query":"Swift concurrency programming"},"confidence":0.95}
        "在淘宝搜无线键盘" → {"action_id":"web_search","params":{"query":"无线键盘","engine":"taobao"},"confidence":0.95}
        "在知乎找一下怎么学编程" → {"action_id":"web_search","params":{"query":"编程入门","engine":"zhihu"},"confidence":0.95}
        "声音小一点" → {"action_id":"volume_control","params":{"action":"down"},"confidence":0.95}
        "窗口放左边" → {"action_id":"window_manage","params":{"position":"left"},"confidence":0.9}
        "静音" → {"action_id":"volume_control","params":{"action":"mute"},"confidence":0.95}
        "锁屏" → {"action_id":"lock_screen","params":{},"confidence":0.95}
        "关掉Safari" → {"action_id":"kill_process","params":{"appName":"Safari"},"confidence":0.95}
        "剪贴板" → {"action_id":"clipboard_history","params":{},"confidence":0.95}
        "打开GitHub" → {"action_id":"open_url","params":{"url":"https://github.com"},"confidence":0.95}
        "打开Gmail" → {"action_id":"open_url","params":{"url":"https://mail.google.com"},"confidence":0.95}
        "打开下载文件夹" → {"action_id":"open_folder","params":{"folder":"downloads"},"confidence":0.95}
        "打开桌面" → {"action_id":"open_folder","params":{"folder":"desktop"},"confidence":0.95}
        "找一下合同" → {"action_id":"file_search","params":{"query":"合同"},"confidence":0.9}
        "readme在哪" → {"action_id":"file_search","params":{"query":"readme"},"confidence":0.9}
        "帮我找那个报告" → {"action_id":"file_search","params":{"query":"报告"},"confidence":0.9}
        "128乘以15" → {"action_id":"quick_answer","params":{"answer":"1,920"},"confidence":0.95}
        "100美元多少人民币" → {"action_id":"quick_answer","params":{"answer":"约 726 人民币（汇率 7.26）"},"confidence":0.9}
        "纽约现在几点" → {"action_id":"quick_answer","params":{"answer":"纽约现在是 14:30（根据当前北京时间换算，UTC-5）"},"confidence":0.95}
        "serendipity什么意思" → {"action_id":"quick_answer","params":{"answer":"意外发现有价值事物的能力或运气，中文可译为「机缘巧合」"},"confidence":0.95}
        "5公里等于多少英里" → {"action_id":"quick_answer","params":{"answer":"约 3.1 英里"},"confidence":0.95}
        "5分钟计时器" → {"action_id":"timer","params":{"seconds":"300","label":"5分钟计时器"},"confidence":0.95}
        "倒计时10分钟" → {"action_id":"timer","params":{"seconds":"600"},"confidence":0.95}
        "今天天气怎么样" → {"action_id":"none","params":{},"confidence":0.0}
        "帮我写一篇文章" → {"action_id":"none","params":{},"confidence":0.0}

        ## 输出

        严格只输出 JSON，不要任何其他文字：
        {"action_id":"xxx","params":{...},"confidence":0.9}
        """

        // Inject current time so LLM can answer time/timezone queries
        let now = Date()
        let bjFormatter = DateFormatter()
        bjFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        bjFormatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        let bjTime = bjFormatter.string(from: now)
        prompt += "\n\n当前北京时间：\(bjTime)"

        if let ctx = context {
            prompt += "\n当前上下文：用户正在 \(ctx.appName)。"
            if let url = ctx.url {
                prompt += " 网页: \(url)"
            }
        }

        return prompt
    }

    // MARK: - Response Parsing

    private func parseResponse(_ response: String, actions: [ActionDefinition]) -> IntentMatch? {
        let jsonString = extractJSON(from: response)
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log.warning("IntentService: Failed to parse LLM JSON: \(response.prefix(200))")
            return nil
        }

        guard let actionId = json["action_id"] as? String, actionId != "none" else {
            return nil
        }

        let confidence = json["confidence"] as? Double ?? 0.0
        guard confidence > 0 else { return nil }

        guard let action = actionService.action(byId: actionId) else {
            log.warning("IntentService: Unknown action_id from LLM: \(actionId)")
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") {
            return trimmed
        }

        // Markdown code block
        if let start = trimmed.range(of: "```json"),
           let end = trimmed.range(of: "```", range: start.upperBound..<trimmed.endIndex) {
            return String(trimmed[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // First { ... } block
        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}") {
            return String(trimmed[start...end])
        }

        return trimmed
    }
}
