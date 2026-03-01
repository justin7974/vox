---
id: window_manage
name: 窗口管理
type: system
triggers:
  - 全屏
  - 放左边
  - 放右边
  - 最大化
  - 最小化
  - fullscreen
  - left half
  - right half
params:
  - name: position
    type: string
    required: true
---
管理当前窗口位置和大小。支持全屏、半屏（左/右）、最大化、最小化。
