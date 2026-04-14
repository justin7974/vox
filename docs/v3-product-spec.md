# Vox v3.0 Product Specification

> Reverse-engineered from codebase as of 2026-04-14. 29 files, 7,434 lines Swift.

## Product Identity

**Vox** is a macOS menu bar app for system-wide voice input. It records speech via a global hotkey, transcribes it through configurable ASR providers, optionally post-processes the text with an LLM (punctuation, formatting, context-aware tone), and pastes the result into any app via simulated Cmd+V.

**Core philosophy (v3.0):** Only do voice input. Do it extremely well. No launcher, clipboard manager, or action system — those were cut in v3.0 (-3,219 lines).

## Feature Inventory

### 1. Voice Dictation (Core Loop)

**State machine:** `idle → recording → transcribing → postProcessing → pasting → [editWindow] → idle`

**Flow:**

1. User presses global hotkey
2. StatusOverlay appears with red pulsing dot + "正在聆听…"
3. Audio recorded at 16kHz mono WAV via AVAudioRecorder
4. User releases hotkey (hold mode) or presses again (toggle mode)
5. Audio sent to ASR provider → raw transcription
6. Raw text sent to LLM provider → polished text (or TextFormatter fallback if no LLM)
7. Text placed on clipboard → Cmd+V simulated via CGEvent
8. History record saved

**Audio safeguards:**

- File < 16KB → too short, ignored
- Peak power < -50 dB → no audio detected, user notified
- Whisper hallucination filter (subtitle patterns, single-char repetitions)

### 2. Edit Window

After pasting, if enabled (default: on, 3s duration):

- StatusOverlay shows blue pulsing dot + "再按一次可修改" with countdown bar
- User can re-press hotkey within the window to enter **edit mode**
- Edit mode: last inserted text is selected via Accessibility API (AXSelectedTextRange), user speaks an edit instruction ("把第一句删掉", "改正式一点"), LLM applies the edit, result replaces selection
- Any other keyboard input cancels the edit window
- Timer expiry auto-dismisses

### 3. Translate Mode

Toggle in menu bar: "Translate Mode (中→EN)"

- Chinese input → English output (and vice versa)
- Uses a dedicated `translatePrompt`
- Translation records saved with `originalText` for reference
- Edit window disabled in translate mode

### 4. Context-Aware Post-Processing

`ContextService` detects the frontmost app + browser tab URL:

- **Browser URL detection** via AppleScript (Chrome, Safari, Arc, Firefox, Edge, Brave, Vivaldi)
- **App bundle ID matching** for native apps
- Generates context hints appended to LLM system prompt:
  - Email (Gmail/Outlook/Mail) → formal tone
  - Chat (WeChat/Discord/Telegram/Slack) → casual tone
  - Code (VS Code/Xcode/Terminal) → technical, concise
  - Documents (Notion/Google Docs) → structured, written
  - Notes → minimal processing
  - Social media → short and punchy

### 5. Long Audio Chunking (v2.9+)

`STTService` handles provider-agnostic audio chunking:

- Provider declares `maxAudioFileBytes` (e.g., QwenASR: 7MB due to base64 inflation)
- If file exceeds limit → `ffmpeg -f segment -segment_time 180` splits into 3-min chunks
- Each chunk transcribed sequentially, results concatenated
- Fallback to single request if ffmpeg fails

### 6. History

- Records saved to `~/.vox/history.json` (JSON, newest-first)
- Configurable retention (default: 7 days, 0 = forever)
- Grouped-by-day table view with copy/delete per record
- Translation records show both original and translated text

### 7. Black Box

Disaster recovery for voice recordings:

- Last 5 audio files backed up to `~/.vox/audio/`
- Playback (AVAudioPlayer) and reprocess capabilities
- Duration estimated from file size (bytes / 32000)

### 8. Setup Wizard

6-step onboarding: Welcome → Hotkey Mode → API Config → History Settings → Test → Complete

- ASR providers: Alibaba Qwen ASR, Local Whisper, Custom (OpenAI-compatible)
- LLM providers: Kimi, Qwen LLM, MiniMax (CN/Global), plus manual configuration for Anthropic/OpenAI-compatible APIs
- Hotkey mode selection: toggle vs. hold
- Test recording with live audio level visualization

### 9. Settings Window

4-tab settings: General, Voice, History, About

- **General:** Hotkey configuration (custom recorder view), hotkey mode (toggle/hold), edit window toggle + duration, user context for prompt personalization
- **Voice:** ASR provider selection + API key fields, LLM provider selection + API key/URL/model fields, test button
- **History:** Enable/disable, retention period, clear all
- **About:** Version, links

## Architecture

```
┌─────────────────────────────────────────┐
│              AppDelegate                │
│  (menu bar, hotkey delegate, app lifecycle)│
├─────────────────────────────────────────┤
│         DictationCoordinator            │
│  (state machine, pipeline orchestration) │
├──────────┬──────────┬───────────────────┤
│ Services │          │       UI          │
├──────────┤          ├───────────────────┤
│AudioSvc  │ STTSvc   │StatusOverlay      │
│ConfigSvc │ LLMSvc   │FloatingPanel      │
│ContextSvc│ PasteSvc │HistoryWindow      │
│HistorySvc│ HotkeySvc│BlackBoxWindow     │
│ LogSvc   │          │SetupWindow        │
│          │          │SettingsWindow     │
└──────────┴──────────┴───────────────────┘
```

**Key patterns:**

- Singleton services (`static let shared`)
- Protocol-based providers (STTProvider, LLMProvider) — pluggable ASR/LLM backends
- Carbon Event API for global hotkeys (not NSEvent — more reliable for hotkey registration)
- CGEvent for Cmd+V paste simulation (with osascript fallback)
- Accessibility API for edit mode text selection
- Config stored as flat JSON in `~/.vox/config.json` (no CoreData/SwiftData)
- LSUIElement app (no Dock icon) — requires manual Edit menu setup for Cmd+C/V/X/A

## ASR Providers

| Provider | Transport | Audio Format | Max File | Language |
|----------|-----------|-------------|----------|----------|
| Whisper Local | CLI subprocess | WAV file path | Unlimited | zh (hardcoded) |
| Qwen ASR | REST (data URI) | Base64 WAV/OGG/MP3 | 7MB raw (~10MB b64) | zh |
| Custom (Whisper API) | REST (multipart) | Binary upload | Unlimited | Model-dependent |

## LLM Providers

| Format | Providers | Auth Header |
|--------|-----------|-------------|
| Anthropic | Anthropic, Kimi, MiniMax | x-api-key |
| OpenAI | Qwen LLM, any OpenAI-compatible | Bearer token |

Auto-detection: URL contains `/chat/completions` → OpenAI format; otherwise Anthropic. Override via `format` field in config.

## Configuration

All config in `~/.vox/`:

| File | Purpose |
|------|---------|
| `config.json` | All settings (hotkey, ASR, LLM, history, edit window) |
| `prompt.txt` | User-editable LLM system prompt (with comments as documentation) |
| `history.json` | Dictation history records |
| `audio/` | Last 5 audio backups |
| `debug.log` | Debug log (append-only) |
| `.last-authorized-version` | TCC version tracking for accessibility permission reset |

Migrates from legacy `~/.voiceinput/` directory automatically.

## Permissions Required

1. **Accessibility** (AXIsProcessTrusted) — for Cmd+V paste simulation and edit mode text selection
2. **Microphone** — for audio recording
3. **Automation/AppleScript** — for browser URL detection (optional, degrades gracefully)
4. **Notifications** — for error/status notifications (optional)

TCC permission version tracking: on version change, resets stale accessibility entry via `tccutil reset` so macOS re-prompts correctly.

## Known Limitations

1. **Whisper language hardcoded to zh** — `WhisperLocalProvider` passes `-l zh`, no language selection in UI
2. **Sequential chunk transcription** — long audio chunks processed one-by-one, could parallelize
3. **No streaming ASR** — full recording → full transcription, no real-time partial results
4. **Paste via clipboard** — overwrites user's clipboard content (no restore)
5. **Edit mode relies on Accessibility API** — may fail in apps with non-standard text fields (e.g., some Electron apps)
6. **No audio format selection** — always records 16kHz mono WAV, not compressed
7. **Single hotkey** — only one hotkey for dictation (no separate translate hotkey)
8. **No multi-language detection** — ASR provider handles language detection implicitly, no explicit multi-language support
9. **Log file grows unbounded** — `debug.log` is append-only with no rotation
10. **FloatingPanel class unused** — base class for removed Launcher/Clipboard panels, still in codebase (dead code)
11. **VoxError has orphan cases** — `actionFailed` and `intentMatchFailed` are from removed Action system, never thrown in v3.0

## File Inventory (29 files, 7,434 lines)

### Core (3 files, 137 lines)
- `VoxPhase.swift` (56) — State machine with validated transitions
- `VoxConfig.swift` (55) — Config model structs (Codable)
- `VoxError.swift` (25) — Error enum

### Services (9 files, 1,710 lines)
- `STTService.swift` (474) — 3 ASR providers + chunking + hallucination filter
- `LLMService.swift` (432) — 2 LLM providers + prompt management
- `AudioService.swift` (129) — AVAudioRecorder + backup management
- `ContextService.swift` (148) — App/browser context detection
- `ConfigService.swift` (124) — JSON config R/W + migration
- `HotkeyService.swift` (138) — Carbon hotkey registration
- `HistoryService.swift` (115) — History CRUD + auto-cleanup
- `PasteService.swift` (102) — Clipboard + CGEvent Cmd+V
- `LogService.swift` (48) — File + NSLog dual logging

### Coordinators (1 file, 397 lines)
- `DictationCoordinator.swift` (397) — Pipeline orchestration + edit window logic

### UI (9 files, 3,168 lines)
- `SetupWindow.swift` (1,674) — 6-step setup wizard (largest file)
- `HistoryWindowController.swift` (508) — History browser
- `StatusOverlay.swift` (429) — Floating status indicator
- `BlackBoxWindowController.swift` (336) — Audio backup viewer
- `Settings/SettingsWindowController.swift` (253) — Tab-based settings
- `Settings/VoiceSettingsVC.swift` (383) — ASR/LLM config
- `Settings/GeneralSettingsVC.swift` (254) — Hotkey/edit window config
- `Settings/HistorySettingsVC.swift` (320) — History config
- `Settings/SettingsUI.swift` (210) — Shared UI helpers
- `Settings/AboutSettingsVC.swift` (100) — About tab

### Other (2 files, 22 lines)
- `AppDelegate.swift` (277) — App lifecycle + menu bar
- `main.swift` (6) — Entry point
- `FloatingPanel.swift` (138) — Base panel class (partially dead code)
- `AudioLevelView.swift` (61) — Audio level visualizer
- `HotkeyRecorderView.swift` (160) — Custom hotkey capture view
- `TextFormatter.swift` (82) — Fallback formatting (CJK spacing, punctuation)
