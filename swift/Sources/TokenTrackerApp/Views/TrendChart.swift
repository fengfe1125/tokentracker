//
//  TrendChart.swift
//  TokenTrackerApp
//
//  使用趋势：每个时间桶一根堆叠柱（Token 四类），成本折线走右轴。
//  桶是离散的小时 / 天，柱形不在两个桶之间虚构过渡值。
//  「今天」按固定 24 小时槽展示（带「此刻」锚线与未到来时段区分），
//  悬停显示该桶的合计、四类明细与成本。
//

import Charts
import SwiftUI

/// 每个时间桶跨工具聚合后的用量点
struct TrendPoint: Identifiable, Equatable {
    let id: String
    let day: String
    let input: Double, output: Double
    let cacheRead: Double, cacheWrite: Double
    let cost: Double
    /// 「今天」24 小时固定槽中尚未到来的小时。非小时图恒为 false。
    var isFuture: Bool = false
    /// 「今天」24 小时固定槽中当前正在进行的小时。非小时图恒为 false。
    var isCurrent: Bool = false

    var tokens: Double { input + output + cacheRead + cacheWrite }

    func value(_ kind: TokenKind) -> Double {
        switch kind {
        case .cacheRead: cacheRead
        case .input: input
        case .cacheWrite: cacheWrite
        case .output: output
        }
    }
}

/// 概览「今天」的纯数据整理与切换规则（无 UI 依赖，便于单元测试）。
enum TodayTrendBuilder {
    /// 活跃小时数 ≤ 2 时默认展示今日实时脉冲面板；≥ 3 时自动切回 24 小时柱图。
    static let sparseHourThreshold = 2

    /// 将今天非空小时桶补齐为固定 24 小时槽（00:00–23:00），并标记当前与未来时段。
    static func daySlots(from points: [TrendPoint],
                         now: Date = Date(),
                         calendar: Calendar = .current) -> [TrendPoint] {
        let currentHour = calendar.component(.hour, from: now)
        let byID = Dictionary(points.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        return (0..<24).map { hour in
            let id = String(format: "%02d:00", hour)
            if let existing = byID[id] {
                return TrendPoint(
                    id: id, day: id,
                    input: existing.input, output: existing.output,
                    cacheRead: existing.cacheRead, cacheWrite: existing.cacheWrite,
                    cost: existing.cost,
                    isFuture: false,
                    isCurrent: hour == currentHour
                )
            }
            return TrendPoint(
                id: id, day: id,
                input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0,
                isFuture: hour > currentHour,
                isCurrent: hour == currentHour
            )
        }
    }

    /// 存在已归入小时的今日数据且活跃小时数 ≤ 2 时，满足脉冲面板自动启用条件。
    static func shouldUsePulsePanel(activeHourPoints: [TrendPoint]) -> Bool {
        let activeCount = activeHourPoints.filter { $0.tokens > 0 }.count
        return activeCount > 0 && activeCount <= sparseHourThreshold
    }

    /// 较昨日同刻的整数百分比变化；昨日同刻无数据则返回 nil（不伪造 0% 或 +∞%）。
    static func yesterdayDeltaPercent(todayTokens: Int64, yesterdaySameTimeTokens: Int64?) -> Int? {
        guard let yesterday = yesterdaySameTimeTokens, yesterday > 0 else { return nil }
        let delta = Double(todayTokens - yesterday) / Double(yesterday) * 100
        return Int(delta.rounded())
    }

    /// 带正负号的百分比文本（如 "+23%"、"-18%"、"0%"）。
    static func signedPercentText(_ percent: Int) -> String {
        if percent > 0 { return "+\(percent)%" }
        return "\(percent)%"
    }

    /// 将 "HH:00" 转为 "HH:00–(HH+1):00" 区间标签。
    static func hourRangeLabel(_ bucket: String) -> String {
        guard bucket.count == 5, bucket.hasSuffix(":00"),
              let hour = Int(bucket.prefix(2)), (0..<24).contains(hour) else { return bucket }
        return String(format: "%02d:00–%02d:00", hour, (hour + 1) % 24)
    }

    /// 当前本地时刻标签（"HH:mm"）。
    static func currentTimeLabel(now: Date = Date(), calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

/// 坐标轴取整与刻度文字（纯函数，便于测试）。
enum TrendScale {
    /// 向上取到 4 等分后仍是整齐数字的上限。
    static func niceCeiling(_ value: Double) -> Double {
        guard value > 0, value.isFinite else { return 1 }
        let magnitude = pow(10, floor(log10(value)))
        let steps: [Double] = [1, 1.2, 1.6, 2, 2.4, 3.2, 4, 6, 8, 10]
        let normalized = value / magnitude
        let step = steps.first { $0 >= normalized - 1e-9 } ?? 10
        return step * magnitude
    }

    static func ticks(top: Double) -> [Double] {
        (0...4).map { top * Double($0) / 4 }
    }

    /// 轴上的 Token 刻度：中文开启「亿」时用 万 / 亿，其余用 K / M / B；去掉多余的 0。
    static func tokenLabel(_ value: Double, yi: Bool) -> String {
        func trimmed(_ x: Double) -> String {
            let text = String(format: "%.1f", x)
            return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
        }
        if value <= 0 { return "0" }
        if yi && !L10n.isEnglish {
            if value >= 1e8 { return trimmed(value / 1e8) + "亿" }
            if value >= 1e4 { return trimmed(value / 1e4) + "万" }
            return trimmed(value)
        }
        if value >= 1e9 { return trimmed(value / 1e9) + "B" }
        if value >= 1e6 { return trimmed(value / 1e6) + "M" }
        if value >= 1e3 { return trimmed(value / 1e3) + "K" }
        return trimmed(value)
    }

    static func costLabel(_ value: Double) -> String {
        value <= 0 ? "$0" : String(format: "$%g", value)
    }
}

struct TrendChart: View, Equatable {
    @ObservedObject private var language = LanguageManager.shared
    let points: [TrendPoint]
    /// 小时粒度（今天）x 标签保留 "HH:00"；天粒度裁成 "MM-dd"
    let isHourly: Bool
    let yi: Bool
    /// 「今天」24 小时固定槽的当前时刻标签（如 "00:12"）；非今天为 nil。
    var currentTimeLabel: String? = nil

    nonisolated static func == (lhs: TrendChart, rhs: TrendChart) -> Bool {
        lhs.points == rhs.points
            && lhs.isHourly == rhs.isHourly
            && lhs.yi == rhs.yi
            && lhs.currentTimeLabel == rhs.currentTimeLabel
    }

    @State private var hoverID: String?

    private struct Segment: Identifiable {
        let id: String
        let bucket: String
        let kind: TokenKind
        let value: Double
    }

    private var isFixedDayTimeline: Bool {
        isHourly && points.count == 24
    }

    private func label(_ bucket: String) -> String {
        isHourly ? bucket : String(bucket.suffix(5))
    }

    /// x 轴：固定 24 小时用整齐 4 小时刻度；其他 8 个桶以内全部标注，更多均分 6 个。
    private var axisBuckets: [String] {
        if isFixedDayTimeline {
            return ["00:00", "04:00", "08:00", "12:00", "16:00", "20:00", "23:00"]
        }
        let n = points.count
        guard n > 8 else { return points.map(\.id) }
        return (0..<6).map { points[$0 * (n - 1) / 5].id }
    }

    private var currentBoundaryID: String? {
        guard isFixedDayTimeline else { return nil }
        return points.first(where: \.isCurrent)?.id ?? points.last(where: { !$0.isFuture })?.id
    }

    var body: some View {
        let fixedDay = isFixedDayTimeline
        let elapsed = fixedDay ? points.filter { !$0.isFuture } : points
        let segSource = fixedDay ? elapsed.filter { $0.tokens > 0 } : points
        let segments: [Segment] = segSource.flatMap { point in
            TokenKind.allCases.map {
                Segment(id: "\(point.id)|\($0.rawValue)", bucket: point.id,
                        kind: $0, value: point.value($0))
            }
        }
        let top = TrendScale.niceCeiling(elapsed.map(\.tokens).max() ?? 0)
        let costTop = TrendScale.niceCeiling(elapsed.map(\.cost).max() ?? 0)
        let hasCost = elapsed.contains { $0.cost > 0 }
        let costPoints = fixedDay ? elapsed : points
        let costDotPoints = fixedDay
            ? elapsed.filter { $0.tokens > 0 }
            : (points.count <= 31 ? points : [])
        let shouldDrawCostLine = fixedDay ? costDotPoints.count > 1 : costPoints.count > 1
        let axisValues = axisBuckets
        let visibleAxisSet = Set(axisValues)
        let domain = points.map(\.id)
        let pointByID = Dictionary(points.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })

        Chart {
            ForEach(segments) { segment in
                BarMark(x: .value("bucket", segment.bucket),
                        y: .value("tokens", segment.value),
                        width: .ratio(fixedDay ? 0.66 : 0.62))
                    .foregroundStyle(segment.kind.color.opacity(
                        hoverID == nil || hoverID == segment.bucket ? 0.9 : 0.42))
            }
            if hasCost {
                if shouldDrawCostLine {
                    ForEach(costPoints) { point in
                        LineMark(x: .value("bucket", point.id),
                                 y: .value("cost", point.cost / costTop * top),
                                 series: .value("series", "cost"))
                            .foregroundStyle(Color.costSeries)
                            .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    }
                }
                ForEach(costDotPoints) { point in
                    PointMark(x: .value("bucket", point.id),
                              y: .value("cost", point.cost / costTop * top))
                        .foregroundStyle(Color.costSeries)
                        .symbolSize(hoverID == point.id ? 46 : (costDotPoints.count == 1 ? 34 : 18))
                }
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...top)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: axisValues) { value in
                if let bucket = value.as(String.self), visibleAxisSet.contains(bucket) {
                    AxisValueLabel {
                        Text(label(bucket)).font(.caption2)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: TrendScale.ticks(top: top)) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(TrendScale.tokenLabel(v, yi: yi)).font(.caption2)
                    }
                }
            }
            if hasCost {
                AxisMarks(position: .trailing, values: TrendScale.ticks(top: top)) { value in
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(TrendScale.costLabel(v / top * costTop))
                                .font(.caption2)
                                .foregroundStyle(Color.costSeries)
                        }
                    }
                }
            }
        }
        .chartBackground { proxy in
            if fixedDay {
                GeometryReader { geo in
                    dayTimelineBackdrop(proxy: proxy, geo: geo)
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    if fixedDay {
                        nowPillOverlay(proxy: proxy, geo: geo)
                            .allowsHitTesting(false)
                    }
                    TrendChartHoverOverlay(
                        proxy: proxy,
                        geo: geo,
                        pointByID: pointByID,
                        isHourly: isHourly,
                        yi: yi,
                        hoverID: $hoverID
                    )
                }
            }
        }
        .padding(.top, fixedDay ? 14 : 0)
        .frame(height: 220)
        // 桶是离散的小时 / 天：禁止隐式柱形/轴插值，切换「今天 ↔ 近 7 天」单帧直出不卡顿。
        .transaction { $0.animation = nil }
        .onChange(of: points) { _, _ in
            if hoverID != nil { hoverID = nil }
        }
    }

    // ------------------------------------------------------ 24h 辅助层 ----

    @ViewBuilder
    private func dayTimelineBackdrop(proxy: ChartProxy, geo: GeometryProxy) -> some View {
        if let plotAnchor = proxy.plotFrame {
            let frame = geo[plotAnchor]
            let boundaryX: CGFloat? = currentBoundaryID.flatMap { id in
                proxy.positionRange(forX: id).map { frame.origin.x + $0.upperBound }
            }
            ZStack(alignment: .topLeading) {
                // 未到来时段的极淡底色（位于当前小时槽右侧，不切割当前柱体）
                if let boundaryX, points.contains(where: \.isFuture), boundaryX < frame.maxX {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.025))
                        .frame(width: max(0, frame.maxX - boundaryX), height: frame.height)
                        .offset(x: boundaryX, y: frame.minY)
                }

                // 0 用量已过小时与未来小时的底部基线刻度
                ForEach(points) { point in
                    if point.tokens <= 0, let range = proxy.positionRange(forX: point.id) {
                        let slotW = max(2, (range.upperBound - range.lowerBound) * 0.66)
                        let midX = frame.origin.x + (range.lowerBound + range.upperBound) / 2
                        Capsule()
                            .fill(point.isFuture ? Color.primary.opacity(0.05) : Color.primary.opacity(0.09))
                            .frame(width: slotW, height: point.isFuture ? 2.5 : 1.5)
                            .offset(x: midX - slotW / 2, y: frame.maxY - (point.isFuture ? 2.5 : 1.5))
                    }
                }

                // 「此刻」竖向虚线
                if let boundaryX {
                    let clampedX = min(max(boundaryX, frame.minX + 1), frame.maxX - 1)
                    Path { path in
                        path.move(to: CGPoint(x: clampedX, y: frame.minY))
                        path.addLine(to: CGPoint(x: clampedX, y: frame.maxY))
                    }
                    .stroke(Color.brand.opacity(0.7),
                            style: StrokeStyle(lineWidth: 1.2, dash: [3, 2.5]))
                }
            }
        }
    }

    @ViewBuilder
    private func nowPillOverlay(proxy: ChartProxy, geo: GeometryProxy) -> some View {
        if let plotAnchor = proxy.plotFrame,
           let boundaryID = currentBoundaryID,
           let range = proxy.positionRange(forX: boundaryID),
           let timeText = currentTimeLabel {
            let frame = geo[plotAnchor]
            let labelText = L10n.text("此刻 \(timeText)")
            let pillWidth: CGFloat = max(56, CGFloat(labelText.count) * 7.5 + 14)
            let maxX = max(frame.minX, frame.maxX - pillWidth)
            let targetX = frame.origin.x + range.upperBound - pillWidth / 2
            let clampedX = min(max(targetX, frame.minX), maxX)
            Text(labelText)
                .font(.system(size: 9.5, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(Color.brand)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.brand.opacity(0.14), in: Capsule())
                .offset(x: clampedX, y: max(-14, frame.minY - 17))
        }
    }
}

/// 独立的悬停捕获与浮卡层：hoverLocation 只在此子视图内变化，绝不触发父级 Swift Charts 重建；
/// 窗口滚动期间直接屏蔽悬停更新，避免 120Hz 滚动帧中反复重算图表与浮卡。
private struct TrendChartHoverOverlay: View {
    let proxy: ChartProxy
    let geo: GeometryProxy
    let pointByID: [String: TrendPoint]
    let isHourly: Bool
    let yi: Bool
    @Binding var hoverID: String?

    @State private var hoverLocation: CGPoint = .zero
    @State private var tokenBox = HoverTokenBox()

    private func label(_ bucket: String) -> String {
        isHourly ? bucket : String(bucket.suffix(5))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard !ScrollActivity.shared.isScrolling else { return }
                        guard let frame = proxy.plotFrame.map({ geo[$0] }) else { return }
                        let nextID: String?
                        if let bucket = proxy.value(atX: location.x - frame.origin.x, as: String.self),
                           let pt = pointByID[bucket],
                           !pt.isFuture {
                            nextID = bucket
                        } else {
                            nextID = nil
                        }
                        if hoverID != nextID { hoverID = nextID }
                        if nextID != nil {
                            if abs(location.x - hoverLocation.x) >= 1 || abs(location.y - hoverLocation.y) >= 1 {
                                hoverLocation = location
                            }
                            tokenBox.setActive(true) {
                                if hoverID != nil { hoverID = nil }
                            }
                        } else {
                            tokenBox.unregister()
                        }
                    case .ended:
                        tokenBox.unregister()
                        if hoverID != nil { hoverID = nil }
                    }
                }
                .onDisappear {
                    tokenBox.unregister()
                }
            if let hoverID, let point = pointByID[hoverID], !point.isFuture {
                tooltip(for: point, in: geo.size)
            }
        }
    }

    private func tooltip(for point: TrendPoint, in size: CGSize) -> some View {
        let cardWidth: CGFloat = 176
        let cardHeight: CGFloat = 138
        let x = min(max(hoverLocation.x + 14, 4), max(size.width - cardWidth - 4, 4))
        let y = min(max(hoverLocation.y - cardHeight - 10, 4),
                    max(size.height - cardHeight - 4, 4))
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(isHourly ? TodayTrendBuilder.hourRangeLabel(point.id) : label(point.id))
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 8)
                Text(UIFormat.compact(Int64(point.tokens), yi: yi))
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
            Divider()
            ForEach(TokenKind.allCases) { kind in
                tooltipRow(kind.title, color: kind.color,
                           value: UIFormat.compact(Int64(point.value(kind)), yi: yi))
            }
            tooltipRow(L10n.text("成本"), color: .costSeries,
                       value: UIFormat.costPrecise(point.cost))
        }
        .padding(9)
        .frame(width: cardWidth, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.cardBorder))
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        .offset(x: x, y: y)
        .allowsHitTesting(false)
    }

    private func tooltipRow(_ name: String, color: Color, value: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(name).font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.caption2.monospacedDigit())
        }
    }
}
