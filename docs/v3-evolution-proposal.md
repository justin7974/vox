# Vox Evolution Proposal

> 基于: v3-review-report.md (三方交叉审阅) + 竞品研究 + 技术研究
> 日期: 2026-04-14

## 核心定位确认

v3.0 的方向是对的：**只做语音输入，做到极致**。

竞品分析显示 Vox 已经有两个独一无二的差异化优势：

1. **上下文感知后处理** — 检测前台 App/浏览器标签页，自动调整 LLM 输出语气（正式/口语/技术）。竞品中只有 Wispr Flow 接近这个方向，但它只做 coding conventions，不做通用语气适配
2. **语音编辑窗口** — 粘贴后再按一次热键，语音说出修改指令，LLM 执行编辑。无竞品有此功能

这两个优势应该继续深化，而不是追求覆盖面。

## Evolution 路线图

### Phase 1: 稳固基础（Bug Fix Sprint）

**目标**: 修复 review 发现的 P0/P1 问题，消除日常使用中的隐患。

| # | 修复项 | 预估工作量 | 依赖 |
|---|--------|-----------|------|
| 1 | Edit/Translate LLM fallback 改为中止 | 30 min | 无 |
| 2 | AppleScript context.detect() 移到后台 | 30 min | 无 |
| 3 | VoiceSettingsVC key 缓存 bug | 15 min | 无 |
| 4 | SetupWindow qwen-llm key 逻辑 | 30 min | 无 |
| 5 | 状态机 transition -> Bool | 45 min | 无 |
| 6 | AudioService 防重入 | 15 min | 无 |
| 7 | Edit Window 加 local monitor | 15 min | 无 |
| 8 | 死代码清理 (VoxConfig/FloatingPanel/VoxError) | 15 min | 无 |

**总计**: ~3.5 小时，全部独立可并行

### Phase 2: 用户词库（最高 ROI 新功能）

**问题**: "Claude" 被识别为 "Cloud"、"红杉" 被识别为 "鸿杉" 等高频词错误严重影响体验。

**方案**: 三层防线

```
层 1: ASR 词库注入
    ↓
层 2: LLM 后处理词库
    ↓
层 3: 纠错历史学习
```

#### 层 1: Qwen ASR System Context 注入（~50 LOC，最高 ROI）

技术研究确认 Qwen ASR 的 chat/completions 接口支持 system role context。在 `QwenASRProvider.transcribe()` 的请求体中加一条 system message，包含用户自定义词表：

```json
{
  "role": "system",
  "content": "以下是用户的常用专有名词，请在转录时优先识别：Claude, 红杉, Sequoia, MiniMax, Term Sheet, Cap Table, LLM, ARR, MRR"
}
```

词表来源: `~/.vox/dictionary.json`（数组格式，用户可手动编辑）

#### 层 2: LLM 后处理词库注入（~20 LOC）

在 `LLMService.buildSystemPrompt()` 中，读取同一个 `dictionary.json`，追加到 prompt：

```
用户的专有名词列表（优先使用这些写法）：Claude, 红杉, MiniMax, ...
```

替代现在硬编码在 prompt 里的纠错列表（"鸿杉→红杉"）。

#### 层 3: 纠错历史自动学习（Phase 2.5，可延后）

利用 edit window 的纠正记录：当用户编辑了刚粘贴的文字，对比 `originalText` 和 `editedText`，提取 diff，自动更新 `dictionary.json`。

需要 UI：Settings 中加一个 Dictionary 管理界面（查看、编辑、删除词条）。

### Phase 3: 深度上下文感知

**当前**: ContextService 检测前台 App → 一句话 hint 追加到 LLM prompt

**升级**: 读取当前输入框的已有文本，作为 LLM 上下文

技术研究确认这是可行的：

- Vox 已经在 edit mode 中使用 `AXUIElementCopyAttributeValue(element, kAXValueAttribute)` 读取输入框内容
- 复用同样的 AX 调用，在 `stopAndProcess()` 中读取最后 500 字符
- 传给 LLM 作为 "前文上下文"

```swift
// DictationCoordinator.stopAndProcess() 中，在 context.detect() 之后
let surroundingText = readFocusedFieldText(maxChars: 500)
// 传给 LLM: "用户已经输入的内容（前文）：\(surroundingText)"
```

**价值**: LLM 可以：
- 保持前文的人称/语气一致性
- 识别正在讨论的话题，避免歧义词错误
- 在邮件场景中推断收件人关系（称呼、敬语级别）

**隐私注意**: 需要在设置中加一个开关（默认关）。用户开启后告知"当前输入框内容会发送给 LLM API"。

### Phase 4: 离线本地模型 Fallback

竞品分析显示 Superwhisper、Voibe、Apple Dictation 都提供离线模式。Vox 目前完全依赖云端 ASR。

**方案**: 利用 macOS 原生 Speech Framework

macOS Tahoe 的 `SFSpeechRecognizer` 支持 on-device 识别（Apple Silicon），据报比 Whisper 快 55%，且免费无 API 成本。

```swift
// 新增 AppleSpeechProvider: STTProvider
struct AppleSpeechProvider: STTProvider {
    let name = "apple"
    func transcribe(audioFile: URL) async -> String {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-Hans"))
        recognizer?.supportsOnDeviceRecognition // 确认 on-device 可用
        // ...
    }
}
```

**定位**: 不替代 Qwen ASR（云端精度更高），而是作为：
- 离线 fallback（无网络时自动切换）
- 短输入加速器（<10s 的输入走本地，0 延迟）

### Phase 5: 可选的进阶功能

根据竞品研究，以下功能值得考虑但优先级较低：

#### 5a. Voice Snippets（语音快捷短语）

参考 Wispr Flow 的 voice shortcuts：用户说 "插入免责声明" → 插入预设文本块。

实现：`~/.vox/snippets.json` + LLM intent 匹配（或简单的关键词触发）。

#### 5b. 剪贴板恢复

Review 三方共识。paste 前保存剪贴板内容，paste 后异步恢复。

#### 5c. 可搜索历史 + 音频回放

参考 Superwhisper 的全文搜索 + 分段音频回放。Vox 的 Black Box 已有音频备份基础设施。

#### 5d. 多语言快速切换

Menu bar 加语言切换（中/英/日），避免 Whisper 的 `-l zh` 硬编码。

## 不做清单

基于竞品分析和产品定位，以下方向明确不做：

| 不做 | 理由 |
|------|------|
| 会议转录 / Speaker Diarization | 与 Notta/Otter 竞争是错误定位，Vox 是个人输入工具 |
| 实时流式 ASR | 技术研究确认当前"录完再处理"的 UX 更适合 dictation 场景，流式 ASR + LLM 后处理会有 error propagation |
| 浏览器插件 / Web 版 | macOS native 是核心优势，跨平台分散精力 |
| 企业功能 / SSO / SOC 2 | 个人工具，不追求合规认证 |
| Launcher / Clipboard / Actions | v3.0 已确认砍掉 |

## 优先级总结

```
Phase 1 (now)     → Bug fix sprint (P0/P1，~3.5h)
Phase 2 (next)    → 用户词库 3 层防线 (~2h for 层1+2)
Phase 3 (after)   → 深度上下文感知 (~1h)
Phase 4 (later)   → 离线本地 ASR fallback (~3h)
Phase 5 (backlog) → Snippets / 剪贴板恢复 / 可搜索历史 / 多语言
```

Phase 1-3 可以在一个 session 内完成（~6.5h），且每个 phase 独立可交付。
