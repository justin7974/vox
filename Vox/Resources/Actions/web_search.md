---
id: web_search
name: Web 搜索
type: url
triggers:
  - 搜索
  - 搜一下
  - 谷歌搜
  - Google搜
  - YouTube搜
  - 油管搜
  - GitHub搜
  - 百度搜
  - B站搜
  - search
params:
  - name: query
    type: string
    required: true
  - name: engine
    type: string
    required: false
template: https://www.google.com/search?q={query}
---
搜索网页内容。默认使用 Google，可通过 engine 参数指定搜索引擎（youtube/github/baidu/bilibili）。
