---
id: open_folder
name: 打开文件夹
type: system
triggers:
  - 打开文件夹
  - 打开目录
  - open folder
  - open directory
params:
  - name: folder
    type: string
    required: true
---
在 Finder 中打开指定文件夹。

内置文件夹映射（folder 参数使用以下关键词）：
- desktop / 桌面 → ~/Desktop
- downloads / 下载 → ~/Downloads
- documents / 文档 → ~/Documents
- home / 主目录 → ~
- applications / 应用 → /Applications
- pictures / 图片 → ~/Pictures
- music / 音乐 → ~/Music
- movies / 视频 → ~/Movies
- trash / 废纸篓 → ~/.Trash
- icloud → ~/Library/Mobile Documents/com~apple~CloudDocs
- dropbox → ~/Library/CloudStorage/Dropbox

folder 参数传关键词（如 "desktop"、"downloads"），不要传完整路径。
如果用户说的文件夹不在映射中，传原始名称。
