import Foundation
import Cocoa

final class ActionService {
    static let shared = ActionService()

    private let log = LogService.shared
    private let actionsDir: String
    private(set) var actions: [ActionDefinition] = []

    /// Map of lowercased app display name → full path to .app bundle.
    /// Populated at startup by scanning /Applications and /System/Applications.
    private var installedApps: [String: String] = [:]

    /// Sorted list of installed app display names (for LLM prompt).
    private(set) var installedAppNames: [String] = []

    private init() {
        actionsDir = NSHomeDirectory() + "/Library/Application Support/Vox/Actions"
    }

    // MARK: - Public API

    /// Load all actions from the user actions directory.
    /// On first run, copies built-in actions from the app bundle.
    func loadActions() {
        ensureActionsDirectory()
        copyBuiltinActionsIfNeeded()

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: actionsDir) else {
            log.warning("ActionService: Could not list actions directory")
            return
        }

        var loaded: [ActionDefinition] = []
        for file in files where file.hasSuffix(".md") {
            let path = (actionsDir as NSString).appendingPathComponent(file)
            let url = URL(fileURLWithPath: path)
            do {
                let action = try ActionDefinition.parse(fileAt: url)
                loaded.append(action)
                log.debug("ActionService: Loaded action '\(action.id)'")
            } catch {
                log.warning("ActionService: Failed to parse \(file): \(error.localizedDescription)")
            }
        }

        actions = loaded
        log.info("ActionService: Loaded \(loaded.count) actions")
    }

    /// Scan installed applications and build the name → path lookup.
    /// Called once at startup from AppDelegate.
    func scanInstalledApps() {
        var map: [String: String] = [:]

        let searchDirs = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications",
        ]

        let fm = FileManager.default
        for dir in searchDirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                let appPath = (dir as NSString).appendingPathComponent(item)
                let displayName = (item as NSString).deletingPathExtension
                map[displayName.lowercased()] = appPath
            }
        }

        installedApps = map
        installedAppNames = map.keys.sorted().map { name in
            // Return the original-cased name from the path
            let path = map[name]!
            return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        log.info("ActionService: Scanned \(map.count) installed apps")
    }

    /// Get all loaded action definitions.
    func getActions() -> [ActionDefinition] {
        return actions
    }

    /// Find an action by ID.
    func action(byId id: String) -> ActionDefinition? {
        return actions.first { $0.id == id }
    }

    /// Execute a matched intent. Returns a result description.
    func execute(match: IntentMatch) async throws -> ActionResult {
        let action = match.action
        log.info("ActionService: Executing '\(action.id)' with params: \(match.params)")

        switch action.type {
        case .url:
            return try executeURL(action: action, params: match.params)
        case .app:
            return try executeApp(action: action, params: match.params)
        case .system:
            return try await executeSystem(action: action, params: match.params)
        case .shortcut:
            return try await executeShortcut(action: action, params: match.params)
        case .vox:
            return try await executeVox(action: action, params: match.params)
        }
    }

    // MARK: - Execution by type

    private func executeURL(action: ActionDefinition, params: [String: String]) throws -> ActionResult {
        guard var template = action.template else {
            throw VoxError.actionFailed("Action '\(action.id)' has no URL template")
        }

        // Handle web_search engine variants
        if action.id == "web_search", let engine = params["engine"]?.lowercased() {
            let engineTemplates: [String: String] = [
                "youtube": "https://www.youtube.com/results?search_query={query}",
                "github": "https://github.com/search?q={query}",
                "baidu": "https://www.baidu.com/s?wd={query}",
                "bilibili": "https://search.bilibili.com/all?keyword={query}",
                "google": "https://www.google.com/search?q={query}",
                "zhihu": "https://www.zhihu.com/search?type=content&q={query}",
                "xiaohongshu": "https://www.xiaohongshu.com/search_result?keyword={query}",
                "taobao": "https://s.taobao.com/search?q={query}",
                "jd": "https://search.jd.com/Search?keyword={query}",
                "amazon": "https://www.amazon.com/s?k={query}",
                "reddit": "https://www.reddit.com/search/?q={query}",
                "stackoverflow": "https://stackoverflow.com/search?q={query}",
                "twitter": "https://x.com/search?q={query}",
                "wikipedia": "https://en.wikipedia.org/w/index.php?search={query}",
            ]
            template = engineTemplates[engine] ?? template
        }

        // Substitute params into template
        var urlString = template
        for (key, value) in params {
            let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            urlString = urlString.replacingOccurrences(of: "{\(key)}", with: encoded)
        }

        guard let url = URL(string: urlString) else {
            throw VoxError.actionFailed("Invalid URL: \(urlString)")
        }

        NSWorkspace.shared.open(url)
        return ActionResult(success: true, message: "Opened: \(url.host ?? urlString)")
    }

    // Common app name aliases (Chinese/phonetic → macOS app name)
    private static let appAliases: [String: String] = [
        // Browsers
        "浏览器": "Safari", "safari浏览器": "Safari",
        "谷歌浏览器": "Google Chrome", "谷歌": "Google Chrome", "chrome浏览器": "Google Chrome",
        "火狐": "Firefox", "火狐浏览器": "Firefox",
        // Communication
        "微信": "WeChat", "飞书": "Feishu", "钉钉": "DingTalk", "企业微信": "企业微信",
        // System apps
        "终端": "Terminal", "记事本": "TextEdit", "文本编辑": "TextEdit",
        "备忘录": "Notes", "日历": "Calendar", "邮件": "Mail",
        "音乐": "Music", "照片": "Photos", "计算器": "Calculator",
        "系统设置": "System Settings", "系统偏好设置": "System Preferences",
        "设置": "System Settings", "访达": "Finder", "文件管理器": "Finder",
        "预览": "Preview", "活动监视器": "Activity Monitor",
        "地图": "Maps", "天气": "Weather", "提醒事项": "Reminders",
        "快捷指令": "Shortcuts", "信息": "Messages", "消息": "Messages",
        // Dev tools
        "代码编辑器": "Visual Studio Code", "vscode": "Visual Studio Code",
    ]

    private func executeApp(action: ActionDefinition, params: [String: String]) throws -> ActionResult {
        guard let appName = params["appName"], !appName.isEmpty else {
            throw VoxError.actionFailed("Missing app name")
        }

        // Strip trailing punctuation/whitespace that STT might add
        let cleaned = appName.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        log.info("ActionService: executeApp raw='\(appName)' cleaned='\(cleaned)'")

        // Resolve: aliases → installed apps (exact) → installed apps (fuzzy) → raw name
        let resolvedName = resolveAppName(cleaned)
        log.info("ActionService: resolved='\(resolvedName)'")

        // 1. Check if app is already running — activate it
        let running = NSWorkspace.shared.runningApplications
        if let app = running.first(where: {
            guard let name = $0.localizedName?.lowercased() else { return false }
            return name == resolvedName.lowercased() || name == cleaned.lowercased()
        }) {
            app.activate()
            log.info("ActionService: Activated running app '\(app.localizedName ?? "")'")
            return ActionResult(success: true, message: "Switched to \(app.localizedName ?? appName)")
        }

        // 2. Try installed apps path (from scan)
        if let path = installedApps[resolvedName.lowercased()] ?? installedApps[cleaned.lowercased()] {
            log.info("ActionService: Found in installed apps: \(path)")
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return ActionResult(success: true, message: "Launched \(resolvedName)")
        }

        // 3. Try direct paths
        let searchPaths = [
            "/Applications/\(resolvedName).app",
            "/System/Applications/\(resolvedName).app",
            "/System/Applications/Utilities/\(resolvedName).app",
            "/Applications/\(cleaned).app",
            "/System/Applications/\(cleaned).app",
        ]

        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path) {
                log.info("ActionService: Found at \(path)")
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                return ActionResult(success: true, message: "Launched \(resolvedName)")
            }
        }

        // 4. Fallback: open -a (handles partial names, localized names)
        log.info("ActionService: Trying 'open -a \(resolvedName)'")
        if tryOpenApp(resolvedName) {
            return ActionResult(success: true, message: "Launched \(resolvedName)")
        }
        if resolvedName != cleaned {
            log.info("ActionService: Trying 'open -a \(cleaned)'")
            if tryOpenApp(cleaned) {
                return ActionResult(success: true, message: "Launched \(cleaned)")
            }
        }

        throw VoxError.actionFailed("找不到应用: \(appName)")
    }

    /// Resolve a possibly garbled app name to the real app name.
    /// Priority: static aliases → exact installed match → fuzzy installed match → original
    private func resolveAppName(_ name: String) -> String {
        let lower = name.lowercased()

        // 1. Static aliases (Chinese → English)
        if let alias = ActionService.appAliases[lower] {
            return alias
        }

        // 2. Exact match in installed apps
        if installedApps[lower] != nil {
            // Return the properly-cased name
            let path = installedApps[lower]!
            return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        }

        // 3. Fuzzy match against installed apps
        // Handles ASR errors like "cloud code" → "Claude Code"
        if let fuzzyMatch = fuzzyMatchApp(lower) {
            return fuzzyMatch
        }

        return name
    }

    /// Word-level match against installed app names.
    /// Only matches when ALL words in the query appear in the app name (order-independent).
    /// This avoids false positives like "cloud code" → "Cloud Station".
    private func fuzzyMatchApp(_ query: String) -> String? {
        let queryWords = query.lowercased().split(separator: " ").map(String.init)
        guard !queryWords.isEmpty else { return nil }

        var bestMatch: (name: String, path: String, matchedWords: Int)?

        for (installedLower, path) in installedApps {
            let appWords = installedLower.split(separator: " ").map(String.init)
            // Count how many query words appear in the app name
            let matched = queryWords.filter { qw in
                appWords.contains { aw in aw == qw || aw.hasPrefix(qw) || qw.hasPrefix(aw) }
            }.count
            // ALL query words must match
            if matched == queryWords.count && matched > (bestMatch?.matchedWords ?? 0) {
                bestMatch = (installedLower, path, matched)
            }
        }

        if let match = bestMatch {
            let realName = ((match.path as NSString).lastPathComponent as NSString).deletingPathExtension
            log.info("ActionService: Word-matched '\(query)' → '\(realName)' (\(match.matchedWords) words)")
            return realName
        }

        return nil
    }

    private func tryOpenApp(_ name: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func executeSystem(action: ActionDefinition, params: [String: String]) async throws -> ActionResult {
        switch action.id {
        case "volume_control":
            return try executeVolumeControl(params: params)
        case "do_not_disturb":
            return try await executeDoNotDisturb(params: params)
        case "lock_screen":
            return executeLockScreen()
        case "window_manage":
            return try executeWindowManage(params: params)
        case "kill_process":
            return try executeKillProcess(params: params)
        case "open_folder":
            return try executeOpenFolder(params: params)
        case "file_search":
            return try executeFileSearch(params: params)
        case "timer":
            return try executeTimer(params: params)
        default:
            throw VoxError.actionFailed("Unknown system action: \(action.id)")
        }
    }

    private func executeVox(action: ActionDefinition, params: [String: String]) async throws -> ActionResult {
        switch action.id {
        case "quick_answer":
            let answer = params["answer"] ?? ""
            guard !answer.isEmpty else {
                return ActionResult(success: false, message: "无法回答")
            }
            // Return answer with special prefix so LauncherCoordinator shows it in the panel
            return ActionResult(success: true, message: "quick_answer:\(answer)")

        case "text_modify":
            // text_modify is handled by DictationCoordinator's editWindow, not here
            return ActionResult(success: true, message: "Text modify: use edit window")

        case "selection_modify":
            // selection_modify is handled by LauncherCoordinator, not here
            return ActionResult(success: true, message: "Selection modify: dispatched")

        case "clipboard_history":
            // Signal to show clipboard panel — handled by LauncherCoordinator
            return ActionResult(success: true, message: "clipboard_show")

        default:
            throw VoxError.actionFailed("Unknown vox action: \(action.id)")
        }
    }

    private func executeShortcut(action: ActionDefinition, params: [String: String]) async throws -> ActionResult {
        guard let shortcutName = params["shortcut"] ?? action.template else {
            throw VoxError.actionFailed("No shortcut name specified")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", shortcutName]
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            return ActionResult(success: true, message: "Ran shortcut: \(shortcutName)")
        } else {
            throw VoxError.actionFailed("Shortcut '\(shortcutName)' failed with exit code \(process.terminationStatus)")
        }
    }

    // MARK: - System action implementations

    private func executeVolumeControl(params: [String: String]) throws -> ActionResult {
        let action = params["action"]?.lowercased() ?? ""

        var script: String
        switch action {
        case "mute", "静音":
            script = "set volume with output muted"
        case "unmute", "取消静音":
            script = "set volume without output muted"
        case "up", "调高":
            script = "set volume output volume ((output volume of (get volume settings)) + 10)"
        case "down", "调低":
            script = "set volume output volume ((output volume of (get volume settings)) - 10)"
        default:
            if let level = params["level"].flatMap({ Int($0) }) {
                let clamped = max(0, min(100, level))
                script = "set volume output volume \(clamped)"
            } else {
                throw VoxError.actionFailed("Unknown volume action: \(action)")
            }
        }

        runAppleScript(script)
        return ActionResult(success: true, message: "Volume: \(action)")
    }

    private func executeDoNotDisturb(params: [String: String]) async throws -> ActionResult {
        let action = params["action"]?.lowercased() ?? "toggle"

        // Use Shortcuts to toggle Focus
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", "Toggle Focus"]
        try process.run()
        process.waitUntilExit()

        return ActionResult(success: true, message: "Focus mode: \(action)")
    }

    private func executeLockScreen() -> ActionResult {
        let script = "tell application \"System Events\" to keystroke \"q\" using {control down, command down}"
        runAppleScript(script)
        return ActionResult(success: true, message: "Screen locked")
    }

    private func executeWindowManage(params: [String: String]) throws -> ActionResult {
        guard let position = params["position"]?.lowercased() else {
            throw VoxError.actionFailed("Missing window position")
        }

        guard let screen = NSScreen.main?.visibleFrame else {
            throw VoxError.actionFailed("No screen available")
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let element = AXUIElementCreateApplication(frontApp.processIdentifier) as AXUIElement? else {
            throw VoxError.actionFailed("Cannot access frontmost application")
        }

        // Get the frontmost window
        var windowRef: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &windowRef)
        guard let window = windowRef else {
            throw VoxError.actionFailed("No focused window found")
        }

        var newOrigin: CGPoint
        var newSize: CGSize

        switch position {
        case "fullscreen", "全屏", "最大化":
            newOrigin = CGPoint(x: screen.origin.x, y: screen.origin.y)
            newSize = CGSize(width: screen.width, height: screen.height)
        case "left", "左边", "放左边", "left half":
            newOrigin = CGPoint(x: screen.origin.x, y: screen.origin.y)
            newSize = CGSize(width: screen.width / 2, height: screen.height)
        case "right", "右边", "放右边", "right half":
            newOrigin = CGPoint(x: screen.origin.x + screen.width / 2, y: screen.origin.y)
            newSize = CGSize(width: screen.width / 2, height: screen.height)
        case "minimize", "最小化":
            AXUIElementSetAttributeValue(window as! AXUIElement, kAXMinimizedAttribute as CFString, true as CFTypeRef)
            return ActionResult(success: true, message: "Window minimized")
        default:
            throw VoxError.actionFailed("Unknown position: \(position)")
        }

        // Set position and size via Accessibility API
        var point = newOrigin
        var size = newSize
        let posValue = AXValueCreate(.cgPoint, &point)!
        let sizeValue = AXValueCreate(.cgSize, &size)!
        AXUIElementSetAttributeValue(window as! AXUIElement, kAXPositionAttribute as CFString, posValue)
        AXUIElementSetAttributeValue(window as! AXUIElement, kAXSizeAttribute as CFString, sizeValue)

        return ActionResult(success: true, message: "Window: \(position)")
    }

    private func executeKillProcess(params: [String: String]) throws -> ActionResult {
        guard let appName = params["appName"], !appName.isEmpty else {
            throw VoxError.actionFailed("Missing app name to kill")
        }

        // Also resolve the name for kill_process
        let resolved = resolveAppName(appName)

        let running = NSWorkspace.shared.runningApplications
        let matches = running.filter {
            guard let name = $0.localizedName?.lowercased() else { return false }
            return name == resolved.lowercased() || name == appName.lowercased()
        }

        if let app = matches.first {
            app.forceTerminate()
            return ActionResult(success: true, message: "Killed \(app.localizedName ?? appName)")
        }

        throw VoxError.actionFailed("App not running: \(appName)")
    }

    // MARK: - Open Folder

    private static let folderMappings: [String: String] = [
        "desktop": "~/Desktop", "桌面": "~/Desktop",
        "downloads": "~/Downloads", "下载": "~/Downloads",
        "documents": "~/Documents", "文档": "~/Documents",
        "home": "~", "主目录": "~",
        "applications": "/Applications", "应用": "/Applications",
        "pictures": "~/Pictures", "图片": "~/Pictures",
        "music": "~/Music", "音乐": "~/Music",
        "movies": "~/Movies", "视频": "~/Movies",
        "trash": "~/.Trash", "废纸篓": "~/.Trash",
        "icloud": "~/Library/Mobile Documents/com~apple~CloudDocs",
        "dropbox": "~/Library/CloudStorage/Dropbox",
    ]

    private func executeOpenFolder(params: [String: String]) throws -> ActionResult {
        guard let folder = params["folder"], !folder.isEmpty else {
            throw VoxError.actionFailed("Missing folder name")
        }

        let lower = folder.lowercased()
        let pathTemplate = ActionService.folderMappings[lower] ?? folder
        let path = NSString(string: pathTemplate).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: path) else {
            throw VoxError.actionFailed("文件夹不存在: \(folder)")
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        let displayName = (path as NSString).lastPathComponent
        return ActionResult(success: true, message: "打开了 \(displayName)")
    }

    // MARK: - File Search

    private func executeFileSearch(params: [String: String]) throws -> ActionResult {
        guard let query = params["query"], !query.isEmpty else {
            throw VoxError.actionFailed("Missing search query")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-name", query, "-onlyin", NSHomeDirectory()]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw VoxError.actionFailed("搜索失败: \(error.localizedDescription)")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let files = output.components(separatedBy: "\n").filter { !$0.isEmpty }

        guard !files.isEmpty else {
            return ActionResult(success: false, message: "未找到: \(query)")
        }

        // Reveal the first result in Finder
        let firstFile = URL(fileURLWithPath: files[0])
        NSWorkspace.shared.activateFileViewerSelecting([firstFile])

        let count = files.count
        let name = (files[0] as NSString).lastPathComponent
        if count == 1 {
            return ActionResult(success: true, message: "找到: \(name)")
        } else {
            return ActionResult(success: true, message: "找到 \(count) 个结果，显示: \(name)")
        }
    }

    // MARK: - Timer

    private func executeTimer(params: [String: String]) throws -> ActionResult {
        guard let secondsStr = params["seconds"], let seconds = Int(secondsStr), seconds > 0 else {
            throw VoxError.actionFailed("Invalid timer duration")
        }

        let label = params["label"] ?? "Vox 计时器"
        let duration = formatDuration(seconds)

        // Use DispatchQueue delayed execution + AppleScript notification
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) {
            let script = """
            display notification "\(duration) 到了" with title "\(label)" sound name "Glass"
            """
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
            }
        }

        return ActionResult(success: true, message: "计时 \(duration)")
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds >= 3600 {
            let h = seconds / 3600
            let m = (seconds % 3600) / 60
            return m > 0 ? "\(h)小时\(m)分钟" : "\(h)小时"
        } else if seconds >= 60 {
            let m = seconds / 60
            let s = seconds % 60
            return s > 0 ? "\(m)分\(s)秒" : "\(m)分钟"
        } else {
            return "\(seconds)秒"
        }
    }

    // MARK: - Spotlight Fallback

    /// Open Spotlight search. Called when no action matches and user wants to fall back.
    func openSpotlight() {
        let script = "tell application \"System Events\" to keystroke \" \" using command down"
        runAppleScript(script)
    }

    // MARK: - Helpers

    private func runAppleScript(_ script: String) {
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                log.warning("ActionService: AppleScript error: \(error)")
            }
        }
    }

    private func ensureActionsDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: actionsDir) {
            try? fm.createDirectory(atPath: actionsDir, withIntermediateDirectories: true)
        }
    }

    private func copyBuiltinActionsIfNeeded() {
        let fm = FileManager.default

        // Copy from app bundle Resources/Actions/
        guard let bundlePath = Bundle.main.resourcePath else {
            log.warning("ActionService: No bundle resource path")
            return
        }

        let bundleActionsDir = (bundlePath as NSString).appendingPathComponent("Actions")
        guard fm.fileExists(atPath: bundleActionsDir) else {
            log.warning("ActionService: No built-in Actions directory in bundle")
            return
        }

        guard let files = try? fm.contentsOfDirectory(atPath: bundleActionsDir) else { return }

        // Copy each builtin action that doesn't exist in user dir yet.
        // Existing user-modified actions are never overwritten.
        for file in files where file.hasSuffix(".md") {
            let src = (bundleActionsDir as NSString).appendingPathComponent(file)
            let dst = (actionsDir as NSString).appendingPathComponent(file)
            if !fm.fileExists(atPath: dst) {
                do {
                    try fm.copyItem(atPath: src, toPath: dst)
                    log.info("ActionService: Copied new built-in action: \(file)")
                } catch {
                    log.warning("ActionService: Failed to copy \(file): \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - ActionResult

struct ActionResult {
    let success: Bool
    let message: String
}
