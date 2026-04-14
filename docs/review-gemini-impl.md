# Gemini 3.1 Pro Review

> Model: gemini-3.1-pro-preview via Vertex AI (Vicoo) | Generated: 2026-04-14 02:06

这份基于 Swift 编写的 Vox v3.0 代码库整体质量很高，架构清晰，对 macOS 底层 API（Carbon Hotkey、CGEvent、Accessibility）的使用非常成熟。特别是 **Black Box 灾备机制**和**状态机驱动的核心循环**设计得非常亮眼。

但在从 v2.x 瘦身到 v3.0 的过程中，遗留了一些历史包袱，同时在并发处理、安全性和边缘场景上存在一些隐患。以下是深度的审阅报告：

---

### 🔴 一、 严重问题（高优先级修复）

#### 1. 状态机与副作用执行脱节 (逻辑错误)
在 `DictationCoordinator` 中，你调用了 `sm.transition(to:)`，但 `VoxStateMachine` 的设计是：如果状态流转不合法，它只会 `return` 并打印日志，**不会阻止调用方继续执行后续逻辑**。
* **复现场景**：如果在 `.transcribing` 状态下意外触发了 `startRecording()`，状态机拒绝进入 `.recording`（保留在 `.transcribing`），但 `audio.startRecording()` 依然会被调用。这会导致 UI 显示在识别中，但底层却在录音。
* **修复建议**：`transition(to:)` 应该抛出错误（`throws`），或者返回一个 `Bool`，调用方必须根据返回值决定是否执行副作用。
  ```swift
  @discardableResult
  func transition(to newPhase: VoxPhase) -> Bool { ... }
  
  // Caller
  guard sm.transition(to: .recording) else { return }
  audio.startRecording()
  ```

#### 2. AppleScript 阻塞主线程 (性能与卡顿)
在 `DictationCoordinator.stopAndProcess()` 中，录音结束瞬间会在主线程同步调用 `context.detect()`。
* **隐患**：`NSAppleScript(source:).executeAndReturnError` 是同步且阻塞的。如果此时 Safari 或 Chrome 处于无响应状态，或者弹出了系统级 Modal，**整个 Vox 的主线程（包括停止录音的 UI 动画）都会被卡死**。
* **修复建议**：将 `context.detect()` 移入 `Task` 中，在后台线程执行。

#### 3. API Key 明文存储 (安全性)
`ConfigService` 将所有的 API Key（Qwen, OpenAI, Anthropic）明文保存在 `~/.vox/config.json` 中。
* **隐患**：任何运行在当前用户权限下的恶意脚本或应用都可以轻易窃取这些高价值的 Token。
* **修复建议**：使用 macOS 的 `Keychain Services` 存储敏感的 API Key，`config.json` 只保存常规设置。可以使用现成的轻量级库如 `KeychainAccess`。

---

### 🟡 二、 架构与可维护性问题

#### 1. `VoxConfig` 结构体形同虚设 (架构设计)
代码中定义了完美的 `VoxConfig: Codable` 结构体，但在 `ConfigService` 中却**完全没有使用它**。你一直在用 `[String: Any]` 字典手动解析和写入配置（例如 `raw["hotkeyMode"] as? String`）。
* **影响**：失去了 Swift 强类型的优势，导致 `SetupWindow` 和 `VoiceSettingsVC` 中充满了容易出错的硬编码字符串键值对。
* **修复建议**：重构 `ConfigService`，内部持有 `var current: VoxConfig`，通过 `JSONEncoder/Decoder` 统一进行文件的读写。

#### 2. `SetupWindow` 过于庞大 (代码异味)
`SetupWindow.swift` 长达 1,674 行，是一个典型的 **God Object**。它同时负责了 6 个步骤的 UI 构建、状态管理、配置校验和文件写入。
* **修复建议**：使用 `NSViewController` 将每个步骤（Welcome, HotkeyMode, APIConfig 等）拆分为独立的 Controller，`SetupWindow` 只负责容器切换和导航条逻辑。

#### 3. 死代码未清理干净 (死代码)
既然 v3.0 砍掉了 Launcher 和 Clipboard，以下代码应被移除：
* `FloatingPanel.swift`（完全未使用）。
* `VoxError` 中的 `.actionFailed` 和 `.intentMatchFailed`。

---

### 🔵 三、 macOS 平台适配与边缘情况

#### 1. 路径硬编码导致架构兼容性问题
在 `STTService` 和 `ConfigService` 中，硬编码了 Homebrew 的路径：
* `/opt/homebrew/bin/whisper-cli`
* `/usr/local/bin/ffmpeg`
* **隐患**：Apple Silicon 的 Homebrew 默认在 `/opt/homebrew`，但 Intel Mac 在 `/usr/local`。代码中 `STTService.splitAudio` 对 ffmpeg 做了 fallback，但对 `whisper-cli` 却没有做架构兼容检测。
* **修复建议**：使用 `ProcessInfo.processInfo.environment["PATH"]` 结合 `which` 命令动态查找执行文件路径。

#### 2. Edit Mode (修改模式) 的致命降级体验
Edit Mode 依赖 `AXSelectedTextRangeAttribute` 选中刚插入的文本。
* **隐患**：已知在 Electron 应用（如 VS Code, Discord, 网页版微信）中 Accessibility API 经常失效。如果**选中失败**，Vox 依然会执行 LLM 修改，并触发 `Cmd+V`。这会导致**修改后的文本被追加到原文本后面**，而不是替换原文本。
* **修复建议**：在 `selectLastInsertedText()` 中返回一个 `Bool`。如果选中失败，直接放弃进入 Edit Mode，或者在 UI 上提示“当前应用不支持修改模式”。

#### 3. 剪贴板污染 (产品完整性)
`PasteService` 使用了剪贴板来实现 `Cmd+V`，但没有恢复用户原有的剪贴板内容。
* **修复建议**：
  ```swift
  let pb = NSPasteboard.general
  let oldItems = pb.pasteboardItems // 备份
  pb.clearContents()
  pb.setString(text, forType: .string)
  // 触发 Cmd+V
  DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      pb.clearContents()
      // 恢复 oldItems
  }
  ```

#### 4. 全局快捷键拦截 Edit Window 的盲区
在 `DictationCoordinator.enterEditWindow()` 中，使用了 `NSEvent.addGlobalMonitorForEvents` 来监听键盘输入以取消 Edit Window。
* **隐患**：`addGlobalMonitorForEvents` **只在其他应用处于前台时生效**。如果 Vox 刚好是前台应用（例如用户刚点过 Vox 的菜单），此时敲击键盘不会触发该 Monitor，Edit Window 不会消失。
* **修复建议**：同时注册 `addLocalMonitorForEvents` 和 `addGlobalMonitorForEvents`。

---

### 🟢 四、 性能与资源管理

#### 1. 长音频分片 (Chunking) 的串行瓶颈
`STTService.transcribeChunked` 中，使用 `for chunk in chunks { await p.transcribe(...) }` 串行处理切片。
* **优化空间**：如果一个 9 分钟的音频被切成 3 段，串行请求需要耗费 3 倍的网络时间。既然是无状态的 API 请求，完全可以使用 `TaskGroup` 进行**并发请求**，然后按索引拼接结果。

#### 2. 日志文件无限增长 (内存/磁盘泄漏)
`LogService` 只追加写入 `~/.vox/debug.log`，没有任何轮转（Rotation）机制。
* **修复建议**：在 `AppDelegate` 启动时，检查日志文件大小，如果超过 5MB，则清空或重命名为 `debug.old.log`。

#### 3. Menu Bar Icon 的绘制方式
`AppDelegate` 中使用 `NSBezierPath` 手动绘制了麦克风图标（几十行代码）。
* **优化建议**：macOS 11.0+ 已经原生支持 SF Symbols。直接使用 `NSImage(systemSymbolName: "mic")` 即可，不仅代码精简，而且能完美适配系统的粗细和对齐规范。

---

### 💡 五、 未来演进 (Evolution) 的产品建议

既然 v3.0 的目标是 **"Only do voice input. Do it extremely well."**，建议在后续版本考虑以下特性：

1. **流式识别 (Streaming ASR)**：
   目前用户说完一长段话后，需要等待完整的上传 -> 识别 -> LLM 处理。对于超过 10 秒的语音，等待感非常明显。建议接入 Qwen 或 OpenAI 的 WebSocket/gRPC 流式 API，在 StatusOverlay 实时显示上屏的中间结果，最后再用 LLM 润色替换。
2. **多语言自动检测增强**：
   目前的 `whisper-local` 写死了 `-l zh`。既然定位是极致输入，建议利用 Whisper 的自动语种检测能力，或者在菜单栏提供一个快捷的语种切换（中/英/日），避免强行将英文用中文模型解析导致幻觉。
3. **上下文感知的剪贴板格式**：
   目前输出全是纯文本。既然经过了 LLM，并且知道当前在 VS Code，完全可以输出带缩进的代码块；如果在 Apple Mail，可以输出带换行的富文本（通过 NSPasteboard 写入 HTML 类型）。
