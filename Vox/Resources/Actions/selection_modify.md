---
id: selection_modify
name: 修改选中文字
type: vox
triggers:
  - 翻译选中的
  - 润色选中的
  - 改写选中的
  - modify selection
params:
  - name: instruction
    type: string
    required: true
---
修改当前选中的文字。先选中文字，再按 Launcher 热键说修改指令。
