---
id: file_search
name: 搜索文件
type: system
triggers:
  - 搜索文件
  - 找文件
  - 找一下文件
  - search file
  - find file
params:
  - name: query
    type: string
    required: true
---
使用 Spotlight 索引搜索本地文件，找到后在 Finder 中显示。

query 应该是文件名或关键词，去掉口语修饰：
- "找一下我的合同文件" → query: "合同"
- "搜索 readme" → query: "readme"
- "找上周的报告" → query: "报告"
