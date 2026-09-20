import SwiftUI

struct ClipboardPanelView: View {
    let monitor: ClipboardMonitor
    private let settings = AppSettings.shared

    let onSelect: (ClipboardItem) -> Void
    let onClear: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void
    let onClose: () -> Void

    @State private var isSearching = false
    @State private var searchText = ""
    /// 实际驱动过滤的查询词，相对 searchText 做 150ms 防抖，避免每次按键都重算过滤 + 重建卡片时间线（打字掉帧）
    @State private var debouncedQuery = ""
    @State private var searchFocusRequest = 0
    @State private var searchResetRequest = 0
    @State private var showFavoritesOnly = false
    @State private var selectedIndex: Int?
    @State private var hoveredItemID: ClipboardItem.ID?
    @State private var deletedItems: [DeletedHistoryItem] = []
    @State private var keyboardScrollRequest = 0
    @State private var timelineResetRequest = 0
    /// 时间线回到开头时是否走动画：过滤条件变化时要「滑」回去；
    /// 面板隐藏期间的重置必须瞬时，否则下次弹出时会看到一段莫名其妙的横向滑动
    /// 「换了一份结果」的代号。过滤条件一变就 +1，卡片据此整批重新浮现——
    /// 靠差量重排（旧卡片滑到新位置）来表达搜索结果，看着就是互相推挤、没有顺序。
    @State private var revealGeneration = 0
    /// 二次过滤：来源 App（按 sourceAppName）与类型（kind），与文本搜索、收藏叠加生效
    @State private var sourceFilter: String? = nil
    @State private var kindFilter: ClipboardKind? = nil
    @State private var showFilterMenu = false

    /// 卡片重排（补位/让位）的主曲线。原来的 response 0.29 + damping 0.94 近乎临界阻尼，
    /// 在 0.98 的微缩放下看着是「跳」而不是「移」；macOS 的内容转场更舍得给时间、
    /// 并留一点回弹余量，眼睛才跟得上位移。
    private var timelineAnimation: Animation {
        .spring(duration: 0.42, bounce: 0.16)
    }

    /// 卡片揭示（浮现）曲线，配合按位置递增的延迟形成从左往右的级联
    private var cardRevealAnimation: Animation {
        .spring(duration: 0.34, bounce: 0.10)
    }

    /// 时间线 ↔ 空状态 的整块交叉淡入
    private var contentSwapAnimation: Animation {
        .easeOut(duration: 0.24)
    }

    /// 揭示级联的每档延迟与档数上限：可视区一次看得见 5~6 张卡，
    /// 30ms 一档刚好能看出「从最近往以前依次铺开」而不觉得在等；
    /// 封顶 12 档是因为再往右已经滚出屏幕，排延迟只会让人白等
    private static let cardStaggerStep = 0.03
    private static let cardStaggerCap = 12

    /// 时间线一次最多渲染多少张卡片。历史现在能存到上千条，而时间线是即时渲染的 HStack
    /// （在 NSScrollView 里，LazyHStack 拿不到可视区、并不会真的偷懒），全量渲染必卡。
    /// 过滤/搜索跑在完整历史上，这里只截结果的前 N 条——搜得到、但一次只画这么多。
    // ponytail: 上限想再抬高就得做真正的窗口化渲染（按滚动偏移只建可视区那几张卡）
    private static let timelineRenderLimit = 120

    private var filteredItems: [ClipboardItem] {
        let query = debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        // lazy + prefix：命中够 N 条就停止扫描，不必为了丢掉的部分把整段历史过一遍
        let matches = monitor.items.lazy.filter { item in
            if showFavoritesOnly, !item.isFavorite { return false }
            if let kindFilter, item.kind != kindFilter { return false }
            if let sourceFilter, item.sourceAppName != sourceFilter { return false }
            guard !query.isEmpty else { return true }

            // 只匹配用户能看到的内容字段；不匹配来源 App 名和类型标签，
            // 否则像搜 "me" 会命中所有来自 "Chrome" 的项，看着像假搜索。
            return [
                item.rawText,
                item.title,
                item.previewTitle,
                item.previewSubtitle,
                item.detail
            ]
            .contains { $0?.localizedCaseInsensitiveContains(query) == true }
        }

        return Array(matches.prefix(Self.timelineRenderLimit))
    }

    /// 历史里出现过的类型（用于过滤菜单「类型」分区），按枚举固定顺序
    private var availableKinds: [ClipboardKind] {
        let present = Set(monitor.items.map(\.kind))
        return ClipboardKind.allCases.filter { present.contains($0) }
    }

    /// 历史里出现过的来源 App（去重，按名称排序），用于过滤菜单「应用」分区
    private var availableSources: [ClipboardSourceOption] {
        var seen = Set<String>()
        var result: [ClipboardSourceOption] = []
        for item in monitor.items {
            let name = item.sourceAppName
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            result.append(
                ClipboardSourceOption(
                    name: name,
                    bundleID: item.sourceBundleIdentifier,
                    // 预缩成 18pt 小图并缓存：避免过滤弹窗每次开窗实时缩放整张 App 大图而掉帧
                    icon: AppIconThumbnailCache.thumbnail(
                        for: item.sourceIcon,
                        key: item.sourceBundleIdentifier ?? name
                    )
                )
            )
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 过滤条件指纹：搜索词 / 类型 / 来源任一变化都意味着「换了一份结果」，
    /// 合成一个值只挂一个 onChange——分成三个会把 body 的类型检查顶爆
    private var filterSignature: String {
        "\(debouncedQuery)|\(kindFilter?.rawValue ?? "")|\(sourceFilter ?? "")"
    }

    /// 选中下标钳制在有效范围内（按给定数量，避免重复计算 filteredItems）
    private func clampedSelection(count: Int) -> Int? {
        guard count > 0, let selectedIndex else { return nil }
        return min(max(0, selectedIndex), count - 1)
    }

    private var panelCornerRadius: CGFloat { 30 }

    private struct TimelineContentSignature: Equatable {
        let items: [TimelineItemSignature]
        let selectedIndex: Int?
        let query: String
        let generation: Int
    }

    private struct TimelineItemSignature: Equatable {
        let id: UUID
        let isFavorite: Bool
        let previewTitle: String?
        let previewSubtitle: String?
        let previewImageID: ObjectIdentifier?
    }

    private struct DeletedHistoryItem: Identifiable {
        let id = UUID()
        let item: ClipboardItem
        let index: Int
    }

    private struct DeletionTarget {
        let item: ClipboardItem
        let filteredIndex: Int
        let followsKeyboardSelection: Bool
    }

    var body: some View {
        // 一次 body 只算一次过滤结果与选中下标，避免在 clampedSelection/timeline/每张卡片里重复全量 filter
        let items = filteredItems
        let selection = clampedSelection(count: items.count)
        // 0 = 没有历史，1 = 有历史但没有匹配，2 = 有结果。整块内容切换按这个值交叉淡入
        let contentMode = monitor.items.isEmpty ? 0 : (items.isEmpty ? 1 : 2)
        return ZStack {
            // macOS 26 Liquid Glass — 对齐 Paste 的高透观感必须用 .clear：
            // .regular 磨砂自带厚重乳白雾感，无论底色多透都看不见壁纸纹理。
            // .clear 合成更贵（大量采样/折射背景），但卡片已完全不透明、可被遮挡剔除，
            // 玻璃实时合成的只剩卡片间隙与顶部工具栏带，负载可接受。
            // 底色垫 0.6（逐轮试出来的：0.18 透过头、0.45 仍偏透、0.76 闷成实心板），
            // 既透出壁纸颜色，又给内容留一层足够的垫底对比度。
            GlassEffectView(
                cornerRadius: panelCornerRadius,
                tintColor: NSColor.windowBackgroundColor.withAlphaComponent(0.6),
                style: .clear
            )
            .clipShape(RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.55), .white.opacity(0.10)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }

            VStack(spacing: 0) {
                toolbar
                    .padding(.horizontal, 28)
                    .padding(.top, 10)
                    .padding(.bottom, 8)

                content(items: items, selection: selection, mode: contentMode)
            }
        }
        .padding(.horizontal, 6)
        .onReceive(NotificationCenter.default.publisher(for: .pasteletNavLeft)) { _ in moveSelection(-1, requestScroll: true) }
        .onReceive(NotificationCenter.default.publisher(for: .pasteletNavRight)) { _ in moveSelection(1, requestScroll: true) }
        .onReceive(NotificationCenter.default.publisher(for: .pasteletNavDelete)) { _ in deleteSelected() }
        .onReceive(NotificationCenter.default.publisher(for: .pasteletNavUndoDelete)) { _ in undoDelete() }
        .onReceive(NotificationCenter.default.publisher(for: .pasteletNavSelect)) { _ in selectCurrent() }
        .onReceive(NotificationCenter.default.publisher(for: .pasteletNavQuickPaste)) { notification in
            guard let number = notification.object as? Int else { return }
            quickPaste(number)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pasteletNavEscape)) { _ in collapseSearch() }
        .onReceive(NotificationCenter.default.publisher(for: .pasteletNavStartSearch)) { _ in
            expandSearch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pasteletNavTypeSearch)) { notification in
            guard let text = notification.object as? String else { return }
            typeIntoSearch(text)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pasteletNavCancelSearch)) { _ in
            // 点击下方卡片区即收起；过滤菜单开着时先让它消化这次点击（关闭弹层），不收起搜索
            if isSearching && !showFilterMenu {
                collapseSearch()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pasteletPanelResetState)) { _ in
            resetPanelState()
        }
        // 过滤条件变了就是一份新结果：把时间线滑回开头，否则先前滚到右边的偏移会留在原处，
        // 搜完看到的是结果列表的中段（内容变窄时还会被 clamp 瞬间拽回来）
        .onChange(of: filterSignature) { resetTimelinePosition() }
        .task(id: searchText) {
            // 清空立即生效；输入时等 150ms 再过滤，打字过程不触发卡片重建
            if searchText.isEmpty {
                debouncedQuery = ""
                return
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            debouncedQuery = searchText
        }
    }

    // MARK: - 键盘选择/删除

    private func moveSelection(_ delta: Int, requestScroll: Bool = false) {
        let count = filteredItems.count
        guard count > 0 else { return }
        let current = clampedSelection(count: count)
        selectedIndex = current.map { min(max(0, $0 + delta), count - 1) } ?? 0
        if requestScroll {
            keyboardScrollRequest += 1
        }
    }

    private func deleteSelected() {
        let items = filteredItems
        guard let target = deletionTarget(in: items) else { return }
        deleteItem(
            target.item,
            filteredIndex: target.filteredIndex,
            followsKeyboardSelection: target.followsKeyboardSelection
        )
    }

    private func deletionTarget(in items: [ClipboardItem]) -> DeletionTarget? {
        if let hoveredItemID,
           let index = items.firstIndex(where: { $0.id == hoveredItemID }) {
            return DeletionTarget(
                item: items[index],
                filteredIndex: index,
                followsKeyboardSelection: false
            )
        }

        guard let selection = clampedSelection(count: items.count) else { return nil }
        return DeletionTarget(
            item: items[selection],
            filteredIndex: selection,
            followsKeyboardSelection: true
        )
    }

    private func deleteItem(
        _ item: ClipboardItem,
        filteredIndex: Int?,
        followsKeyboardSelection: Bool
    ) {
        guard let sourceIndex = monitor.items.firstIndex(where: { $0.id == item.id }) else { return }
        let selectedItemID = clampedSelection(count: filteredItems.count).map { filteredItems[$0].id }

        withAnimation(timelineAnimation) {
            monitor.delete(item)
        }
        rememberDeletedItem(item, sourceIndex: sourceIndex)

        if hoveredItemID == item.id {
            hoveredItemID = nil
        }

        if followsKeyboardSelection, let filteredIndex {
            let nextCount = filteredItems.count
            selectedIndex = nextCount > 0 ? min(filteredIndex, nextCount - 1) : nil
        } else if selectedItemID == item.id {
            selectedIndex = nil
        }
    }

    private func rememberDeletedItem(_ item: ClipboardItem, sourceIndex: Int) {
        deletedItems.append(DeletedHistoryItem(item: item, index: sourceIndex))
        if deletedItems.count > 20 {
            deletedItems.removeFirst(deletedItems.count - 20)
        }
    }

    private func undoDelete() {
        guard let deleted = deletedItems.popLast() else { return }

        withAnimation(timelineAnimation) {
            monitor.restoreDeletedItem(deleted.item, at: deleted.index)
        }
        hoveredItemID = nil
    }

    private func selectCurrent() {
        let items = filteredItems
        guard let selection = clampedSelection(count: items.count) else { return }
        onSelect(items[selection])
    }

    /// 快速粘贴第 N 项（与卡片右下角显示的序号一致，即当前过滤结果里的位置）
    private func quickPaste(_ number: Int) {
        let items = filteredItems
        guard number >= 1, number <= items.count else { return }
        onSelect(items[number - 1])
    }

    private func expandSearch() {
        // 第一次 Cmd+F：展开并聚焦搜索框；已在搜索中再按：切换「来源 / 类型」过滤菜单
        guard !isSearching else {
            showFilterMenu.toggle()
            return
        }

        isSearching = true
        searchFocusRequest += 1
    }

    private func typeIntoSearch(_ text: String) {
        guard !text.isEmpty else { return }
        showFilterMenu = false
        if !isSearching {
            isSearching = true
        }
        // 字符始终立即、按序写入：搜索框展开动画期间 TextField 还没成为第一响应者，
        // 输入全程走事件监视器 → 这里追加，天然有序，不会丢字也不会乱序。
        // 关键是「不在这里抢焦点」：首字符激活时若立刻聚焦，field editor 会以空串初始化、
        // 在下一次原生按键时覆盖掉 searchText 首字符。焦点改由视图层在 searchText 传播完成后再落。
        searchText += text
    }

    private func resetPanelState() {
        isSearching = false
        searchText = ""
        debouncedQuery = ""
        showFavoritesOnly = false
        showFilterMenu = false
        sourceFilter = nil
        kindFilter = nil
        selectedIndex = nil
        hoveredItemID = nil
        searchResetRequest += 1
        timelineResetRequest += 1
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Color.clear
                .frame(width: 34, height: 34)

            Spacer(minLength: 20)

            toolbarCluster

            Spacer(minLength: 20)

            moreMenu
        }
        .frame(height: 44)
    }

    private var toolbarCluster: some View {
        SearchToolbarClusterView(
            isSearching: $isSearching,
            searchText: $searchText,
            showFavoritesOnly: $showFavoritesOnly,
            focusRequest: $searchFocusRequest,
            resetRequest: $searchResetRequest,
            showFilterMenu: $showFilterMenu,
            sourceFilter: $sourceFilter,
            kindFilter: $kindFilter,
            availableKinds: { availableKinds },
            availableSources: { availableSources },
            onClipboardSelected: {
                resetTimelinePosition()
            },
            onFavoritesSelected: {
                resetTimelinePosition()
            },
            onSearchCancelled: {
                collapseSearch()
            }
        )
        .frame(width: 522, height: 44)
    }

    private func collapseSearch() {
        guard isSearching else { return }
        isSearching = false
        showFilterMenu = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
            if !isSearching {
                searchText = ""
                debouncedQuery = ""
                sourceFilter = nil
                kindFilter = nil
            }
        }
    }

    private func resetTimelinePosition() {
        selectedIndex = nil
        hoveredItemID = nil
        timelineResetRequest += 1
        revealGeneration += 1
    }

    private var moreMenu: some View {
        Menu {
            Button("打开设置", action: onSettings)
            Divider()
            Button("退出 Pastelet", role: .destructive, action: onQuit)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("更多")
    }

    /// 时间线 / 空状态。用 ZStack 而不是 VStack 里的 if/else：交叉淡入期间新旧两块同时在树上，
    /// 竖排会被挤成各占一半高度（先塌一下再复位），叠放才不会动到布局。
    @ViewBuilder
    private func content(items: [ClipboardItem], selection: Int?, mode: Int) -> some View {
        ZStack {
            switch mode {
            case 0:
                emptyState(title: "复制内容后会显示在这里")
                    .transition(.opacity)
            case 1:
                emptyState(title: showFavoritesOnly
                           ? "还没有收藏的项目（右键卡片可收藏）"
                           : "没有找到匹配的剪贴板项目")
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .center)))
            default:
                timeline(
                    items: items,
                    selection: selection,
                    query: debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(contentSwapAnimation, value: mode)
    }

    private func timeline(items: [ClipboardItem], selection: Int?, query: String) -> some View {
        SmoothHorizontalScrollView(
            selectedIndex: selection ?? 0,
            scrollRequest: keyboardScrollRequest,
            resetRequest: timelineResetRequest,
            contentSignature: timelineSignature(items: items, selection: selection, query: query),
            itemCount: items.count,
            itemWidth: 232,
            spacing: 18
        ) {
            HStack(alignment: .top, spacing: 18) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    ClipboardCardView(
                        item: item,
                        index: index + 1,
                        isSelected: index == selection,
                        searchQuery: query,
                        onSelect: { onSelect(item) },
                        onToggleFavorite: { monitor.toggleFavorite(item) },
                        onCopy: { monitor.restore(item) },
                        onDelete: {
                            deleteItem(item, filteredIndex: index, followsKeyboardSelection: false)
                        },
                        onHoverChanged: { hovering in
                            if hovering {
                                hoveredItemID = item.id
                            } else if hoveredItemID == item.id {
                                hoveredItemID = nil
                            }
                        }
                    )
                    .id(item.id)
                    .modifier(
                        StaggeredReveal(
                            generation: revealGeneration,
                            delay: Double(min(index, Self.cardStaggerCap)) * Self.cardStaggerStep,
                            animation: cardRevealAnimation
                        )
                    )
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 2)
            .padding(.bottom, 16)
            .animation(timelineAnimation, value: items.map(\.id))
        }
    }

    private func timelineSignature(
        items: [ClipboardItem],
        selection: Int?,
        query: String
    ) -> TimelineContentSignature {
        TimelineContentSignature(
            items: items.map {
                TimelineItemSignature(
                    id: $0.id,
                    isFavorite: $0.isFavorite,
                    previewTitle: $0.previewTitle,
                    previewSubtitle: $0.previewSubtitle,
                    previewImageID: $0.previewImage.map(ObjectIdentifier.init)
                )
            },
            selectedIndex: selection,
            query: query,
            generation: revealGeneration
        )
    }

    private func emptyState(title: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)

            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)

            Text("按 \(settings.launchShortcut?.displayString ?? "菜单栏") 呼出 Pastelet，点击卡片会复制回系统剪贴板。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

/// 按位置级联的「浮现」：generation 变化 = 换了一份结果，卡片先瞬时归零再依次浮上来。
///
/// 为什么不用 .transition：HStack 里正在退场的卡片仍然占布局宽度，过滤前后两批并排
/// 会把内容撑宽再缩回，加上 identity 复用的卡片从旧位置一路滑到新位置 —— 三种动画
/// 叠在一起就是「先冒出一条旧记录、又被新记录推到后面」。
/// 这里换成显式状态：数据替换不动画（瞬时，看不见推挤），只有浮现这一个方向有动画。
private struct StaggeredReveal: ViewModifier {
    let generation: Int
    let delay: Double
    let animation: Animation

    @State private var shownGeneration = -1

    func body(content: Content) -> some View {
        let shown = shownGeneration == generation
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : 0.96, anchor: .bottom)
            .offset(y: shown ? 0 : 8)
            // 归零那一下传 nil 不动画（否则会被外层的重排曲线拖成一次可见的淡出），
            // 只给「浮现」方向排延迟
            .animation(shown ? animation.delay(delay) : nil, value: shown)
            .onAppear { shownGeneration = generation }
            .onChange(of: generation) { shownGeneration = generation }
    }
}
