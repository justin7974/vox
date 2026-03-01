---
id: file_search
name: 找文件
type: system
triggers:
  - 找一下
  - 在哪
  - 文件在哪
  - 帮我找
  - where is
  - find
params:
  - name: query
    type: string
    required: true
---
通过 Spotlight 搜索本地文件。用户说出要找的文件名或关键词，自动打开 Spotlight 搜索。

query 应该是文件名或关键词，去掉口语修饰：
- "找一下我的合同" → query: "合同"
- "readme 在哪" → query: "readme"
- "找一下上周的报告" → query: "报告"
