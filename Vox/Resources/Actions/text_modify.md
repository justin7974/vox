---
id: text_modify
name: 修改文字
type: vox
triggers:
  - 改正式一点
  - 缩短一下
  - 展开
  - 改口语
  - rewrite
  - 改写
params:
  - name: instruction
    type: string
    required: true
---
根据指令修改最近输入的文字。在听写模式的时间窗口内触发。
