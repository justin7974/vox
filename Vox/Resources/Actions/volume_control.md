---
id: volume_control
name: 音量控制
type: system
triggers:
  - 静音
  - 取消静音
  - 音量调高
  - 音量调低
  - 音量调到
  - mute
  - unmute
  - volume
params:
  - name: action
    type: string
    required: true
  - name: level
    type: number
    required: false
---
控制系统音量。支持静音、取消静音、调高、调低、调到指定值（0-100）。
