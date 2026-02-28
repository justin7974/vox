import Cocoa

/// Detects the user's current app and browser context for prompt routing.
/// Called on the main thread before dispatching to background processing.
enum ContextDetector {

    struct AppContext {
        let bundleID: String
        let appName: String
        let url: String?       // Browser active tab URL (nil if not a browser)
        let domain: String?    // Extracted domain from URL
    }

    // MARK: - Public API

    /// Detect the frontmost app (and browser tab URL if applicable).
    /// Must be called on the main thread for reliable results.
    static func detect() -> AppContext {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier ?? ""
        let appName = app?.localizedName ?? ""

        var url: String? = nil
        var domain: String? = nil

        if isBrowser(bundleID) {
            url = getBrowserURL(bundleID: bundleID)
            if let u = url {
                domain = extractDomain(from: u)
            }
        }

        NSLog("Vox: Context detected — app: \(appName) (\(bundleID)), url: \(url ?? "N/A")")
        return AppContext(bundleID: bundleID, appName: appName, url: url, domain: domain)
    }

    /// Generate a context hint string to append to the prompt.
    /// Returns nil if no specific hint applies (use default behavior).
    static func contextHint(for ctx: AppContext) -> String? {
        // 1. Check browser URL domain first (more specific)
        if let domain = ctx.domain {
            // Exact match
            if let hint = urlHints[domain] { return hint }
            // Partial match (e.g., "mail.google.com" contains "google.com")
            for (key, hint) in urlHints {
                if domain.contains(key) || key.contains(domain) { return hint }
            }
        }

        // 2. Check native app bundle ID
        if let hint = appHints[ctx.bundleID] { return hint }

        // 3. No match — return nil, PostProcessor will use prompt as-is
        return nil
    }

    // MARK: - Browser detection

    private static let browserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.apple.Safari",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",   // Arc
        "com.vivaldi.Vivaldi",
    ]

    private static func isBrowser(_ bundleID: String) -> Bool {
        browserBundleIDs.contains(bundleID)
    }

    /// Use AppleScript to query the active tab URL from the browser.
    /// Returns nil on failure (permission denied, no window, etc.)
    private static func getBrowserURL(bundleID: String) -> String? {
        let script: String
        switch bundleID {
        case "com.apple.Safari":
            script = "tell application \"Safari\" to get URL of current tab of front window"
        case "company.thebrowser.Browser":
            script = "tell application \"Arc\" to get URL of active tab of front window"
        default:
            // Chrome, Edge, Brave, Vivaldi all use Chromium AppleScript API
            let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Google Chrome"
            script = "tell application \"\(appName)\" to get URL of active tab of front window"
        }

        guard let appleScript = NSAppleScript(source: script) else { return nil }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        if let error = error {
            NSLog("Vox: AppleScript error: \(error)")
            return nil
        }
        return result.stringValue
    }

    // MARK: - Domain extraction

    private static func extractDomain(from urlString: String) -> String? {
        guard let url = URL(string: urlString), let host = url.host else { return nil }
        return host.lowercased()
    }

    // MARK: - Context hint tables

    /// URL domain → context hint (for browser tabs)
    private static let urlHints: [String: String] = [
        // Email
        "mail.google.com":      "用户正在 Gmail 中处理邮件。请使用正式、清晰的书面语气。",
        "outlook.live.com":     "用户正在 Outlook 中处理邮件。请使用正式、清晰的书面语气。",
        "outlook.office.com":   "用户正在 Outlook 中处理邮件。请使用正式、清晰的书面语气。",
        "outlook.office365.com":"用户正在 Outlook 中处理邮件。请使用正式、清晰的书面语气。",

        // IM / Social
        "discord.com":          "用户正在 Discord 聊天。请保持轻松口语化的风格。",
        "web.whatsapp.com":     "用户正在 WhatsApp 聊天。请保持口语自然的风格。",
        "web.telegram.org":     "用户正在 Telegram 聊天。请保持口语自然的风格。",
        "twitter.com":          "用户正在发推文/帖子。请保持简短有力。",
        "x.com":                "用户正在发推文/帖子。请保持简短有力。",
        "linkedin.com":         "用户正在 LinkedIn 上。请使用专业商务的语气。",

        // Workspace IM
        "slack.com":            "用户正在 Slack 工作沟通。请使用简洁专业但不过于正式的语气。",
        "feishu.cn":            "用户正在飞书中沟通。请使用简洁专业但不过于正式的语气。",
        "larksuite.com":        "用户正在飞书中沟通。请使用简洁专业但不过于正式的语气。",

        // Docs
        "notion.so":            "用户正在 Notion 中编辑文档。请保持结构清晰的书面表达。",
        "docs.google.com":      "用户正在 Google Docs 中编辑文档。请使用规范的书面语。",

        // Dev
        "github.com":           "用户正在 GitHub 上。请使用简洁准确的技术语言。",
        "gitlab.com":           "用户正在 GitLab 上。请使用简洁准确的技术语言。",
        "stackoverflow.com":    "用户正在 Stack Overflow 上。请使用简洁准确的技术语言。",
    ]

    /// App bundle ID → context hint (for native apps)
    private static let appHints: [String: String] = [
        // IM
        "com.tencent.xinWeChat":    "用户正在微信中聊天。请保持口语自然的风格。",
        "com.apple.MobileSMS":      "用户正在 iMessage 中聊天。请保持口语自然的风格。",
        "com.tencent.qq":           "用户正在 QQ 中聊天。请保持口语自然的风格。",
        "com.lark.Lark":            "用户正在飞书中沟通。请使用简洁专业但不过于正式的语气。",
        "com.electron.lark":        "用户正在飞书中沟通。请使用简洁专业但不过于正式的语气。",
        "com.tinyspeck.slackmacgap":"用户正在 Slack 工作沟通。请使用简洁专业但不过于正式的语气。",

        // Email
        "com.apple.mail":           "用户正在 Apple Mail 中写邮件。请使用正式、清晰的书面语气。",
        "com.microsoft.Outlook":    "用户正在 Outlook 中处理邮件。请使用正式、清晰的书面语气。",

        // Notes
        "com.apple.Notes":          "用户正在备忘录中记录。请忠实保留原意，仅做基本清理，少润色。",

        // Dev
        "com.microsoft.VSCode":     "用户正在 VS Code 中编程。请使用简洁的技术语言。",
        "com.apple.dt.Xcode":       "用户正在 Xcode 中编程。请使用简洁的技术语言。",
        "com.apple.Terminal":       "用户正在终端中工作。请使用简洁的技术语言。",
        "com.googlecode.iterm2":    "用户正在终端中工作。请使用简洁的技术语言。",
        "dev.warp.Warp-Stable":     "用户正在终端中工作。请使用简洁的技术语言。",

        // Office
        "com.microsoft.Word":       "用户正在 Word 中编辑文档。请使用规范的书面语。",
        "com.microsoft.Powerpoint": "用户正在 PowerPoint 中编辑。请使用简洁有力的表达。",
        "com.microsoft.Excel":      "用户正在 Excel 中工作。请使用简洁精确的表达。",
    ]
}
