# Pastelet

Pastelet 是一款原生 macOS 剪贴板管理器。它用底部弹出的横向时间线展示剪贴板历史，重点放在快速呼出、快速预览、快速粘贴和低干扰操作上。

界面基于 SwiftUI + AppKit 构建，使用 Liquid Glass 风格、卡片预览和柔和补位动画，适合长期驻留在后台作为日常剪贴板工具使用。

## 核心功能

- 全局快捷键呼出剪贴板面板，默认 `Command + Shift + V`
- 底部弹出式时间线，展示最新剪贴板历史
- 支持文本、代码、链接、颜色、图片、文件等类型
- 图片历史按缩略图展示，粘贴时保留原图质量
- 链接项目支持标题、域名和预览图补全
- 支持搜索历史内容
- 支持按收藏、内容类型、来源 App 过滤
- 右键卡片可收藏、复制到剪贴板、删除
- 粘贴或复制过的历史记录会自动移动到首位
- 每次打开面板都会重置到初始状态：无默认选中、回到列表最前、清空搜索和过滤
- 删除后支持 `Command + Z` 撤回
- 删除时后续卡片会平滑前移，撤回时平滑插回

## 快捷操作

| 操作 | 快捷键 |
| --- | --- |
| 呼出 / 收起 Pastelet | `Command + Shift + V` |
| 展开搜索 | `Command + F` |
| 搜索展开后打开来源 / 类型过滤 | 再按一次 `Command + F` |
| 上一个 / 下一个项目 | `←` / `→` |
| 粘贴当前选中项 | `Return` |
| 删除鼠标下方项目 | `Delete` |
| 删除当前键盘选中项 | `Delete` |
| 撤回最近删除 | `Command + Z` |
| 关闭面板或退出搜索 | `Esc` |

说明：刚打开面板时默认不选中任何项目；使用方向键后才会进入键盘选择状态。`Delete` 会优先删除鼠标悬停的卡片，没有悬停时才删除键盘选中项。

## 粘贴行为

Pastelet 支持两种粘贴模式，可在设置中切换：

- 到当前活动应用：点击卡片后恢复剪贴板内容，并自动向原前台 App 发送 `Command + V`
- 到剪贴板：点击卡片后只复制回系统剪贴板，由用户手动粘贴

自动粘贴需要 macOS 辅助功能权限。如果没有授权，Pastelet 会只复制到剪贴板，并提示打开系统设置授权。

## 设置项

通用设置：

- 登录时打开
- 隐藏菜单栏图标
- 音效开关
- 直接粘贴到当前活动应用 / 仅复制到剪贴板
- 始终以纯文本粘贴
- 历史保留时间：1 天、1 周、1 个月、1 年、永久
- 删除全部历史

快捷键设置：

- 自定义启动 Pastelet 快捷键
- 自定义上一个 / 下一个项目快捷键
- 重置快捷键为默认值

## 数据存储

历史记录只保存在本机用户目录中：

```text
~/Library/Application Support/Pastelet/
```

文本、链接、颜色和文件引用会写入本地 JSON 索引；图片会单独保存到本地图片目录。收藏项会尽量保留，普通历史会按数量上限和保留时间自动清理。

## 系统要求

- macOS 26 或更高版本
- Apple Silicon / ARM64

## 技术栈

- Swift
- SwiftUI
- AppKit
- Swift Package Manager
- LinkPresentation
- macOS Liquid Glass / `NSGlassEffectView`

## 本地构建

```bash
./scripts/build-app.sh
```

构建完成后，应用会生成在：

```text
build/Pastelet.app
```

## 安装到应用目录

```bash
pkill -x Pastelet 2>/dev/null || true
rm -rf /Applications/Pastelet.app
cp -R build/Pastelet.app /Applications/Pastelet.app
open /Applications/Pastelet.app
```

如果系统阻止启动，可以按需清理隔离属性并重新签名：

```bash
xattr -cr /Applications/Pastelet.app 2>/dev/null || true
codesign --force --deep --sign - /Applications/Pastelet.app
```

## 项目状态

当前版本聚焦本地剪贴板历史管理：快速呼出、富媒体预览、搜索过滤、收藏、删除撤回、粘贴后置顶和柔和动效。同步、多设备协作和更复杂的分组能力暂未纳入当前版本。
