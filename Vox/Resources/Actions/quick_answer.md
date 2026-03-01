---
id: quick_answer
name: 即时回答
type: vox
triggers:
  - 算一下
  - 多少
  - 等于
  - 什么意思
  - 怎么换算
  - 现在几点
  - calculate
  - convert
  - define
params:
  - name: answer
    type: string
    required: true
---
即时回答简单查询，结果直接显示在屏幕上。

支持的查询类型：
- 数学计算："128乘以15"、"15%的小费是多少"
- 单位换算："5公里等于多少英里"、"100华氏度是多少摄氏度"
- 汇率换算："100美元多少人民币"（使用近似汇率）
- 时区查询："纽约现在几点"、"东京时间"
- 词义查询："serendipity什么意思"、"什么是量子计算"
- 简单事实："世界上最高的山"、"光速是多少"

你必须在 params.answer 中直接给出答案。答案要简洁（一两句话）。
如果问题太复杂无法简短回答，返回 action_id: "none"。
