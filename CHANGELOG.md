# Vox Changelog — Cross-Platform Feature Tracker

> macOS 为主开发端，Windows 按此清单对齐移植。每条标注平台状态。

## Feature Status

| # | Feature | macOS | Windows | Notes |
|---|---------|:-----:|:-------:|-------|
| - | Core pipeline (hotkey→ASR→LLM→paste) | ✅ v2.0 | 📋 planned | Windows 计划见 plan file |
| - | Setup wizard (5-step onboarding) | ✅ v2.0 | 📋 planned | |
| - | Custom hotkey + Hold-to-Talk | ✅ v2.0 | 📋 planned | Windows 用 WH_KEYBOARD_LL |
| - | Audio level visualization (30 bars) | ✅ v2.0 | 📋 planned | |
| - | Status overlay (recording/processing) | ✅ v2.0 | 📋 planned | |
| 1 | Context-aware prompt (app/URL detection) | ✅ v2.1 | 📋 | NSWorkspace → Windows equivalent |
| 2 | Translate mode (CN↔EN toggle) | ✅ v2.1 | 📋 | |
| 3 | Multi-segment accumulation | ❌ skip | ❌ skip | Not needed |
| 4 | Personal vocabulary | ⏸ deferred | ⏸ deferred | Uncertain ROI |
| 5 | Recording waveform overlay | ❌ skip | ❌ skip | Current status indicator is sufficient |
| 6 | Result preview window | ❌ skip | ❌ skip | Not needed |
| 7 | History records | ✅ v2.5 | 📋 | HistoryManager + HistoryWindow + Setup step |
| 8 | Custom ASR/LLM providers | ✅ v2.5 | 📋 | Open interface: any Whisper API / OpenAI / Anthropic compatible endpoint |
| 9 | Silence detection (auto-stop) | ❌ skip | ❌ skip | Not needed for now |
| 10 | Recording time limit | ❌ skip | ❌ skip | Not needed for now |
| 11 | Prompt templates | ❌ skip | ❌ skip | Low demand, reconsider if requested |
| 12 | Shortcuts integration | ❌ skip | ❌ skip | Low ROI |
| 13 | Multi-hotkey binding | ❌ skip | ❌ skip | Low ROI |

### Legend

- ✅ = implemented
- 📋 = planned / to be ported
- ⏸ = deferred
- ❌ = skipped

## Version History

### macOS

| Version | Date | Changes |
|---------|------|---------|
| v2.0 | 2026-02-28 | Brand rename to Vox, onboarding wizard, custom hotkey, hold-to-talk |
| v2.1 | 2026-02-28 | Context-aware prompt, translate mode, hotkey save fix |
| v2.5 | 2026-02-28 | History records, custom ASR/LLM providers, config dir rename (~/.vox), Qwen ASR hallucination fix |

### Windows

| Version | Date | Changes |
|---------|------|---------|
| — | — | Development not started |
