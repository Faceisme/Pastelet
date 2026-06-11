import SwiftUI

struct ClipboardPanelView: View {
    @ObservedObject var monitor: ClipboardMonitor
    @ObservedObject private var settings = AppSettings.shared

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
    /// 二次过滤：来源 App（按 sourceAppName）与类型（kind），与文本搜索、收藏叠加生效
    @State private var sourceFilter: String? = nil
    @State private var kindFilter: ClipboardKind? = nil
    @State private var showFilterMenu = false

    private var timelineAnimation: Animation {
        .spring(response: 0.29, dampingFraction: 0.94, blendDuration: 0.04)
    }

    private var filteredItems: [ClipboardItem] {
        var result = monitor.items

        if showFavoritesOnly {
            result = result.filter(\.isFavorite)
        }

        if let kindFilter {
            result = result.filter { $0.kind == kindFilter }
        }

        if let sourceFilter {
            result = result.filter { $0.sourceAppName == sourceFilter }
        }

        let query = debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            // 只匹配用户能看到的内容字段；不再匹配来源 App 名和类型标签，
            // 否则像搜 "me" 会命中所有来自 "Chrome" 的项，看着像假搜索。
            result = result.filter { item in
                [
                    item.rawText,
                    item.title,
                    item.previewTitle,
                    item.previewSubtitle,
                    item.detail
                ]
                .compactMap(\.self)
                .contains { value in
                    value.localizedCaseInsensitiveContains(query)
                }
            }
        }

        return result
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
        return ZStack {
            // macOS 26 Liquid Glass — 用 .regular（磨砂）而非 .clear（高透）：后者要大量采样/折射
            // 背景，合成最贵；.regular 更实、合成更轻（对齐 Paste 的磨砂观感，降 WindowServer 负载）。
            // 底色也调实一些，进一步减少需要实时合成的背景面积。
            GlassEffectView(
                cornerRadius: panelCornerRadius,
                tintColor: NSColor.windowBackgroundColor.withAlphaComponent(0.76),
                style: .regular
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

                if monitor.items.isEmpty {
                    emptyState(title: "复制内容后会显示在这里")
                } else if items.isEmpty {
                    emptyState(title: showFavoritesOnly
                               ? "还没有收藏的项目（右键卡片可收藏）"
                               : "没有找到匹配的剪贴板项目")
                } else {
                    timeline(items: items, selection: selection,
                             query: debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines))
                }
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
        if !isSearching {
            isSearching = true
        }
        showFilterMenu = false
        searchText += text
        searchFocusRequest += 1
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
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .center)),
                            removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .center))
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
            query: query
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
