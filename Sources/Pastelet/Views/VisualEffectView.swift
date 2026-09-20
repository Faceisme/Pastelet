import SwiftUI

struct GlassEffectView: NSViewRepresentable {
    var cornerRadius: CGFloat
    var tintColor: NSColor?
    var style: NSGlassEffectView.Style = .regular
    /// 玻璃是否跟随指针给出交互反馈（macOS 27 才有的 effectIsInteractive，26 上忽略）
    var isInteractive = false

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.cornerRadius = cornerRadius
        view.tintColor = tintColor
        view.style = style
        if #available(macOS 27.0, *) {
            view.effectIsInteractive = isInteractive
        }
        return view
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {
        // 仅在实际变化时赋值，避免每次 body 重算（如 hover）都重设属性触发玻璃层重绘
        if nsView.cornerRadius != cornerRadius { nsView.cornerRadius = cornerRadius }
        if nsView.tintColor != tintColor { nsView.tintColor = tintColor }
        if nsView.style != style { nsView.style = style }
        if #available(macOS 27.0, *), nsView.effectIsInteractive != isInteractive {
            nsView.effectIsInteractive = isInteractive
        }
    }
}
