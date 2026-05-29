import AppKit
import SwiftUI

/// 横向滚动容器：鼠标滚轮（纵向）也能横向滚动 + 平滑动画 + 键盘定位。
struct SmoothHorizontalScrollView<Content: View>: NSViewRepresentable {
    let selectedIndex: Int
    let scrollRequest: Int
    let itemWidth: CGFloat
    let spacing: CGFloat
    let content: Content

    init(
        selectedIndex: Int,
        scrollRequest: Int,
        itemWidth: CGFloat,
        spacing: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.selectedIndex = selectedIndex
        self.scrollRequest = scrollRequest
        self.itemWidth = itemWidth
        self.spacing = spacing
        self.content = content()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> VellumSmoothScrollView {
        let scrollView = VellumSmoothScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.allowsMagnification = false
        scrollView.verticalScrollElasticity = .none

        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
        scrollView.documentView = hostingView
        context.coordinator.hostingView = hostingView
        return scrollView
    }

    func updateNSView(_ scrollView: VellumSmoothScrollView, context: Context) {
        guard let hostingView = context.coordinator.hostingView else { return }

        hostingView.rootView = content
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: max(fittingSize.width, scrollView.contentView.bounds.width),
            height: max(fittingSize.height, scrollView.contentView.bounds.height)
        )

        if context.coordinator.lastScrollRequest != scrollRequest {
            context.coordinator.lastScrollRequest = scrollRequest
            scrollView.scrollToIndex(
                selectedIndex,
                itemWidth: itemWidth,
                spacing: spacing,
                animated: true
            )
        }
    }

    final class Coordinator {
        var hostingView: NSHostingView<Content>?
        var lastScrollRequest = 0
    }
}

final class VellumSmoothScrollView: NSScrollView {
    private var targetX: CGFloat = 0
    private var isAnimatingWheel = false

    override func scrollWheel(with event: NSEvent) {
        guard let documentView else {
            super.scrollWheel(with: event)
            return
        }

        let maxX = max(0, documentView.frame.width - contentView.bounds.width)
        guard maxX > 0 else { return }

        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY
        let delta = abs(deltaX) >= abs(deltaY) ? deltaX : deltaY
        guard delta != 0 else { return }

        if event.hasPreciseScrollingDeltas {
            // 触摸板：直接跟手（系统本身已平滑）
            let x = min(max(0, contentView.bounds.origin.x - delta), maxX)
            contentView.setBoundsOrigin(NSPoint(x: x, y: 0))
            reflectScrolledClipView(contentView)
            targetX = x
        } else {
            // 鼠标滚轮：每格固定步长累加，动画平滑滑过去
            let base = isAnimatingWheel ? targetX : contentView.bounds.origin.x
            let step: CGFloat = 90
            targetX = min(max(0, base - (delta > 0 ? step : -step)), maxX)
            animateWheelScroll()
        }
    }

    private func animateWheelScroll() {
        isAnimatingWheel = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            contentView.animator().setBoundsOrigin(NSPoint(x: targetX, y: 0))
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isAnimatingWheel = false
                self.reflectScrolledClipView(self.contentView)
            }
        }
        reflectScrolledClipView(contentView)
    }

    func scrollToIndex(
        _ index: Int,
        itemWidth: CGFloat,
        spacing: CGFloat,
        animated: Bool
    ) {
        guard let documentView else { return }

        let visibleWidth = contentView.bounds.width
        let itemStride = itemWidth + spacing
        let itemMidX = CGFloat(index) * itemStride + itemWidth / 2 + 26
        let maxX = max(0, documentView.frame.width - visibleWidth)
        let target = min(max(0, itemMidX - visibleWidth / 2), maxX)
        targetX = target
        let origin = NSPoint(x: target, y: 0)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.92, 0.20, 1)
                contentView.animator().setBoundsOrigin(origin)
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.reflectScrolledClipView(self.contentView)
                }
            }
        } else {
            contentView.setBoundsOrigin(origin)
            reflectScrolledClipView(contentView)
        }
    }
}
