---
id: timer
name: 计时器
type: system
triggers:
  - 计时
  - 倒计时
  - 分钟后提醒
  - timer
  - remind me
params:
  - name: seconds
    type: number
    required: true
  - name: label
    type: string
    required: false
---
设置倒计时提醒。到时间后弹出系统通知。

示例：
- "5分钟计时器" → seconds: 300
- "倒计时10分钟" → seconds: 600
- "30秒后提醒我" → seconds: 30
- "一个半小时计时" → seconds: 5400

seconds 参数必须是秒数（整数）。label 是可选的提醒文字。
