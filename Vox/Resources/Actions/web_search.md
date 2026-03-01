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
  - 知乎搜
  - 在知乎
  - 小红书搜
  - 在小红书
  - 淘宝搜
  - 在淘宝
  - 京东搜
  - 在京东
  - Amazon搜
  - 在Amazon
  - Reddit搜
  - 在Reddit
  - StackOverflow搜
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
搜索网页内容。默认使用 Google，可通过 engine 参数指定搜索引擎。

引擎识别规则：
- YouTube / 油管 / 看视频 / 找视频 → engine: "youtube"
- B站 / bilibili / 哔哩哔哩 → engine: "bilibili"
- GitHub / 代码搜索 → engine: "github"
- 百度 → engine: "baidu"
- 知乎 → engine: "zhihu"
- 小红书 → engine: "xiaohongshu"
- 淘宝 → engine: "taobao"
- 京东 → engine: "jd"
- Amazon / 亚马逊 → engine: "amazon"
- Reddit → engine: "reddit"
- StackOverflow → engine: "stackoverflow"
- Twitter / X → engine: "twitter"
- Wikipedia / 维基百科 → engine: "wikipedia"
- 未指定 → 不传 engine（默认 Google）

注意区分"在 YouTube 搜索 xxx"（web_search）和"打开 YouTube"（open_url）。

**query 必须是优化后的搜索关键词**，不是用户原话。像搜索引擎助手一样重构：
- 去掉口语动词和无意义修饰
- 提取核心搜索意图
- 中文人名在英文平台搜索时翻译为英文
