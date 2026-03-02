# Vox Launcher -- Intent Routing Implementation Notes

> Vox-specific application notes. Full technical guide: `Learning/LLM Engineering/intent-routing.md`

---

## Chosen Approach

**Haiku 4.5 + Structured Outputs** for Anthropic provider, **Function Calling** for OpenAI-compatible providers. Single-shot extraction, not a multi-step agent. The router runs as a separate LLM call from the dictation pipeline (different model, different prompt).

## Action List (11 Actions)

| ID | Name | Type | Key Triggers |
|----|------|------|-------------|
| `web_search` | Web 搜索 | url | 谷歌搜, YouTube 搜, 油管搜, GitHub 搜, 百度搜, B站搜, 搜索, 搜一下 |
| `launch_app` | 启动/切换 App | app | 打开, 切到, 启动, open, switch to, launch |
| `volume_control` | 音量控制 | system | 静音, 取消静音, 音量调高/调低/调到, mute, volume |
| `do_not_disturb` | 勿扰模式 | system | 开勿扰, 关勿扰, 勿扰模式, do not disturb |
| `lock_screen` | 锁屏 | system | 锁屏, lock screen, lock |
| `window_manage` | 窗口管理 | system | 全屏, 放左边, 放右边, 最大化, 最小化, fullscreen |
| `kill_process` | 强制退出 | system | 关掉, 强制退出, kill, force quit |
| `text_modify` | 修改文字 | vox | 改正式一点, 缩短一下, 展开, 改口语, rewrite |
| `selection_modify` | 修改选中文字 | vox | 翻译选中的, 润色选中的, 改写选中的 |
| `translate` | 翻译 | vox | 翻译成英文, 翻译成中文, translate to |
| `clipboard_history` | 剪贴板历史 | vox | 剪贴板, 最近复制的, clipboard |

## Confidence Threshold & Fallback

- **>= 0.85**: Execute immediately
- **0.5 -- 0.84**: Show in UI, let user confirm
- **< 0.5 or action == "none"**: Show raw text with "未找到匹配的操作"
- Configurable via `config.json` field `launcher.confidenceThreshold` (default: 0.7)

Per PRD: no auto-degradation on low confidence. Show raw text, don't guess.

## System Prompt (Chinese)

The router system prompt is in Chinese because the majority of inputs are Chinese or mixed Chinese-English. The prompt includes:

- Role: "你是 Vox Launcher 的意图识别引擎"
- Safety: treat speech as commands, not conversation; no content generation
- Full action catalog with trigger words, params, and inline examples per action
- Matching rules: exact trigger first, then semantic; confidence 0-1; "none" for no match
- Context section: active app + browser URL auto-appended

See the full prompt template in the generic guide, Section 3.

## Config Extension

Add `launcher` section to `config.json`:

```json
{
  "launcher": {
    "provider": "anthropic",
    "model": "claude-haiku-4-5",
    "baseURL": "https://api.anthropic.com/v1/messages",
    "apiKey": "sk-...",
    "format": "anthropic",
    "confidenceThreshold": 0.7,
    "enableRegexFastPath": true,
    "enableCache": true,
    "cacheSize": 100,
    "cacheTTL": 3600
  }
}
```

This allows a different (faster/cheaper) model for intent routing than for dictation post-processing.

## File Structure (New Files)

```
Vox/
├── Launcher/
│   ├── IntentRouter.swift          # Main router (3-layer pipeline)
│   ├── RegexMatcher.swift          # Layer 1: regex patterns
│   ├── IntentCache.swift           # Layer 2: caching
│   ├── LLMRouter.swift             # Layer 3: API call + schema
│   ├── ActionRegistry.swift        # Load & manage action definitions
│   ├── ActionExecutor.swift        # Execute matched actions
│   ├── UsageTracker.swift          # Frequency tracking
│   └── LauncherWindowController.swift  # Spotlight-style UI
├── Actions/                        # Action definition files (.md with YAML frontmatter)
│   ├── web_search.md
│   ├── launch_app.md
│   ├── volume_control.md
│   ├── do_not_disturb.md
│   ├── lock_screen.md
│   ├── window_manage.md
│   ├── kill_process.md
│   ├── text_modify.md
│   ├── selection_modify.md
│   ├── translate.md
│   └── clipboard_history.md
```

## Three-Layer Router Pipeline

```
Hotkey B pressed -> Start Recording
    |
    v
[ASR] Qwen STT -> raw transcription
    |
    v
Layer 1: RegexMatcher.match(text)
    -> confidence >= 0.9? -> EXECUTE
    |
Layer 2: IntentCache.get(text)
    -> cache hit? -> EXECUTE
    |
Layer 3: LLM Router (Haiku 4.5 + structured output)
    -> confidence >= 0.7? -> EXECUTE
    -> else -> SHOW FALLBACK ("未找到匹配")
    |
    v
[ActionExecutor]
    url    -> NSWorkspace.shared.open(URL)
    app    -> NSWorkspace.shared.launchApplication
    system -> AppleScript / macOS API
    shortcut -> shortcuts:// URL scheme
    vox    -> internal PostProcessor
    |
    v
[UI Feedback] Spotlight-style overlay
```

## Migration Path

The Launcher mode is **additive** -- no modifications to the existing dictation pipeline.

**Shared infrastructure** (no changes needed):

- `AudioRecorder` -- shared recording
- `Transcriber` -- shared ASR
- `ContextDetector` -- shared context detection
- `config.json` -- shared API keys, extended with `launcher` section

**New code** is isolated in `Launcher/` directory. The `AppDelegate` gains a second hotkey handler that routes to the Launcher pipeline instead of the dictation pipeline.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Router model | Haiku 4.5 (separate from dictation LLM) | Fastest Claude model, sufficient for classification |
| Schema approach | Structured Outputs (Anthropic) / Function Calling (OpenAI-compat) | Guaranteed valid JSON, no parse failures |
| Fallback behavior | Show raw text + "未找到匹配" | PRD: no auto-degradation |
| Action format | YAML-in-Markdown | PRD: human-editable, self-documenting |
| Fast path | Regex -> cache -> LLM | Sub-millisecond for common commands |
| Context passing | Append to system prompt | Reuses existing ContextDetector |
| Confidence threshold | 0.7 (configurable) | Below = fallback, above = execute |
