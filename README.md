# Pastelet

Pastelet 是一款原生 macOS 剪贴板管理器，采用底部弹出式面板展示剪贴板历史。界面目标是接近高端独立 macOS 应用的视觉质感：Liquid Glass、轻量动效、富媒体预览和低干扰的时间线布局。

## 功能

- 使用快捷键快速呼出剪贴板历史面板
- 从屏幕底部弹出剪贴板时间线
- 支持文本、代码、图片、链接、文件等剪贴板项目预览
- 支持搜索剪贴板历史
- 支持删除项目、收藏项目和快速粘贴
- 支持开机启动、隐藏菜单栏图标和本地历史保留设置
- 支持自定义快捷键

## 默认快捷键

- 呼出 Pastelet：`Command + Shift + V`

快捷键可以在应用设置中修改。

## 系统要求

- macOS 26 或更高版本
- Apple Silicon / ARM64

## 技术栈

- Swift
- SwiftUI
- AppKit
- Swift Package Manager
- macOS 26 Liquid Glass / `NSGlassEffectView`

## 本地构建

```bash
./scripts/build-app.sh
```

构建完成后，应用会生成在：

```bash
build/Pastelet.app
```

如需安装到系统应用目录：

```bash
pkill -x Pastelet 2>/dev/null || true
rm -rf /Applications/Pastelet.app
cp -R build/Pastelet.app /Applications/Pastelet.app
xattr -cr /Applications/Pastelet.app 2>/dev/null || true
codesign --force --deep --sign - /Applications/Pastelet.app
open /Applications/Pastelet.app
```

## 项目状态

当前版本聚焦于第一版核心体验：剪贴板历史记录、底部弹出面板、富媒体卡片预览、设置页和基础交互动画。后续会继续完善更细的分组、同步、筛选和剪贴板处理能力。
