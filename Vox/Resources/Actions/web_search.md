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
  - 在YouTube
  - 在油管
  - 用YouTube
  - 用油管
  - YouTube上
  - 油管上
  - GitHub搜
  - 在GitHub
  - 百度搜
  - 百度一下
  - B站搜
  - 在B站
  - 在bilibili
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
当用户提到 YouTube/油管 相关的意图（看视频、找视频等），engine 应设为 youtube。
当用户提到 B站/bilibili，engine 应设为 bilibili。
