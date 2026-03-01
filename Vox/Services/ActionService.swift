import Foundation
import Cocoa

final class ActionService {
    static let shared = ActionService()

    private let log = LogService.shared
    private let actionsDir: String
    private(set) var actions: [ActionDefinition] = []

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

    private func executeApp(action: ActionDefinition, params: [String: String]) throws -> ActionResult {
        guard let appName = params["appName"], !appName.isEmpty else {
            throw VoxError.actionFailed("Missing app name")
        }

        // First check if app is already running — just activate it
        let running = NSWorkspace.shared.runningApplications
        if let app = running.first(where: { $0.localizedName?.lowercased() == appName.lowercased() }) {
            app.activate()
            return ActionResult(success: true, message: "Switched to \(appName)")
        }

        // Try to find and launch from /Applications
        let searchPaths = [
            "/Applications/\(appName).app",
            "/Applications/\(appName)",
            "/System/Applications/\(appName).app",
            "/System/Applications/Utilities/\(appName).app",
        ]

        for path in searchPaths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                let config = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.openApplication(at: url, configuration: config)
                return ActionResult(success: true, message: "Launched \(appName)")
            }
        }

        // Last resort: try open -a via shell
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appName]
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            return ActionResult(success: true, message: "Launched \(appName)")
        }

        throw VoxError.actionFailed("Could not find app: \(appName)")
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
        default:
            throw VoxError.actionFailed("Unknown system action: \(action.id)")
        }
    }

    private func executeVox(action: ActionDefinition, params: [String: String]) async throws -> ActionResult {
        switch action.id {
        case "translate":
            let targetLang = params["targetLanguage"] ?? "English"
            let prompt = "翻译以下文字到\(targetLang)。只输出翻译结果，不要任何解释。"
            let text = params["text"] ?? ""
            guard !text.isEmpty else {
                return ActionResult(success: true, message: "Translate: awaiting text")
            }
            let result = await LLMService.shared.process(rawText: text, customSystemPrompt: prompt)
            if !result.isEmpty && result != text {
                PasteService.shared.paste(text: result)
                return ActionResult(success: true, message: "Translated to \(targetLang)")
            }
            return ActionResult(success: false, message: "Translation failed")

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

        let running = NSWorkspace.shared.runningApplications
        let matches = running.filter {
            $0.localizedName?.lowercased() == appName.lowercased()
        }

        if let app = matches.first {
            app.forceTerminate()
            return ActionResult(success: true, message: "Killed \(appName)")
        }

        throw VoxError.actionFailed("App not running: \(appName)")
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

        // Check if actions already exist
        if let existing = try? fm.contentsOfDirectory(atPath: actionsDir),
           existing.contains(where: { $0.hasSuffix(".md") }) {
            return  // Already have actions, don't overwrite user modifications
        }

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

        for file in files where file.hasSuffix(".md") {
            let src = (bundleActionsDir as NSString).appendingPathComponent(file)
            let dst = (actionsDir as NSString).appendingPathComponent(file)
            do {
                try fm.copyItem(atPath: src, toPath: dst)
                log.debug("ActionService: Copied built-in action: \(file)")
            } catch {
                log.warning("ActionService: Failed to copy \(file): \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - ActionResult

struct ActionResult {
    let success: Bool
    let message: String
}
