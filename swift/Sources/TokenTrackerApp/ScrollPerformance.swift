//
//  ScrollPerformance.swift
//  TokenTrackerApp
//
//  滚动与布局性能基础设施：
//  - ScrollActivity：O(1) 追踪主窗口实时滚动状态，滚动期间屏蔽悬停重建与重绘，
//    只清理当前正在悬停的 1–2 个元素，不触发全局 ObservableObject 刷新。
//  - Adaptive*Layout：单次求值、单遍测量的响应式 Layout，替代 ScrollView 内的
//    ViewThatFits（避免双重实例化图表与嵌套 2×2 测量）。
//  - CardListRowBackground：供 LazyVStack 列表按首/中/尾行拼出统一卡片圆角，
//    避免对数百行超长卡片套整块 .clipShape 造成离屏遮罩与破坏懒加载。
//  - SegmentedBar：基于 Canvas 的零 GeometryReader 分段占比条。
//

import AppKit
import SwiftUI

// ------------------------------------------------------------------ 滚动悬停协调 ----

@MainActor
final class ScrollActivity {
    static let shared = ScrollActivity()

    private var liveScrollCount = 0
    private var wheelScrolling = false
    private var wheelResetTimer: Timer?
    private var wheelDeadline: TimeInterval = 0
    private var activeHoverClearers: [UUID: () -> Void] = [:]
    private var observers: [NSObjectProtocol] = []
    private var scrollMonitor: Any?
    private var testingOverride: Bool?

    var isScrolling: Bool {
        if let testingOverride { return testingOverride }
        return liveScrollCount > 0 || wheelScrolling
    }

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.liveScrollStarted() }
        })
        observers.append(center.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.liveScrollEnded() }
        })
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.handleScrollWheel(event) }
            return event
        }
    }

    /// 仅当前处于悬停态的视图（通常 0–2 个）注册清理闭包；滚动开始时 O(1) 清掉。
    @discardableResult
    func registerActiveHover(_ onScrollStart: @escaping () -> Void) -> UUID {
        let id = UUID()
        activeHoverClearers[id] = onScrollStart
        return id
    }

    func unregisterActiveHover(_ id: UUID?) {
        guard let id else { return }
        activeHoverClearers.removeValue(forKey: id)
    }

    /// 供单元测试模拟滚动态切换。
    func setScrollingForTesting(_ active: Bool?) {
        let was = isScrolling
        testingOverride = active
        if !was && isScrolling { clearActiveHovers() }
    }

    private func liveScrollStarted() {
        let was = isScrolling
        liveScrollCount += 1
        if !was { clearActiveHovers() }
    }

    private func liveScrollEnded() {
        liveScrollCount = max(0, liveScrollCount - 1)
    }

    private func handleScrollWheel(_ event: NSEvent) {
        // 离散滚轮或触控板滑动：触控板抬手/惯性结束立即恢复，离散滚轮 140ms 后恢复。
        if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
            stopWheelCooldown()
            return
        }
        if event.phase == .ended || event.phase == .cancelled {
            // 抬手后可能紧接惯性阶段，保留短暂冷却避免首帧闪一下悬停。
            scheduleWheelCooldown(seconds: 0.10)
            return
        }
        let was = isScrolling
        wheelScrolling = true
        if !was { clearActiveHovers() }
        scheduleWheelCooldown(seconds: 0.14)
    }

    private func scheduleWheelCooldown(seconds: TimeInterval) {
        wheelDeadline = ProcessInfo.processInfo.systemUptime + seconds
        guard wheelResetTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if ProcessInfo.processInfo.systemUptime >= self.wheelDeadline {
                    self.stopWheelCooldown()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        wheelResetTimer = timer
    }

    private func stopWheelCooldown() {
        wheelResetTimer?.invalidate()
        wheelResetTimer = nil
        wheelScrolling = false
    }

    private func clearActiveHovers() {
        guard !activeHoverClearers.isEmpty else { return }
        let callbacks = Array(activeHoverClearers.values)
        activeHoverClearers.removeAll()
        for callback in callbacks { callback() }
    }
}

/// 持有 ScrollActivity 注册句柄而不触发 SwiftUI @State 重算。
@MainActor
final class HoverTokenBox {
    var id: UUID?

    func setActive(_ active: Bool, clear: @escaping () -> Void) {
        if active {
            if id == nil {
                id = ScrollActivity.shared.registerActiveHover { [weak self] in
                    self?.id = nil
                    clear()
                }
            }
        } else if let current = id {
            id = nil
            ScrollActivity.shared.unregisterActiveHover(current)
        }
    }

    func unregister() {
        if let current = id {
            id = nil
            ScrollActivity.shared.unregisterActiveHover(current)
        }
    }
}

// ------------------------------------------------------------------ 响应式 Layout ----

/// 两列固定右侧宽度的自适应布局：宽屏横排（左弹性 + 右定宽），窄屏纵排（均满宽）。
/// 相比 ViewThatFits，子视图只构造一次、单遍测量，且跨断点保留状态。
struct AdaptiveSplitLayout: Layout {
    let minLeadingWidth: CGFloat
    let trailingWidth: CGFloat
    let spacing: CGFloat

    private var horizontalThreshold: CGFloat {
        minLeadingWidth + spacing + trailingWidth
    }

    private func isHorizontal(_ width: CGFloat?) -> Bool {
        guard let width, width.isFinite else { return true }
        return width >= horizontalThreshold
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        if subviews.count == 1 {
            return subviews[0].sizeThatFits(proposal)
        }
        let horizontal = isHorizontal(proposal.width)
        let totalWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? horizontalThreshold
        if horizontal {
            let leadingW = max(1, totalWidth - trailingWidth - spacing)
            let s0 = subviews[0].sizeThatFits(ProposedViewSize(width: leadingW, height: nil))
            let s1 = subviews[1].sizeThatFits(ProposedViewSize(width: trailingWidth, height: nil))
            return CGSize(width: totalWidth, height: max(s0.height, s1.height))
        } else {
            var totalHeight: CGFloat = 0
            for (index, subview) in subviews.enumerated() {
                let s = subview.sizeThatFits(ProposedViewSize(width: totalWidth, height: nil))
                totalHeight += s.height + (index > 0 ? spacing : 0)
            }
            return CGSize(width: totalWidth, height: totalHeight)
        }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        if subviews.count == 1 {
            subviews[0].place(at: bounds.origin,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
            return
        }
        if isHorizontal(bounds.width) {
            let leadingW = max(1, bounds.width - trailingWidth - spacing)
            let s0 = subviews[0].sizeThatFits(ProposedViewSize(width: leadingW, height: nil))
            let s1 = subviews[1].sizeThatFits(ProposedViewSize(width: trailingWidth, height: nil))
            subviews[0].place(at: bounds.origin,
                              proposal: ProposedViewSize(width: leadingW, height: s0.height))
            subviews[1].place(at: CGPoint(x: bounds.minX + leadingW + spacing, y: bounds.minY),
                              proposal: ProposedViewSize(width: trailingWidth, height: s1.height))
        } else {
            var y = bounds.minY
            for subview in subviews {
                let s = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subview.place(at: CGPoint(x: bounds.minX, y: y),
                              proposal: ProposedViewSize(width: bounds.width, height: s.height))
                y += s.height + spacing
            }
        }
    }
}

/// 两列固定左侧宽度的自适应布局：宽屏横排（左定宽 + 右弹性），窄屏纵排。
struct AdaptiveLeadingFixedLayout: Layout {
    let leadingWidth: CGFloat
    let minTrailingWidth: CGFloat
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat
    var horizontalAlignment: VerticalAlignment = .top
    var stackCenterLeading: Bool = false

    init(leadingWidth: CGFloat, minTrailingWidth: CGFloat, spacing: CGFloat,
         verticalSpacing: CGFloat? = nil,
         horizontalAlignment: VerticalAlignment = .top,
         stackCenterLeading: Bool = false) {
        self.leadingWidth = leadingWidth
        self.minTrailingWidth = minTrailingWidth
        self.horizontalSpacing = spacing
        self.verticalSpacing = verticalSpacing ?? spacing
        self.horizontalAlignment = horizontalAlignment
        self.stackCenterLeading = stackCenterLeading
    }

    private var horizontalThreshold: CGFloat {
        leadingWidth + horizontalSpacing + minTrailingWidth
    }

    private func isHorizontal(_ width: CGFloat?) -> Bool {
        guard let width, width.isFinite else { return true }
        return width >= horizontalThreshold
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        if subviews.count == 1 { return subviews[0].sizeThatFits(proposal) }
        let totalWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? horizontalThreshold
        if isHorizontal(proposal.width) {
            let trailingW = max(1, totalWidth - leadingWidth - horizontalSpacing)
            let s0 = subviews[0].sizeThatFits(ProposedViewSize(width: leadingWidth, height: nil))
            let s1 = subviews[1].sizeThatFits(ProposedViewSize(width: trailingW, height: nil))
            return CGSize(width: totalWidth, height: max(s0.height, s1.height))
        } else {
            let leadingProp = ProposedViewSize(width: stackCenterLeading ? leadingWidth : totalWidth, height: nil)
            let s0 = subviews[0].sizeThatFits(leadingProp)
            let s1 = subviews[1].sizeThatFits(ProposedViewSize(width: totalWidth, height: nil))
            return CGSize(width: totalWidth, height: s0.height + verticalSpacing + s1.height)
        }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        if subviews.count == 1 {
            subviews[0].place(at: bounds.origin,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
            return
        }
        if isHorizontal(bounds.width) {
            let trailingW = max(1, bounds.width - leadingWidth - horizontalSpacing)
            let s0 = subviews[0].sizeThatFits(ProposedViewSize(width: leadingWidth, height: nil))
            let s1 = subviews[1].sizeThatFits(ProposedViewSize(width: trailingW, height: nil))
            let rowH = max(s0.height, s1.height)
            let y0 = horizontalAlignment == .center ? bounds.minY + (rowH - s0.height) / 2 : bounds.minY
            let y1 = horizontalAlignment == .center ? bounds.minY + (rowH - s1.height) / 2 : bounds.minY
            subviews[0].place(at: CGPoint(x: bounds.minX, y: y0),
                              proposal: ProposedViewSize(width: leadingWidth, height: s0.height))
            subviews[1].place(at: CGPoint(x: bounds.minX + leadingWidth + horizontalSpacing, y: y1),
                              proposal: ProposedViewSize(width: trailingW, height: s1.height))
        } else {
            let leadingW = stackCenterLeading ? min(leadingWidth, bounds.width) : bounds.width
            let s0 = subviews[0].sizeThatFits(ProposedViewSize(width: leadingW, height: nil))
            let x0 = stackCenterLeading ? bounds.minX + (bounds.width - s0.width) / 2 : bounds.minX
            subviews[0].place(at: CGPoint(x: x0, y: bounds.minY),
                              proposal: ProposedViewSize(width: leadingW, height: s0.height))
            let s1 = subviews[1].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + s0.height + verticalSpacing),
                              proposal: ProposedViewSize(width: bounds.width, height: s1.height))
        }
    }
}

/// 等宽多列自适应布局：宽屏横排等分，窄屏纵排。支持同高拉伸或定高横排。
struct AdaptiveEqualColumnsLayout: Layout {
    let minColumnWidth: CGFloat
    let spacing: CGFloat
    var equalHeight: Bool = false
    var horizontalHeight: CGFloat? = nil
    var minHorizontalWidthOverride: CGFloat? = nil

    private func threshold(count: Int) -> CGFloat {
        if let override = minHorizontalWidthOverride { return override }
        let n = CGFloat(max(1, count))
        return n * minColumnWidth + CGFloat(max(0, count - 1)) * spacing
    }

    private func isHorizontal(_ width: CGFloat?, count: Int) -> Bool {
        guard count > 1 else { return false }
        guard let width, width.isFinite else { return true }
        return width >= threshold(count: count)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let count = subviews.count
        guard count > 0 else { return .zero }
        let fallbackW = threshold(count: count)
        let totalWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? fallbackW
        if isHorizontal(proposal.width, count: count) {
            let colW = max(1, (totalWidth - CGFloat(count - 1) * spacing) / CGFloat(count))
            if let fixedH = horizontalHeight {
                return CGSize(width: totalWidth, height: fixedH)
            }
            var maxH: CGFloat = 0
            for subview in subviews {
                let s = subview.sizeThatFits(ProposedViewSize(width: colW, height: nil))
                maxH = max(maxH, s.height)
            }
            return CGSize(width: totalWidth, height: maxH)
        } else {
            var totalH: CGFloat = 0
            for (index, subview) in subviews.enumerated() {
                let s = subview.sizeThatFits(ProposedViewSize(width: totalWidth, height: nil))
                totalH += s.height + (index > 0 ? spacing : 0)
            }
            return CGSize(width: totalWidth, height: totalH)
        }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let count = subviews.count
        guard count > 0 else { return }
        if isHorizontal(bounds.width, count: count) {
            let colW = max(1, (bounds.width - CGFloat(count - 1) * spacing) / CGFloat(count))
            let rowH: CGFloat?
            if let fixedH = horizontalHeight {
                rowH = fixedH
            } else if equalHeight {
                var maxH: CGFloat = 0
                for subview in subviews {
                    maxH = max(maxH, subview.sizeThatFits(ProposedViewSize(width: colW, height: nil)).height)
                }
                rowH = maxH
            } else {
                rowH = nil
            }
            for (index, subview) in subviews.enumerated() {
                let x = bounds.minX + CGFloat(index) * (colW + spacing)
                let h = rowH ?? subview.sizeThatFits(ProposedViewSize(width: colW, height: nil)).height
                subview.place(at: CGPoint(x: x, y: bounds.minY),
                              proposal: ProposedViewSize(width: colW, height: h))
            }
        } else {
            var y = bounds.minY
            for subview in subviews {
                let s = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subview.place(at: CGPoint(x: bounds.minX, y: y),
                              proposal: ProposedViewSize(width: bounds.width, height: s.height))
                y += s.height + spacing
            }
        }
    }
}

/// 指标块网格：放得下一行 N 块就单行等高横排，窄屏退成 fallbackColumns 列等高网格。
struct AdaptiveTileGridLayout: Layout {
    let maxColumns: Int
    let fallbackColumns: Int
    let minColumnWidth: CGFloat
    let spacing: CGFloat

    private func columns(for width: CGFloat?, count: Int) -> Int {
        let singleRow = max(1, min(maxColumns, count))
        guard let width, width.isFinite else { return singleRow }
        let needed = CGFloat(singleRow) * minColumnWidth + CGFloat(max(0, singleRow - 1)) * spacing
        return width >= needed ? singleRow : max(1, min(fallbackColumns, count))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let count = subviews.count
        guard count > 0 else { return .zero }
        let cols = columns(for: proposal.width, count: count)
        let defaultW = CGFloat(cols) * minColumnWidth + CGFloat(max(0, cols - 1)) * spacing
        let totalWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? defaultW
        let colW = max(1, (totalWidth - CGFloat(cols - 1) * spacing) / CGFloat(cols))
        let rows = (count + cols - 1) / cols
        var totalHeight: CGFloat = 0
        for row in 0..<rows {
            var rowH: CGFloat = 0
            for col in 0..<cols {
                let idx = row * cols + col
                guard idx < count else { break }
                let s = subviews[idx].sizeThatFits(ProposedViewSize(width: colW, height: nil))
                rowH = max(rowH, s.height)
            }
            totalHeight += rowH + (row > 0 ? spacing : 0)
        }
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let count = subviews.count
        guard count > 0 else { return }
        let cols = columns(for: bounds.width, count: count)
        let colW = max(1, (bounds.width - CGFloat(cols - 1) * spacing) / CGFloat(cols))
        let rows = (count + cols - 1) / cols
        var y = bounds.minY
        for row in 0..<rows {
            var rowH: CGFloat = 0
            for col in 0..<cols {
                let idx = row * cols + col
                guard idx < count else { break }
                rowH = max(rowH, subviews[idx].sizeThatFits(ProposedViewSize(width: colW, height: nil)).height)
            }
            for col in 0..<cols {
                let idx = row * cols + col
                guard idx < count else { break }
                let x = bounds.minX + CGFloat(col) * (colW + spacing)
                subviews[idx].place(at: CGPoint(x: x, y: y),
                                    proposal: ProposedViewSize(width: colW, height: rowH))
            }
            y += rowH + spacing
        }
    }
}

/// 带中间竖分隔线的双栏自适应布局：期望 3 个子视图（左栏、Divider、右栏）。
/// 宽屏横排等分并展示分隔线；窄屏纵排并收起分隔线。
struct AdaptiveDividedPairLayout: Layout {
    let minFirstWidth: CGFloat
    let minSecondWidth: CGFloat
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat
    let dividerWidth: CGFloat = 1

    private var horizontalThreshold: CGFloat {
        minFirstWidth + minSecondWidth + dividerWidth + horizontalSpacing * 2
    }

    private func isHorizontal(_ width: CGFloat?) -> Bool {
        guard let width, width.isFinite else { return true }
        return width >= horizontalThreshold
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 3 else {
            return subviews.first?.sizeThatFits(proposal) ?? .zero
        }
        let totalWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? horizontalThreshold
        if isHorizontal(proposal.width) {
            let colW = max(1, (totalWidth - dividerWidth - horizontalSpacing * 2) / 2)
            let s0 = subviews[0].sizeThatFits(ProposedViewSize(width: colW, height: nil))
            let s1 = subviews[1].sizeThatFits(ProposedViewSize(width: dividerWidth, height: nil))
            let s2 = subviews[2].sizeThatFits(ProposedViewSize(width: colW, height: nil))
            return CGSize(width: totalWidth, height: max(s0.height, s1.height, s2.height))
        } else {
            let s0 = subviews[0].sizeThatFits(ProposedViewSize(width: totalWidth, height: nil))
            let s2 = subviews[2].sizeThatFits(ProposedViewSize(width: totalWidth, height: nil))
            return CGSize(width: totalWidth, height: s0.height + verticalSpacing + s2.height)
        }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        if isHorizontal(bounds.width) {
            let colW = max(1, (bounds.width - dividerWidth - horizontalSpacing * 2) / 2)
            let s0 = subviews[0].sizeThatFits(ProposedViewSize(width: colW, height: nil))
            let s1 = subviews[1].sizeThatFits(ProposedViewSize(width: dividerWidth, height: nil))
            let s2 = subviews[2].sizeThatFits(ProposedViewSize(width: colW, height: nil))
            subviews[0].place(at: bounds.origin,
                              proposal: ProposedViewSize(width: colW, height: s0.height))
            subviews[1].place(at: CGPoint(x: bounds.minX + colW + horizontalSpacing, y: bounds.minY),
                              proposal: ProposedViewSize(width: dividerWidth, height: s1.height))
            subviews[2].place(at: CGPoint(x: bounds.minX + colW + horizontalSpacing * 2 + dividerWidth, y: bounds.minY),
                              proposal: ProposedViewSize(width: colW, height: s2.height))
        } else {
            let s0 = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(at: bounds.origin,
                              proposal: ProposedViewSize(width: bounds.width, height: s0.height))
            subviews[1].place(at: bounds.origin,
                              proposal: ProposedViewSize(width: 0, height: 0))
            let s2 = subviews[2].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[2].place(at: CGPoint(x: bounds.minX, y: bounds.minY + s0.height + verticalSpacing),
                              proposal: ProposedViewSize(width: bounds.width, height: s2.height))
        }
    }
}

// ------------------------------------------------------------------ 懒列表卡片行背景 ----

/// 供 LazyVStack 列表按首/中/尾行拼出统一卡片表面与圆角，替代包裹整张列表的 .clipShape。
struct CardListRowBackground: View {
    let isFirst: Bool
    let isLast: Bool
    var radius: CGFloat = Metrics.cardRadius

    var body: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: isFirst ? radius : 0,
            bottomLeadingRadius: isLast ? radius : 0,
            bottomTrailingRadius: isLast ? radius : 0,
            topTrailingRadius: isFirst ? radius : 0,
            style: .continuous
        )
        .fill(Color.cardSurface)
    }
}

/// 仅对首行/末行应用圆角裁剪，中间行保持零遮罩，兼顾悬停高亮不溢出与滚动性能。
struct CardListRowClip: ViewModifier {
    let isFirst: Bool
    let isLast: Bool
    var radius: CGFloat = Metrics.cardRadius

    @ViewBuilder
    func body(content: Content) -> some View {
        if isFirst || isLast {
            content.clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: isFirst ? radius : 0,
                    bottomLeadingRadius: isLast ? radius : 0,
                    bottomTrailingRadius: isLast ? radius : 0,
                    topTrailingRadius: isFirst ? radius : 0,
                    style: .continuous
                )
            )
        } else {
            content
        }
    }
}

// ------------------------------------------------------------------ 零 GeometryReader 分段条 ----

struct SegmentedBarSegment: Equatable {
    let value: Double
    let color: Color
    var minWidth: CGFloat = 3
}

/// 单遍 Canvas 绘制的多段占比胶囊条，避免在 ScrollView 中堆叠 GeometryReader。
struct SegmentedBar: View {
    let segments: [SegmentedBarSegment]
    var height: CGFloat = 10
    var spacing: CGFloat = 2
    var cornerRadius: CGFloat? = nil
    var emptyColor: Color = Color.primary.opacity(0.08)

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            let active = segments.filter { $0.value > 0 }
            let fullRect = CGRect(origin: .zero, size: size)
            if let radius = cornerRadius {
                if active.isEmpty {
                    context.fill(Path(roundedRect: fullRect, cornerRadius: radius), with: .color(emptyColor))
                    return
                }
                let total = active.reduce(0.0) { $0 + $1.value }
                let usableWidth = max(0, size.width - CGFloat(max(0, active.count - 1)) * spacing)
                var x: CGFloat = 0
                for (index, seg) in active.enumerated() {
                    let isLast = index == active.count - 1
                    let rawW = max(seg.minWidth, usableWidth * CGFloat(seg.value / total))
                    let w = isLast ? max(0, size.width - x) : min(rawW, max(0, size.width - x))
                    if w > 0 {
                        let rect = CGRect(x: x, y: 0, width: w, height: size.height)
                        context.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(seg.color))
                    }
                    x += w + spacing
                }
            } else {
                let clipPath = Capsule().path(in: fullRect)
                context.clip(to: clipPath)
                if active.isEmpty {
                    context.fill(Path(fullRect), with: .color(emptyColor))
                    return
                }
                let total = active.reduce(0.0) { $0 + $1.value }
                let largestIdx = active.indices.max { active[$0].value < active[$1].value } ?? 0
                let totalSpacing = CGFloat(max(0, active.count - 1)) * spacing
                var widths = [CGFloat](repeating: 0, count: active.count)
                var fixedSum: CGFloat = 0
                for i in active.indices where i != largestIdx {
                    let w = max(active[i].minWidth, size.width * CGFloat(active[i].value / total))
                    widths[i] = w
                    fixedSum += w
                }
                widths[largestIdx] = max(0, size.width - totalSpacing - fixedSum)
                var x: CGFloat = 0
                for (i, seg) in active.enumerated() {
                    let w = widths[i]
                    if w > 0 {
                        context.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)),
                                     with: .color(seg.color))
                    }
                    x += w + spacing
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
