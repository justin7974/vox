# Vox 开发日志

> 从灵感到 v2.0 的完整记录（2026-02-27 ~ 2026-02-28）

## 起因

Typeless.app 频繁崩溃（EPIPE 错误），加上一直想要一个更智能的语音输入工具——不只是转写，还要自动纠错、格式化。决定自己手搓一个。

## Day 1（2/27）— 从零到能用

### v0.1 原型

- 用 Swift 写了一个 macOS menubar app，6 个源文件 + build.sh，无需 Xcode
- 技术栈：AVFoundation 录音 + whisper-cli 本地转写 + Carbon 全局热键
- 快捷键 Ctrl+`（两键、离得近、好按）
- LLM 后处理最初用 `claude --print`，后来发现在 .app 里有兼容问题

### v1.0 实际可用

- **ASR**：本地 whisper-cli + large-v3-turbo 模型
- **LLM 后处理**：从 claude CLI → MiniMax API → 最终落在 Kimi k2.5（速度快、中文好）
- **粘贴机制**：试了 AXValue 注入（Electron 假阳性）→ osascript（权限问题）→ 最终 CGEvent Cmd+V + osascript 双保险
- **格式化**：TextFormatter 做 Pangu spacing + 标点规范化
- **幻觉过滤**：识别 whisper 常见幻觉输出（"优优独播剧场"等）
- **静音检测**：audio metering -50dB 阈值，避免空录音

### 踩过的坑

- CRLF 行尾问题（Dropbox + Write tool 的已知坑）
- TCC 权限每次重编译丢失（ad-hoc 签名 hash 变化）
- iPhone Continuity Camera 劫持 AirPods 音频通道
- MiniMax API 500 错误 + 余额不足

## Day 1.5（2/27 深夜）— 快速迭代到 v1.3

### v1.1 Settings UI + 云端 ASR

- 完整的 Settings GUI（NSWindow + NSTabView）
- 支持切换 ASR provider（Qwen / Whisper）和 LLM provider（Kimi / MiniMax / Anthropic）
- 添加 Qwen3-ASR-Flash 云端识别（阿里百炼），中英混合效果远超本地 whisper
- userContext 方案：一句话描述用户背景，LLM 自动推断纠错
- 自签名证书解决 TCC 权限持久化

### v1.3 App 图标 + 状态覆盖层

- 用 Labnana API 生成了 App 图标（8 个方案，最终选 F1：蓝紫渐变 + 声波 V）
- 浮动状态覆盖层：录音/处理时全屏半透明提示（Recording... / Processing...）
- build.sh 自动安装到 /Applications/
- 首次 push 到 GitHub，创建 v1.3.0 Release

## Day 2（2/28 凌晨）— v2.0 大升级 + 品牌重塑

### Vox 品牌

- 应用正式命名为 **Vox**（拉丁语"声音"）
- 全新 App 图标（Vox F1 设计）
- GitHub 仓库从 `voice-input` 改名为 `vox`
- 所有源码、配置、文档统一更名

### 多步引导向导（Onboarding Wizard）

5 步引导，首次启动自动弹出：

1. **Welcome** — 图标 + 标语 "You speak, Vox types."
2. **API 配置** — ASR 和 LLM 的 provider 选择 + API Key 输入
3. **快捷键 & 模式** — 自定义全局热键 + Toggle/Hold-to-Talk 切换
4. **录音测试** — 实时录音 + 30 条音频波形柱可视化
5. **完成** — 配置摘要 + 开始使用

### 自定义快捷键

- 不再锁定 Ctrl+`，用户可以在引导中点击录入任意 modifier+key 组合
- HotkeyRecorderView：自定义 NSView，acceptsFirstResponder + keyDown 捕获
- AppDelegate 动态注册/注销 Carbon 热键
- 菜单栏动态显示当前快捷键

### Hold-to-Talk 模式

- 新增按住说话模式：按住热键录音，松开自动结束
- 与原有 Toggle 模式自由切换
- 通过 Carbon kEventHotKeyReleased 事件实现

### 音频可视化

- AudioLevelView：30 条 CALayer 柱状图
- 实时响应麦克风 dB 值（-160 ~ 0 归一化）
- 录音测试步骤中展示，直观反馈麦克风状态

## 最终架构

```
Hotkey (custom) →  AudioRecorder (16kHz WAV, metering)
               →  Transcriber (Qwen ASR / local Whisper)
               →  PostProcessor (Kimi k2.5 / other LLM + userContext)
               →  TextFormatter (Pangu spacing + punctuation)
               →  PasteHelper (CGEvent Cmd+V → osascript fallback)
```

## 文件结构

```
Dev/voice-input/          (本地目录名保留，GitHub 已改名 vox)
├── Vox/                  (源码，9 个 Swift 文件)
│   ├── main.swift
│   ├── AppDelegate.swift
│   ├── SetupWindow.swift (引导向导 + Settings)
│   ├── AudioRecorder.swift
│   ├── Transcriber.swift
│   ├── PostProcessor.swift
│   ├── TextFormatter.swift
│   ├── PasteHelper.swift
│   └── StatusOverlay.swift
├── AppIcon.icns
├── Info.plist
├── build.sh
├── setup-signing.sh
├── config.example.json
└── README.md
```

## 版本线

| 版本 | 时间 | 里程碑 |
|------|------|--------|
| v0.1 | 2/27 下午 | 原型：whisper + claude CLI |
| v1.0 | 2/27 晚 | 可用：Kimi LLM + CGEvent paste |
| v1.1 | 2/27 深夜 | Settings UI + Qwen ASR + 自签名 |
| v1.3 | 2/28 00:05 | App 图标 + 状态覆盖 + GitHub |
| v2.0 | 2/28 02:04 | Vox 品牌 + Onboarding + 自定义热键 + Hold-to-Talk |

## 已知问题

- 完成引导后偶尔会跳回 API 配置页（已加防御代码，待进一步测试）
- Whisper 本地模型对中英混合仍有错误（云端 Qwen ASR 已基本解决）
