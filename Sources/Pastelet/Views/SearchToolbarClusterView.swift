import AppKit
import SwiftUI

/// 工具栏搜索簇：磁贴样式的「剪贴板 / 收藏」筛选 + 可展开的搜索框。
///
/// 纯 SwiftUI 实现：展开/收起只靠 `isSearching` 的宽度状态切换 + 一次 `.animation`，
/// GPU 自己插值，没有手写 CALayer、没有 asyncAfter 收尾、没有重复触发。搜索框像画卷
/// 一样横向铺开，收起时缩回成一颗放大镜。展开后尾部带「清空」按钮与「按来源/类型过滤」菜单。
struct SearchToolbarClusterView: View {
    @Binding var isSearching: Bool
    @Binding var searchText: String
    @Binding var showFavoritesOnly: Bool
    @Binding var focusRequest: Int
    @Binding var resetRequest: Int
    @Binding var showFilterMenu: Bool
    @Binding var sourceFilter: String?
    @Binding var kindFilter: ClipboardKind?

    // 懒求值：只在过滤弹窗真正打开时才计算（避免每次 body / 每次 hover 都全量重算来源与类型）
    let availableKinds: () -> [ClipboardKind]
    let availableSources: () -> [ClipboardSourceOption]

    let onClipboardSelected: () -> Void
    let onFavoritesSelected: () -> Void
    let onSearchCancelled: () -> Void

    @State private var isFieldFocused: Bool = false
    @State private var didWarmFieldEditor = false

    private enum Metric {
        static let height: CGFloat = 32
        static let collapsedSearch: CGFloat = 34
        static let expandedSearch: CGFloat = 392
        static let circleButton: CGFloat = 34
        static let spacing: CGFloat = 10
    }

    /// 无回弹的平滑曲线，比带弹性的 spring 更「丝滑」，贴合画卷横向铺开的观感。
    /// 时长经两次提速：0.34 → 0.24（-30%）→ 0.19（再 -20%，0.24 × 0.8），手感更利落。
    private var expandAnimation: Animation {
        .smooth(duration: 0.19)
    }

    var body: some View {
        HStack(spacing: Metric.spacing) {
            searchCapsule

            if isSearching {
                circleButton(symbol: "clock.arrow.circlepath", help: "返回剪贴板") {
                    onSearchCancelled()
                }
                .transition(.opacity)
            } else {
                ToolbarPill(
                    title: "剪贴板",
                    symbol: "clock.arrow.circlepath",
                    isSelected: !showFavoritesOnly
                ) {
                    showFavoritesOnly = false
                    onClipboardSelected()
                }
                .transition(.opacity)
            }

            ToolbarPill(
                title: "收藏",
                symbol: "star.fill",
                isSelected: showFavoritesOnly
            ) {
                showFavoritesOnly = true
                onFavoritesSelected()
            }
        }
        .frame(height: 44)
        .animation(expandAnimation, value: isSearching)
        .onChange(of: isSearching) { _, expanded in
            // SearchField 在 becomeFirstResponder 时会主动吸收当前 searchText，
            // 因此这里直接聚焦即可，无需延迟、也不会丢字。
            isFieldFocused = expanded
        }
        .onChange(of: focusRequest) { _, _ in
            // Cmd+F：仅在已展开时把焦点拉回搜索框；面板入场的「预热」请求不应自动展开。
            if isSearching { isFieldFocused = true }
        }
        .onChange(of: resetRequest) { _, _ in
            isFieldFocused = false
        }
        .onChange(of: showFilterMenu) { _, shown in
            // 过滤菜单关闭后把焦点交还搜索框，搜索会话延续；打开时弹层自然接管焦点。
            if !shown && isSearching { isFieldFocused = true }
        }
        .task {
            // 离屏预热：面板首次（在屏幕外）出现时，让常驻文本框静默拿一次焦点，
            // 创建窗口的 field editor。此刻文本框 opacity 0、宽度 0，不可见，
            // 因此用户「第一次」真正展开搜索时不再为此卡顿。
            guard !didWarmFieldEditor else { return }
            didWarmFieldEditor = true
            isFieldFocused = true
            try? await Task.sleep(nanoseconds: 60_000_000)
            if !isSearching { isFieldFocused = false }
        }
    }

    // MARK: - 搜索胶囊

    private var searchCapsule: some View {
        HStack(spacing: 0) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            // 文本框常驻：收起时压成 0 宽 + 透明，展开时铺满。避免首次插入子树的开销，
            // 它的出现也成为同一条宽度动画的一部分，更连贯。
            // 用原生 SearchField（NSTextField）而非 SwiftUI TextField：后者聚焦时不吸收绑定值，
            // 会把「打字直接搜索」累计的前几个字符覆盖掉（见 SearchField 注释）。
            SearchField(
                text: $searchText,
                isFocused: $isFieldFocused,
                onSubmit: {
                    NotificationCenter.default.post(name: .pasteletNavSelect, object: nil)
                }
            )
            .padding(.leading, 7)
            .frame(maxWidth: isSearching ? .infinity : 0, alignment: .leading)
            .opacity(isSearching ? 1 : 0)

            if isSearching {
                searchAccessories
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, isSearching ? 11 : 0)
        .frame(
            width: isSearching ? Metric.expandedSearch : Metric.collapsedSearch,
            height: Metric.height
        )
        .background {
            Capsule(style: .continuous)
                .fill(Color(nsColor: .controlColor).opacity(0.72))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(
                            Color(nsColor: .controlAccentColor).opacity(isSearching ? 0.55 : 0),
                            lineWidth: 1.2
                        )
                }
        }
        .clipShape(Capsule(style: .continuous))
        .contentShape(Capsule(style: .continuous))
        .onTapGesture {
            if isSearching {
                isFieldFocused = true
            } else {
                isSearching = true
            }
        }
    }

    // MARK: - 搜索框尾部：清空 + 过滤菜单

    private var hasActiveFilter: Bool {
        sourceFilter != nil || kindFilter != nil
    }

    @ViewBuilder
    private var searchAccessories: some View {
        // 清空：仅在有输入时出现，点一下清空关键字并保持焦点
        if !searchText.isEmpty {
            Button {
                searchText = ""
                isFieldFocused = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .contentShape(Circle())
            }
            .buttonStyle(PasteletPressButtonStyle(pressedScale: 0.84, pressedOpacity: 0.7))
            .help("清空")
            .padding(.trailing, 3)
        }

        // 按来源 / 类型过滤：再次 Cmd+F 或点此打开；有筛选生效时图标高亮
        Button {
            showFilterMenu.toggle()
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(hasActiveFilter ? Color(nsColor: .controlAccentColor) : Color.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(PasteletPressButtonStyle(pressedScale: 0.84, pressedOpacity: 0.7))
        .help("按来源 / 类型过滤")
        .popover(isPresented: $showFilterMenu, arrowEdge: .top) {
            SourceFilterMenu(
                kinds: availableKinds(),
                sources: availableSources(),
                kindFilter: $kindFilter,
                sourceFilter: $sourceFilter,
                onPick: { showFilterMenu = false }
            )
        }
    }

    // MARK: - 圆形图标按钮（返回剪贴板）

    private func circleButton(
        symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: Metric.circleButton, height: Metric.circleButton)
                .background(Color(nsColor: .controlColor).opacity(0.12), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PasteletPressButtonStyle(pressedScale: 0.9, pressedOpacity: 0.8))
        .help(help)
    }

}

// MARK: - 原生搜索输入框

/// 原生 NSTextField 包装，解决「打字直接搜索」首字符被覆盖的问题。
///
/// SwiftUI 的 `TextField` 在成为第一响应者那一刻**不会**把当前绑定值灌进 field editor：
/// 于是事件监视器在展开动画期间按序写入 `searchText` 的前几个字符（如 "ic"），会被 field editor
/// 接管输入时的空内容覆盖（实测第一下原生按键把 "ic" 清成 "o"，"icon" 变 "on"）。
/// 这里在 `becomeFirstResponder` 时主动把绑定值写入字段并把光标移到末尾，彻底消除这次交接丢字。
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var onSubmit: () -> Void = {}

    func makeNSView(context: Context) -> FocusAdoptingTextField {
        let tf = FocusAdoptingTextField()
        tf.delegate = context.coordinator
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = .systemFont(ofSize: 12.5, weight: .medium)
        tf.placeholderString = "搜索"
        tf.lineBreakMode = .byTruncatingTail
        tf.usesSingleLineMode = true
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tf.boundTextProvider = { [weak coordinator = context.coordinator] in
            coordinator?.parent.text ?? ""
        }
        tf.onFocusChange = { [weak coordinator = context.coordinator] focused in
            DispatchQueue.main.async {
                guard let coordinator else { return }
                if coordinator.parent.isFocused != focused {
                    coordinator.parent.isFocused = focused
                }
            }
        }
        return tf
    }

    func updateNSView(_ tf: FocusAdoptingTextField, context: Context) {
        context.coordinator.parent = self
        // 非编辑态时让显示值跟随绑定（清空、外部赋值等）
        if tf.currentEditor() == nil, tf.stringValue != text {
            tf.stringValue = text
        }
        guard let window = tf.window else { return }
        let isFirstResponder = tf.currentEditor() != nil && window.firstResponder === tf.currentEditor()
        if isFocused, !isFirstResponder {
            window.makeFirstResponder(tf)
        } else if !isFocused, isFirstResponder {
            window.makeFirstResponder(nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            parent.text = tf.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}

/// 在成为第一响应者时把外部绑定值写进字段、光标置末尾，避免 field editor 以空内容覆盖已累计的输入。
final class FocusAdoptingTextField: NSTextField {
    var boundTextProvider: () -> String = { "" }
    var onFocusChange: (Bool) -> Void = { _ in }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            let value = boundTextProvider()
            if stringValue != value { stringValue = value }
            if let editor = currentEditor() {
                let end = (value as NSString).length
                editor.selectedRange = NSRange(location: end, length: 0)
            }
            onFocusChange(true)
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange(false) }
        return ok
    }
}

// MARK: - 筛选磁贴（剪贴板 / 收藏）

private struct ToolbarPill: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(isSelected ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background {
                Capsule(style: .continuous)
                    .fill(Color(nsColor: .controlColor).opacity(backgroundOpacity))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(
                                Color(nsColor: .separatorColor).opacity(isSelected ? 0.36 : 0.12),
                                lineWidth: 1
                            )
                    }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PasteletPressButtonStyle(pressedScale: 0.95, pressedOpacity: 0.85))
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.18, dampingFraction: 0.82), value: isHovered)
        .help(title)
    }

    private var backgroundOpacity: Double {
        if isSelected {
            return isHovered ? 0.24 : 0.18
        }
        return isHovered ? 0.14 : 0.08
    }
}

// MARK: - 来源选项

/// 历史里出现过的一个来源 App（用于「应用」过滤分区）。
struct ClipboardSourceOption: Identifiable, Equatable {
    let name: String
    let bundleID: String?
    let icon: NSImage?

    var id: String { name }

    static func == (lhs: ClipboardSourceOption, rhs: ClipboardSourceOption) -> Bool {
        lhs.name == rhs.name && lhs.bundleID == rhs.bundleID
    }
}

/// App 图标缩略图缓存。
///
/// `NSRunningApplication.icon` 是含大尺寸表示的多分辨率图标，直接在过滤弹窗里缩到 18pt
/// 会在开窗动画那几帧实时缩放十几张大图、掉帧。这里按 key 预缩成一张 18pt 小位图并缓存，
/// 每个 App 只缩一次，弹窗只需画现成的小图。仅在主线程使用。
@MainActor
enum AppIconThumbnailCache {
    private static var cache: [String: NSImage] = [:]

    static func thumbnail(for icon: NSImage?, key: String, side: CGFloat = 18) -> NSImage? {
        guard let icon else { return nil }
        if let cached = cache[key] { return cached }

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixels = max(1, Int((side * scale).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return icon
        }
        rep.size = NSSize(width: side, height: side)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        icon.draw(
            in: NSRect(x: 0, y: 0, width: side, height: side),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        let thumb = NSImage(size: NSSize(width: side, height: side))
        thumb.addRepresentation(rep)
        cache[key] = thumb
        return thumb
    }
}

// MARK: - 过滤菜单弹层（类型 / 应用）

private struct SourceFilterMenu: View {
    let kinds: [ClipboardKind]
    let sources: [ClipboardSourceOption]
    @Binding var kindFilter: ClipboardKind?
    @Binding var sourceFilter: String?
    let onPick: () -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !kinds.isEmpty {
                    section(title: "类型") {
                        ForEach(kinds, id: \.self) { kind in
                            FilterPill(
                                title: kind.label,
                                symbol: kind.symbolName,
                                icon: nil,
                                isSelected: kindFilter == kind
                            ) {
                                kindFilter = (kindFilter == kind) ? nil : kind
                                onPick()
                            }
                        }
                    }
                }

                if !sources.isEmpty {
                    section(title: "应用") {
                        ForEach(sources) { source in
                            FilterPill(
                                title: source.name,
                                symbol: "app.dashed",
                                icon: source.icon,
                                isSelected: sourceFilter == source.name
                            ) {
                                sourceFilter = (sourceFilter == source.name) ? nil : source.name
                                onPick()
                            }
                        }
                    }
                }

                if kinds.isEmpty && sources.isEmpty {
                    Text("暂无可筛选的记录")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
            }
            .padding(18)
        }
        .frame(width: 540)
        .frame(maxHeight: 460)
    }

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                content()
            }
        }
    }
}

private struct FilterPill: View {
    let title: String
    let symbol: String
    let icon: NSImage?
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                iconView
                    .frame(width: 18, height: 18)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color(nsColor: .controlAccentColor) : Color(nsColor: .labelColor))
            .padding(.horizontal, 12)
            .frame(height: 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                Capsule(style: .continuous)
                    .fill(backgroundColor)
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(
                                isSelected
                                    ? Color(nsColor: .controlAccentColor).opacity(0.5)
                                    : Color(nsColor: .separatorColor).opacity(0.18),
                                lineWidth: 1
                            )
                    }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PasteletPressButtonStyle(pressedScale: 0.96, pressedOpacity: 0.9))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon {
            // 图标已在 AppIconThumbnailCache 预缩到 18pt，这里按原尺寸画即可，无需再插值缩放
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
        }
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color(nsColor: .controlAccentColor).opacity(isHovered ? 0.22 : 0.16)
        }
        return Color(nsColor: .controlColor).opacity(isHovered ? 0.16 : 0.08)
    }
}
