---
id: open_url
name: 打开网站
type: url
triggers:
  - 打开网站
  - 打开网页
  - open website
  - go to
params:
  - name: url
    type: string
    required: true
template: {url}
---
打开指定网站。根据用户说的网站名称，匹配到正确的 URL 并打开。

常见网站映射（你必须输出完整 URL）：
- GitHub → https://github.com
- Gmail → https://mail.google.com
- Google Drive → https://drive.google.com
- YouTube → https://youtube.com
- Twitter / X → https://x.com
- Reddit → https://reddit.com
- ChatGPT → https://chat.openai.com
- Claude → https://claude.ai
- Notion → https://notion.so
- Figma → https://figma.com
- Vercel → https://vercel.com
- 知乎 → https://zhihu.com
- 微博 → https://weibo.com
- 小红书 → https://xiaohongshu.com
- 淘宝 → https://taobao.com
- 京东 → https://jd.com
- 飞书 → https://feishu.cn
- 豆瓣 → https://douban.com
- Bilibili → https://bilibili.com

如果用户说的网站不在列表中但你能推断出 URL，也可以直接输出。
注意区分"打开 YouTube"（open_url）和"在 YouTube 搜索 xxx"（web_search）。
