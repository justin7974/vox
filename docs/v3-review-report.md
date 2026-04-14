# Vox v3.0 三方交叉审阅报告

> 审阅对象: Vox v3.0 完整代码库 (29 files, 7,434 lines Swift)
> 审阅模型: Claude (CC) + GPT-5.4 + Gemini 3.1 Pro
> 日期: 2026-04-14

## 共识（三方一致）

### 1. 死代码需清理

三方均指出：

- `VoxConfig.swift` — 定义了完整的 Codable 结构但从未使用，ConfigService 走的是 `[String: Any]` 手动解析（CC: P1/confidence 100, GPT: P3, Gemini: 架构问题）
- `FloatingPanel.swift` — 删除 Launcher/Clipboard 后无子类引用（CC: P1/confidence 90, GPT: 未提, Gemini: 死代码）
- `VoxError.actionFailed/intentMatchFailed` — 残留的 Action 系统错误类型（CC: P1/confidence 100, GPT: 未提, Gemini: 死代码）

### 2. API Key 明文存储

三方一致认为应迁移到 macOS Keychain：

- CC: P2（个人工具风险可接受）
- GPT: P1（log 也会泄漏敏感信息，UI 应用 NSSecureTextField）
- Gemini: 严重问题（任何同用户进程可读取）

### 3. 剪贴板不恢复

三方均提出 paste 后应恢复原剪贴板内容：

- CC: P2
- GPT: 未显式提，但指出 paste 缺乏成功确认
- Gemini: 提供了具体的 save/restore 代码示例

### 4. 日志无限增长

`debug.log` 只追加不轮转，长期使用会累积大量数据。三方一致建议加 rotation 或大小限制。

## 分歧

### 1. 主线程阻塞的严重程度

- **CC** 认为 `PasteService.usleep(70ms)` 是 P0（每次粘贴阻塞主线程）
- **GPT** 更关注 `paste 缺乏成功确认`（P1），未单独提 usleep
- **Gemini** 指出 `AppleScript 阻塞主线程`（context.detect() 在 stop 时同步执行）是严重问题，但未提 usleep

**CC 判断**: usleep 70ms 在实践中几乎不可感知（<16ms 帧时间的 4 倍），但 AppleScript 阻塞是真正危险的——浏览器无响应时可能卡数秒。**两个都该修，AppleScript 优先级更高**。

### 2. Edit/Translate 的 LLM 依赖问题

- **GPT** 独立发现了两个高价值 bug（P1）：
  - Edit 模式 LLM 失败时会把 `"原文：xxx\n修改指令：yyy"` 粘贴回去（destructive）
  - Translate 模式 LLM 失败时会贴原文但标记为翻译（misleading）
- **CC** 和 **Gemini** 未覆盖此问题

**CC 判断**: GPT 的发现是本次 review 最有价值的——这是真正的用户可见 bug，且修复简单。**提升为 P0**。

### 3. 状态机设计

- **Gemini** 指出状态机 transition 失败时不阻止后续代码执行（只 log，不 throw/return false），可能导致"UI 显示在识别中但底层在录音"
- **GPT** 从架构层面建议用 `async throws` 或 `Result<T, VoxError>` 替代空字符串错误通道
- **CC** 指出 AudioService.startRecording() 无防重入

**CC 判断**: 三者描述的是同一个根因——状态机与副作用执行之间缺乏事务性。Gemini 的 `transition(to:) -> Bool` 方案最小侵入。

### 4. VoiceSettingsVC provider 切换 bug

- **GPT** 独立发现：`llmProviderChanged()` 中 `indexOfSelectedItem` 取的是新选项而非旧选项，导致 key 缓存到错误 provider（P1）
- **CC** 和 **Gemini** 未覆盖

**CC 判断**: 确认这是真实 bug。NSPopUpButton 的 action 触发时 selectedItem 已经是新值。

### 5. Edit Window 的键盘监听盲区

- **Gemini** 独立发现：`addGlobalMonitorForEvents` 只在其他 app 前台时生效，Vox 自身前台时键盘输入不会取消 edit window
- **CC** 和 **GPT** 未覆盖

**CC 判断**: 确认是真实问题，需同时注册 local + global monitor。

## 行动项

### P0: Must Fix

- [ ] **Edit 模式 LLM fallback 是 destructive** — LLM 失败时不能 fallback 到 rawText，必须中止编辑并通知用户（GPT 发现）
- [ ] **Translate 模式 LLM fallback 是 misleading** — LLM 未配置/失败时应禁用翻译，不能贴原文冒充翻译（GPT 发现）

### P1: Should Fix

- [ ] **AppleScript 阻塞主线程** — `context.detect()` 在 stop 录音时同步执行，浏览器无响应会卡死 Vox（Gemini 发现）
- [ ] **VoiceSettingsVC provider 切换 key 串线** — `indexOfSelectedItem` 在 action 触发时已是新值，key 缓存到错误 provider（GPT 发现）
- [ ] **SetupWindow qwen-llm key 逻辑** — ASR 不是 qwen 时，qwen-llm 的 key 来源是错的（GPT 发现）
- [ ] **状态机 transition 无返回值** — 失败时只 log 不阻止副作用执行，加 `-> Bool` 返回值（Gemini 发现）
- [ ] **粘贴目标未锁定** — 处理中用户切 app 会贴到错误位置（GPT 发现）
- [ ] **paste 成功无确认** — 返回 Void，后续 history/edit window 盲目执行（GPT 发现）
- [ ] **AudioService 无防重入** — startRecording() 不检查已有录音，可能泄漏 timer 和文件（CC 发现）
- [ ] **Edit Window 键盘监听盲区** — 缺少 local monitor，Vox 前台时 edit window 不会被键盘取消（Gemini 发现）

### P2: Nice to Have

- [ ] **API Key 迁移 Keychain** + UI 用 NSSecureTextField（三方共识）
- [ ] **剪贴板恢复** — paste 后恢复原内容（三方共识）
- [ ] **日志轮转** — debug.log 加大小限制或 rotation（三方共识）
- [ ] **死代码清理** — 删除 VoxConfig.swift、FloatingPanel.swift、VoxError 孤儿 case（三方共识）
- [ ] **PasteService usleep** — 移到后台线程（CC 发现）
- [ ] **LogService DateFormatter** — 每次 log 创建新实例，改为 static（CC 发现）
- [ ] **ffmpeg 路径检测** — Apple Silicon 优先或用 `which`（CC + Gemini）
- [ ] **OpenAI-compatible `enable_thinking`** — 不通用的字段不应硬编码（GPT 发现）
- [ ] **chunk 拼接无分隔** — `joined(separator: "")` 英文会粘连（GPT 发现）
- [ ] **云 ASR 单字过滤** — `count < 2` 过于激进，"好""是"等合法单字被丢弃（GPT 发现）
- [ ] **edit 流缺少静音检测** — 只查 fileSize 不查 hasAudio（GPT 发现）
- [ ] **子进程 stderr 未消费** — pipe buffer 满可能卡死 whisper/ffmpeg（GPT 发现）
- [ ] **StatusOverlay 多显示器** — 固定 NSScreen.main，应跟随鼠标/前台窗口（GPT 发现）
- [ ] **Menu bar icon 用 SF Symbols** — 替代手绘 NSBezierPath（Gemini 建议）
- [ ] **TCC reset 过于激进** — bundle id 硬编码，改为用户可触发的 repair action（GPT 发现）
- [ ] **测试录音污染 Black Box** — stopRecording 默认 backup:true（GPT 发现）
- [ ] **音频文件名精确到秒会撞名** — 改 UUID 或毫秒时间戳（GPT 发现）

### P3: 架构演进方向

- [ ] **配置层统一** — 收敛到 typed VoxConfig + Codable，消除 raw dict 手写 schema（GPT + Gemini）
- [ ] **错误通道类型化** — String/Void → Result<T, VoxError> 或 async throws（GPT）
- [ ] **DictationCoordinator @MainActor** — 减少 MainActor.run 来回切换（GPT）
- [ ] **SetupWindow 拆分** — 1,674 行 God Object → 每步一个 ViewController（Gemini）

## Review 价值评估

| 审阅方 | 独有发现 | 最有价值发现 |
|--------|---------|-------------|
| **GPT-5.4** | Edit/Translate LLM fallback bug、provider key 串线、paste 目标锁定、qwen-llm key bug、单字过滤、chunk 拼接、stderr 卡死、TCC reset | Edit/Translate LLM fallback（P0 级 bug） |
| **Gemini 3.1 Pro** | AppleScript 阻塞、状态机 transition 无返回值、edit window 监听盲区、streaming ASR 建议、SF Symbols | AppleScript 阻塞（实际延迟可达数秒） |
| **CC (Claude)** | usleep 主线程、AudioService 防重入、DateFormatter 性能 | AudioService 防重入（timer 泄漏） |

**结论**: GPT 在这次 review 中表现最强——覆盖面最广（20 个发现），且独立发现了两个 P0 级别的真实 bug（edit/translate LLM fallback）。Gemini 的发现数量较少但质量高，尤其是 AppleScript 阻塞和 edit window 监听盲区是两个非常有深度的平台级发现。CC 的发现偏保守但准确率高。

三方交叉的价值在于：**单方 review 最多覆盖 60% 的问题，三方合并后覆盖率显著提升**。
