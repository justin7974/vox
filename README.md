# Vox

AI-powered voice input for macOS. Press a hotkey, speak, and text appears at your cursor.

[English](#english) | [中文](#中文)

<!-- TODO: Add demo GIF here -->
<!-- ![Demo](demo.gif) -->

---

## English

**How it works:** Hotkey → Record → Cloud ASR → LLM cleanup → Paste at cursor

### Features

- Customizable global hotkey — works in any app
- Hold-to-talk or toggle mode
- Cloud ASR via Alibaba Qwen3-ASR-Flash (fast, accurate, great for Chinese-English mixed input)
- Optional LLM post-processing (removes filler words, fixes typos, adds punctuation)
- Automatic text formatting (Chinese-English spacing, punctuation normalization)
- Multi-step onboarding wizard — easy first-time setup
- Audio waveform visualization during recording
- Menubar app — runs quietly in the background
- BYOK (Bring Your Own Key) — no subscription, you control the cost

### Quick Start

**1. Build** (requires macOS 14+ and Xcode Command Line Tools)

```bash
git clone https://github.com/justin7974/vox.git
cd vox
bash build.sh
```

**2. Install**

```bash
cp -r build/Vox.app ~/Applications/
xattr -cr ~/Applications/Vox.app   # bypass Gatekeeper
```

**3. Launch & Setup**

```bash
open ~/Applications/Vox.app
```

A setup wizard will guide you through API keys, hotkey, recording mode, and a test recording.

**4. Grant Permissions**

macOS will prompt for these permissions. Grant both in **System Settings > Privacy & Security**:

- **Microphone** — to record your voice
- **Accessibility** — to paste text at your cursor

**5. Use**

1. Press your hotkey to start recording (menubar icon turns red)
2. Speak naturally
3. Press your hotkey again to stop (or release if using hold-to-talk)
4. Text appears at your cursor

### API Keys

Vox uses cloud APIs. You need to bring your own keys.

**Speech Recognition (required):**

| Provider | How to get key | Notes |
|---|---|---|
| **Alibaba Qwen ASR** (recommended) | [bailian.console.aliyun.com](https://bailian.console.aliyun.com/) | Best Chinese-English mixed recognition |
| Local Whisper | No key needed | Requires [whisper-cpp](https://github.com/ggerganov/whisper.cpp) via Homebrew |

**Text Post-Processing (optional):**

| Provider | How to get key | Notes |
|---|---|---|
| **Kimi** (recommended) | [platform.moonshot.cn](https://platform.moonshot.cn/) | Fast, good quality |
| MiniMax | [platform.minimaxi.com](https://platform.minimaxi.com/) | Alternative |
| None | — | Skip post-processing entirely |

### Configuration

Config file: `~/.vox/config.json`

You can edit it directly or use the Settings UI (menubar icon > Settings). See [config.example.json](config.example.json) for the full format.

The `userContext` field helps the LLM correct domain-specific terms:

```json
{
  "userContext": "VC investor working with AI/LLM products (Claude, GPT), investment terms (Term Sheet, Cap Table), dev tools (GitHub, VS Code)."
}
```

### Architecture

```
Hotkey  →  AudioRecorder (16kHz WAV)
        →  Transcriber (Qwen ASR / local Whisper)
        →  PostProcessor (LLM, optional)
        →  TextFormatter (CJK spacing, punctuation)
        →  PasteHelper (CGEvent Cmd+V → osascript fallback)
```

### Troubleshooting

| Problem | Solution |
|---|---|
| No audio detected | System Settings > Privacy > Microphone — allow Vox |
| Text not pasting | System Settings > Privacy > Accessibility — allow Vox |
| ASR errors | Check `~/.vox/debug.log`, verify API key in Settings |
| macOS blocks the app | Run `xattr -cr ~/Applications/Vox.app` |
| Permissions reset after rebuild | macOS resets TCC on new binary signature. Re-grant permissions. |

---

## 中文

**工作原理：** 快捷键 → 录音 → 云端语音识别 → LLM 纠错 → 粘贴到光标位置

### 功能特点

- 自定义全局快捷键 — 在任何应用中都能用
- 按住说话或切换模式
- 云端语音识别：阿里 Qwen3-ASR-Flash（快速、准确，中英混合识别效果好）
- 可选 LLM 后处理（去除口头语、纠正错别字、补充标点）
- 自动文本格式化（中英文间距、标点规范化）
- 多步引导向导 — 轻松完成首次设置
- 录音时实时音频波形可视化
- 菜单栏应用 — 安静运行在后台
- BYOK（自带 API Key）— 没有订阅费，成本自己控制

### 快速开始

**1. 编译**（需要 macOS 14+ 和 Xcode 命令行工具）

```bash
git clone https://github.com/justin7974/vox.git
cd vox
bash build.sh
```

**2. 安装**

```bash
cp -r build/Vox.app ~/Applications/
xattr -cr ~/Applications/Vox.app   # 绕过 Gatekeeper
```

**3. 启动和设置**

```bash
open ~/Applications/Vox.app
```

首次启动会弹出引导向导，帮你完成 API Key 配置、快捷键设置、录音模式选择和测试录音。

**4. 授权**

macOS 会弹窗请求权限，都要允许。在 **系统设置 > 隐私与安全性** 中授权：

- **麦克风** — 录音用
- **辅助功能** — 自动粘贴用

**5. 使用**

1. 按快捷键开始录音（菜单栏图标变红）
2. 正常说话
3. 再按快捷键停止录音（按住说话模式松开即可）
4. 文字自动出现在光标位置

### API Key 获取

Vox 使用云端 API，你需要自己提供 Key。

**语音识别（必选）：**

| 服务商 | 获取地址 | 说明 |
|---|---|---|
| **阿里 Qwen ASR**（推荐） | [bailian.console.aliyun.com](https://bailian.console.aliyun.com/) | 中英混合识别最佳 |
| 本地 Whisper | 不需要 Key | 需要通过 Homebrew 安装 [whisper-cpp](https://github.com/ggerganov/whisper.cpp) |

**文本后处理（可选）：**

| 服务商 | 获取地址 | 说明 |
|---|---|---|
| **Kimi**（推荐） | [platform.moonshot.cn](https://platform.moonshot.cn/) | 速度快，效果好 |
| MiniMax | [platform.minimaxi.com](https://platform.minimaxi.com/) | 备选 |
| 不使用 | — | 跳过后处理 |

### 配置

配置文件位置：`~/.vox/config.json`

可以直接编辑文件，也可以通过菜单栏图标 > Settings 打开设置界面。完整格式参见 [config.example.json](config.example.json)。

`userContext` 字段帮助 LLM 纠正领域术语：

```json
{
  "userContext": "科技行业 VC 投资人，日常涉及 AI/LLM 产品（Claude、GPT、Kimi）、投资术语（Term Sheet、Cap Table）、开发工具（GitHub、VS Code）。"
}
```

### 常见问题

| 问题 | 解决方案 |
|---|---|
| 检测不到音频 | 系统设置 > 隐私与安全 > 麦克风 — 允许 Vox |
| 文字没有粘贴 | 系统设置 > 隐私与安全 > 辅助功能 — 允许 Vox |
| 识别报错 | 查看 `~/.vox/debug.log`，检查 API Key 是否正确 |
| macOS 阻止运行 | 运行 `xattr -cr ~/Applications/Vox.app` |
| 重新编译后权限失效 | macOS 对新签名的二进制会重置权限，需要重新授权 |

---

## License

[MIT](LICENSE)
