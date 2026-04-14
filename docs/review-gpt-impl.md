# GPT-5.4 Review

> Model: gpt-5.4 via xs | Generated: 2026-04-14 02:06

下面是一次偏 implementation / latent bug 导向的 review。先给结论：

**整体评价**
- v3.0 的瘦身方向是对的，主链路也明显比 v2.x 清爽。
- 但现在有几类**隐藏得比较深、且会直接影响“日常可靠性”**的问题：
  1. **编辑 / 翻译对 LLM 的依赖没有被建模出来**
  2. **配置 UI 有真实的 provider/key 串线 bug**
  3. **粘贴目标与粘贴成功没有被确认**
  4. **隐私/密钥处理还停留在“本地工具原型”阶段**

如果只挑最值得优先修的，我会先修前 6 个。

---

## P1：建议优先修复

### 1) 编辑模式在 LLM 不可用时会把“原文+修改指令”直接粘回去
**位置**
- `DictationCoordinator.stopAndProcessEdit()`
- `LLMService.process(...)`

**问题**
编辑流里：

```swift
let userMessage = "原文：\(originalText)\n\n修改指令：\(editInstruction)"
let editedText = await self.llm.process(rawText: userMessage, customSystemPrompt: LLMService.editPrompt)
```

但 `LLMService.process()` 在 **未配置 LLM** 或 **LLM 调用失败** 时，会直接 `return rawText`。

这在普通 dictation 流里是合理兜底；但在 edit 流里，`rawText` 不是原始转写，而是：

```text
原文：xxx

修改指令：yyy
```

所以结果会是：**用户刚插入的文字被这段 prompt payload 替换掉**。

**影响**
- 用户文档被污染
- 编辑模式变成 destructive 行为
- 这是“偶发但非常伤”的 bug

**建议**
- 把 LLM 能力分成两类：
  - `cleanup`：可降级
  - `edit/translate`：**不可降级**
- edit 流里如果 `!llm.isConfigured` 或调用失败，应直接：
  - 退出 edit 模式
  - 通知用户“编辑需要启用 LLM”
  - **绝不能 fallback 到 rawText**

---

### 2) 翻译模式在没有 LLM / LLM 失败时会“假翻译”
**位置**
- `DictationCoordinator.stopAndProcess()`
- `LLMService.process(...)`
- `AppDelegate.toggleTranslateMode()`

**问题**
translate mode 本质上完全依赖 LLM prompt，但当前逻辑是：
- 没有 LLM：`process()` 返回 `rawText`
- 然后继续走 `TextFormatter`
- 最终照常 paste，并且 history 记成 translation record

也就是：
- 用户打开了“Translate Mode”
- 实际贴出去的仍然是原文/原语言
- history 还标记成翻译

**影响**
- 用户会误信输出已翻译
- translation history 数据不可信

**建议**
- `Translate Mode` 打开前就校验 `llm.isConfigured`
- 若未配置，菜单项禁用或点击时提示
- LLM 失败时，不要贴原文冒充翻译；应提示失败并中止

---

### 3) Voice Settings 切换 LLM provider 时会把 key 缓存到错误的 provider 上
**位置**
- `VoiceSettingsVC.llmProviderChanged()`

**问题**
这里写的是“切换前缓存当前 key”，但代码取的是：

```swift
let prevIdx = llmPopup.indexOfSelectedItem
```

这个 action 触发时，`indexOfSelectedItem` 已经是**新选项**了，不是旧选项。

所以结果是：
- A provider 的 key，可能被存到 B provider 的 cache
- 切来切去会出现 key 丢失 / 串线 / 保存错 provider

**影响**
- 非常隐蔽的配置错误
- 用户会觉得“设置页不可信”

**建议**
- 跟 `SetupWindow` 一样，加 `lastLLMIndex`
- 先用旧 index 保存，再切换显示

---

### 4) Setup 里 `qwen-llm` 的 key 逻辑在 ASR 不是 qwen 时是错的
**位置**
- `SetupWindow.validateAndSaveConfig()`
- `SetupWindow.applyConfigState()`
- `SetupWindow.saveConfig()`
- `SetupWindow.llmProviderChanged()`

**问题**
`Alibaba Qwen (Same key as ASR)` 被实现成直接读取 `asrKeyField`。
但 `asrKeyField` 在不同 ASR provider 下语义不同：

- ASR = qwen：它是 qwen ASR key
- ASR = custom：它变成 custom ASR key
- ASR = whisper：这一行甚至隐藏了

所以如果用户：
- ASR 用 Whisper / Custom
- LLM 选 qwen-llm

那 setup 里要么拿到**错误 key**，要么拿到**空值**，而且校验还把 `qwen-llm` 排除在必填之外。

**影响**
- 配置看似成功，运行时才失败
- 很难排查

**建议**
- 不要把 `qwen-llm` 绑定到“当前 ASR 输入框”
- 要么单独维护 `qwenKey`
- 要么只有在 `ASR == qwen` 时才显示“same key as ASR”捷径
- 否则就显示独立 key 输入

---

### 5) 粘贴目标没有被锁定；用户处理中切 app 会贴到错误地方
**位置**
- `DictationCoordinator.stopAndProcess()`
- `PasteService.paste(...)`
- `DictationCoordinator.selectLastInsertedText()`

**问题**
当前只在 stop 时捕获了 `contextHint`，但**没有捕获目标 app / target element**。
之后真正 paste 时，是向“当前前台 app”发 `Cmd+V`。

所以如果用户：
- 录完音后等待 1~3 秒
- 期间切到别的 app / 别的窗口

那文本就会贴到新位置。后面的 edit window 还会基于新的焦点去选尾部文本。

**影响**
- 这类 bug 用户感知非常强：“Vox 会乱贴”
- edit mode 也会跟着选错对象

**建议**
- stop 时记录 `frontmost pid + bundle id`，paste 前校验是否还是同一个目标
- 更进一步：记录目标 AX element / 选择范围快照
- 若目标已变化，至少提示“请切回原输入位置后重试”

---

### 6) 粘贴是否成功没有返回值，但后续逻辑都按“成功”处理
**位置**
- `PasteService.paste(...)`
- `DictationCoordinator.stopAndProcess()`
- `DictationCoordinator.stopAndProcessEdit()`

**问题**
`paste()` 返回 `Void`，而 coordinator 在调用后立刻：
- 加 history
- 进入 edit window
- 更新 `lastInsertedText/Length`

但现实里 paste 可能失败：
- 无 Accessibility
- CGEvent 发出但目标 app 没接收
- osascript fallback 失败
- 焦点不在可粘贴区域

**影响**
- history 记录与真实插入不一致
- edit window 会去选择“并不存在的刚插入文本”，可能选中原文尾部别的内容

**建议**
- `PasteService` 返回 `Result<Void, VoxError>` 或 `Bool`
- 只有 paste 成功时才：
  - add history
  - 更新 lastInsertedText
  - 开 edit window

---

### 7) API key 和敏感内容处理不够安全
**位置**
- `~/.vox/config.json`
- `VoiceSettingsVC` / `SetupWindow` 里的 API key 输入框
- `LogService`, `STTService`, `LLMService`, `ContextService`

**问题**
- API key 明文保存在 `config.json`
- UI 用的是 `NSTextField`，不是 `NSSecureTextField`
- log 里会写：
  - 原始转写文本
  - LLM 结果
  - frontmost app / URL
  - provider 原始响应前 500 字

**影响**
- 本地隐私风险很高
- debug.log 是长期累积的“隐私黑盒”

**建议**
- 密钥迁到 **Keychain**
- UI 改 `NSSecureTextField` + reveal toggle
- 日志默认脱敏：
  - 不记正文
  - 只记长度 / provider / status code / error code
- debug logging 改成显式开关，并加 rotate

---

## P2：建议尽快跟进

### 8) 音频临时文件 / 备份文件名只精确到秒，会撞名
**位置**
- `AudioService.startRecording()`
- `AudioService.saveBackup(...)`

**问题**
文件名都用：

```swift
Int(Date().timeIntervalSince1970)
```

如果 1 秒内发生两次录音/测试/备份：
- `/tmp/vox-xxx.wav` 会撞
- `~/.vox/audio/vox-xxx.wav` 也会撞
- `copyItem` 会失败

**建议**
- 改成 `UUID().uuidString`
- 或毫秒级时间戳
- `stopRecording()` 后顺手清空 `currentURL`

---

### 9) Settings 里的测试录音会泄漏临时文件，还会污染 Black Box
**位置**
- `GeneralSettingsVC.stopTestRecording()`
- `SetupWindow.testRecordToggle()`

**问题**
- `GeneralSettingsVC` 测试后没有删除临时音频
- 两处测试都走 `stopRecording()` 默认 `backup: true`
- 结果：测试录音也会进 `Black Box`

**建议**
- 测试场景统一 `stopRecording(backup: false)`
- 转写结束后删除 temp file

---

### 10) “OpenAI-compatible” 实现不够通用
**位置**
- `OpenAIProvider.complete(...)`

**问题**
请求体固定带：

```swift
"enable_thinking": false
```

这对 Qwen 兼容接口也许有用，但对很多严格的 OpenAI-compatible 服务，可能是**非法字段**。

**影响**
- “自定义 OpenAI-compatible” 的承诺会被打破

**建议**
- 只对已知 provider 注入额外字段
- 或把 extra params 做成 provider-specific config

---

### 11) 长音频 chunk 结果直接 `joined(separator: "")`，英文会粘连
**位置**
- `STTService.transcribeChunked(...)`

**问题**
多个 chunk 结果拼接时无分隔符：

```swift
let combined = results.joined(separator: "")
```

中文问题小一些，英文/混合语音很容易出现：
- `hello` + `world` => `helloworld`

**建议**
- 至少 `joined(separator: "\n")` 或 `" "`
- 更好是按 provider 返回尾部标点做启发式拼接

---

### 12) 云 ASR 路径把合法的单字结果直接丢掉了
**位置**
- `STTService.transcribe(...)`

**问题**
对 cloud provider：

```swift
if trimmed.count < 2 { return "" }
```

这会把很多合法输入丢掉，比如：
- “好”
- “嗯”
- “是”
- “发”

**建议**
- 不要用长度当总规则
- 用更精确的 hallucination pattern 过滤

---

### 13) edit 流缺少和主链路一致的“静音检测”
**位置**
- `DictationCoordinator.stopAndProcessEdit()`

**问题**
普通 dictation 会检查：
- 文件过短
- `audio.hasAudio`

edit 流只检查了文件大小，没检查 `hasAudio`。

**影响**
- 无声但较长的 edit 指令也会打到 STT/LLM
- 增加误识别和成本

**建议**
- 复用主链路的 silence gate

---

### 14) 子进程 stderr 不消费，存在卡死风险
**位置**
- `WhisperLocalProvider.transcribe(...)`
- `STTService.splitAudio(...)`

**问题**
`standardError = Pipe()`，但没人读。
像 `whisper-cli` / `ffmpeg` 这类工具如果 stderr 输出多，pipe buffer 满了会把子进程阻塞住。

**建议**
- stderr 重定向到 stdout
- 或异步 drain
- 或直接丢到 `/dev/null`

---

### 15) Accessibility 自动 reset 策略过于激进，且对 sandbox/发行形态不友好
**位置**
- `AppDelegate.resetAccessibilityIfVersionChanged()`

**问题**
- 只要版本变化且当前 trusted，就直接 `tccutil reset`
- bundle id 还写死为 `"com.justin.vox"`
- 启动时同步 `waitUntilExit()`

**风险**
- 每次升级都把权限打掉，UX 抖动
- dev/release bundle id 不一致时无效
- 未来 sandbox / MAS 基本不适配

**建议**
- 改成用户可触发的 repair action
- bundle id 动态取 `Bundle.main.bundleIdentifier`
- 避免主线程同步等待外部进程

---

### 16) StatusOverlay 固定用 `NSScreen.main`，多显示器下容易出现在错误屏幕
**位置**
- `StatusOverlay.positionAndShow(...)`

**建议**
- 用鼠标所在屏幕
- 或前台 app/window 所在屏幕

---

### 17) `ContextService.detect()` 自己要求主线程，但 Black Box reprocess 里不是这样调用
**位置**
- `ContextService.detect()`
- `BlackBoxWindowController.reprocessAudio(...)`

**建议**
```swift
let appContext = await MainActor.run { ContextService.shared.detect() }
```

---

## P3：可作为演进输入

### 18) 配置层已经出现“多套真相”
**现象**
- 有 `VoxConfig` typed model
- 但真实读写走的是 `ConfigService.raw [String: Any]`
- `SetupWindow`、`VoiceSettingsVC`、`ConfigService` 各自手写 schema / 迁移 / 保存逻辑

这已经直接引出了上面的 provider/key bug。

**建议**
- 收敛到一套 typed config + validator
- UI 层只编辑 view model
- 持久化由单点负责

---

### 19) 用空字符串和 `Void` 作为错误通道，导致用户体验和状态处理都变脆
**现象**
- STT 返回 `String`
- LLM 返回 `String`
- paste 返回 `Void`

所以现在：
- `""` 可能代表无语音、API 错、网络错、解析错
- edit/translate 场景无法区分“可以 fallback”还是“必须失败”
- paste 失败后也无法阻断后续流程

**建议**
改成：
- `async throws`
- 或 `Result<T, VoxError>`

这会显著改善：
- 错误提示
- 状态机
- 可测试性

---

### 20) `DictationCoordinator` 很适合明确标注为 `@MainActor`
现在它同时管理：
- phase/state
- overlay/timer/monitor
- 录音开始停止
- UI 反馈

而异步任务里又频繁 `MainActor.run` 来回切。

**建议**
- coordinator 设为 `@MainActor`
- STT/LLM provider 保持后台执行
- 这样 race 和 UI 状态漂移会少很多

---

## 一句话优先级建议

### 第一批就修
1. **edit/translate 的 LLM 依赖建模错误**
2. **VoiceSettingsVC provider 切换 bug**
3. **SetupWindow qwen-llm key bug**
4. **paste success / target locking**
5. **Keychain + secure field + log 脱敏**

### 第二批
6. 文件命名/临时文件/测试备份
7. OpenAI-compatible 请求体收敛
8. chunk 拼接 / 单字过滤
9. TCC reset 与多显示器 overlay

---

如果你愿意，我下一轮可以继续做两件更实用的事之一：

1. **给出一个“按优先级排序的修复 patch plan”**  
2. **直接列出可改的代码级 patch（按文件/函数）**
