//
//  UsageChartsView.swift
//  TokenTrackerApp
//
//  用量页可视化组件与纯聚合逻辑：
//  - UsageDonutCard：项目 / 模型占比环形图（Tokens / 费用切换，悬停高亮 + 点击下钻）
//  - TokenMixBarCard：Top 项目 / 模型四类 Token 堆叠横条图（悬停明细 + 点击下钻）
//  - CacheHitComparisonCard：模型输入侧缓存命中率对比图
//  - SessionSummaryDock：会话页底部可收起的分布可视化（Agent 构成 + 高消耗会话对比）
//

import Charts
import SwiftUI
import TokenTrackerCore

// ------------------------------------------------------------------ 数据模型 ----

enum UsageChartMetric: String, CaseIterable, Identifiable {
    case tokens
    case cost

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tokens: "Tokens"
        case .cost: L10n.text("费用")
        }
    }
}

struct UsageDonutSlice: Identifiable, Equatable {
    let id: String
    let label: String
    let subtitle: String?
    let value: Double
    let share: Double
    let tokens: Int64
    let costText: String
    /// 分类索引（0...5 为主题色板，-1 为中性灰，用于「其他」或「未归属」）。
    let colorIndex: Int
    let isOther: Bool
    /// 点击时的业务目标 ID（例如项目 ID 或模型名）；nil 表示不可点击（如「其他」）。
    let targetID: String?
}

struct UsageDonutData: Equatable {
    let slices: [UsageDonutSlice]
    let totalValue: Double
    let totalTokens: Int64
    let totalCost: Double
    let itemCount: Int
    let unpricedItemCount: Int
}

struct TokenMixItem: Identifiable, Equatable {
    let id: String
    let label: String
    let subtitle: String?
    let input: Int64
    let output: Int64
    let cacheRead: Int64
    let cacheWrite: Int64
    let costText: String
    let targetID: String?

    var tokens: Int64 { input + output + cacheRead + cacheWrite }
    var inputSideTokens: Int64 { input + cacheRead + cacheWrite }
    var cacheHitRate: Double? {
        guard inputSideTokens > 0 else { return nil }
        return Double(cacheRead) / Double(inputSideTokens) * 100
    }

    func value(for kind: TokenKind) -> Int64 {
        switch kind {
        case .cacheRead: cacheRead
        case .input: input
        case .cacheWrite: cacheWrite
        case .output: output
        }
    }
}

struct CacheHitItem: Identifiable, Equatable {
    let id: String
    let label: String
    let subtitle: String?
    let tool: String
    let hitRate: Double
    let cacheRead: Int64
    let inputSideTokens: Int64
    let targetID: String?
}

struct SessionAgentSlice: Identifiable, Equatable {
    let tool: String
    let sessions: Int
    let tokens: Int64
    let share: Double
    var id: String { tool }
}

// ------------------------------------------------------------------ 纯聚合逻辑 ----

enum UsageChartBuilder {
    /// 项目占比环形图数据。费用口径严格排除全未计价项目，不伪造 $0 扇区。
    static func projectDonut(projects: [ProjectSummary],
                             metric: UsageChartMetric,
                             maxSlices: Int = 5) -> UsageDonutData {
        let nonEmpty = projects.filter { $0.totals.tokens > 0 }
        let unpricedCount = nonEmpty.filter {
            $0.totals.records > 0 && $0.totals.unpriced == $0.totals.records
        }.count

        struct Entry {
            let id: String
            let label: String
            let subtitle: String
            let value: Double
            let tokens: Int64
            let cost: Double
            let costText: String
            let isUnassigned: Bool
        }

        let entries: [Entry]
        switch metric {
        case .tokens:
            entries = nonEmpty
                .sorted { $0.totals.tokens > $1.totals.tokens }
                .map { project in
                    Entry(id: project.id,
                          label: projectDisplayName(project),
                          subtitle: L10n.text("\(project.totals.sessions) 个会话"),
                          value: Double(project.totals.tokens),
                          tokens: project.totals.tokens,
                          cost: project.totals.cost,
                          costText: UIFormat.costLabel(project.totals),
                          isUnassigned: project.id == "unassigned")
                }
        case .cost:
            entries = nonEmpty
                .filter { !($0.totals.records > 0 && $0.totals.unpriced == $0.totals.records) && $0.totals.cost > 0 }
                .sorted { $0.totals.cost > $1.totals.cost }
                .map { project in
                    Entry(id: project.id,
                          label: projectDisplayName(project),
                          subtitle: L10n.text("\(project.totals.sessions) 个会话"),
                          value: project.totals.cost,
                          tokens: project.totals.tokens,
                          cost: project.totals.cost,
                          costText: UIFormat.costLabel(project.totals),
                          isUnassigned: project.id == "unassigned")
                }
        }

        return buildDonutData(
            entries: entries.map { ($0.id, $0.label, $0.subtitle as String?, $0.value, $0.tokens, $0.cost, $0.costText, $0.isUnassigned, $0.id) },
            totalItemCount: metric == .tokens ? nonEmpty.count : entries.count,
            unpricedItemCount: unpricedCount,
            maxSlices: maxSlices
        )
    }

    /// 模型占比环形图数据。费用口径严格排除全未计价模型。
    static func modelDonut(rows: [UsageStore.ModelRow],
                           metric: UsageChartMetric,
                           maxSlices: Int = 5) -> UsageDonutData {
        let nonEmpty = rows.filter { $0.stats.tokens > 0 }
        let unpricedCount = nonEmpty.filter {
            $0.stats.events > 0 && $0.stats.unpriced == $0.stats.events
        }.count

        struct Entry {
            let id: String
            let label: String
            let subtitle: String
            let value: Double
            let tokens: Int64
            let cost: Double
            let costText: String
            let modelKey: String
        }

        let entries: [Entry]
        switch metric {
        case .tokens:
            entries = nonEmpty
                .sorted { $0.stats.tokens > $1.stats.tokens }
                .map { row in
                    Entry(id: "\(row.tool)|\(row.model)",
                          label: row.model.isEmpty ? L10n.text("（未知模型）") : row.model,
                          subtitle: toolDisplayName(row.tool),
                          value: Double(row.stats.tokens),
                          tokens: row.stats.tokens,
                          cost: row.stats.cost,
                          costText: UIFormat.sessionCost(row.stats),
                          modelKey: row.model)
                }
        case .cost:
            entries = nonEmpty
                .filter { !($0.stats.events > 0 && $0.stats.unpriced == $0.stats.events) && $0.stats.cost > 0 }
                .sorted { $0.stats.cost > $1.stats.cost }
                .map { row in
                    Entry(id: "\(row.tool)|\(row.model)",
                          label: row.model.isEmpty ? L10n.text("（未知模型）") : row.model,
                          subtitle: toolDisplayName(row.tool),
                          value: row.stats.cost,
                          tokens: row.stats.tokens,
                          cost: row.stats.cost,
                          costText: UIFormat.sessionCost(row.stats),
                          modelKey: row.model)
                }
        }

        return buildDonutData(
            entries: entries.map { ($0.id, $0.label, $0.subtitle as String?, $0.value, $0.tokens, $0.cost, $0.costText, false, $0.modelKey) },
            totalItemCount: metric == .tokens ? nonEmpty.count : entries.count,
            unpricedItemCount: unpricedCount,
            maxSlices: maxSlices
        )
    }

    private static func buildDonutData(
        entries: [(id: String, label: String, subtitle: String?, value: Double, tokens: Int64, cost: Double, costText: String, neutral: Bool, targetID: String)],
        totalItemCount: Int,
        unpricedItemCount: Int,
        maxSlices: Int
    ) -> UsageDonutData {
        let totalValue = entries.reduce(0.0) { $0 + $1.value }
        let totalTokens = entries.reduce(Int64(0)) { $0 + $1.tokens }
        let totalCost = entries.reduce(0.0) { $0 + $1.cost }
        guard totalValue > 0, !entries.isEmpty else {
            return UsageDonutData(slices: [], totalValue: 0, totalTokens: totalTokens,
                                  totalCost: totalCost, itemCount: 0,
                                  unpricedItemCount: unpricedItemCount)
        }

        // 只剩 1 项时不合并成「其他」，直接完整展示（最多 maxSlices + 1 项）。
        let shouldRollOther = entries.count > maxSlices + 1
        let head = shouldRollOther ? Array(entries.prefix(maxSlices)) : entries
        let tail = shouldRollOther ? Array(entries.dropFirst(maxSlices)) : []

        var paletteCursor = 0
        var slices: [UsageDonutSlice] = head.map { item in
            let colorIdx: Int
            if item.neutral {
                colorIdx = -1
            } else {
                colorIdx = paletteCursor
                paletteCursor += 1
            }
            return UsageDonutSlice(
                id: item.id,
                label: item.label,
                subtitle: item.subtitle,
                value: item.value,
                share: item.value / totalValue,
                tokens: item.tokens,
                costText: item.costText,
                colorIndex: colorIdx,
                isOther: false,
                targetID: item.targetID
            )
        }

        if !tail.isEmpty {
            let otherValue = tail.reduce(0.0) { $0 + $1.value }
            let otherTokens = tail.reduce(Int64(0)) { $0 + $1.tokens }
            let otherCost = tail.reduce(0.0) { $0 + $1.cost }
            let allTailUnpriced = tail.allSatisfy { $0.costText == L10n.text("未计价") || $0.costText == "—" }
            slices.append(UsageDonutSlice(
                id: "__other__",
                label: L10n.text("其他 (\(tail.count))"),
                subtitle: nil,
                value: otherValue,
                share: otherValue / totalValue,
                tokens: otherTokens,
                costText: allTailUnpriced ? L10n.text("未计价") : UIFormat.cost(otherCost),
                colorIndex: -1,
                isOther: true,
                targetID: nil
            ))
        }

        return UsageDonutData(slices: slices, totalValue: totalValue, totalTokens: totalTokens,
                              totalCost: totalCost, itemCount: totalItemCount,
                              unpricedItemCount: unpricedItemCount)
    }

    static func projectMix(projects: [ProjectSummary], limit: Int = 6) -> [TokenMixItem] {
        projects
            .filter { $0.totals.tokens > 0 }
            .sorted { $0.totals.tokens > $1.totals.tokens }
            .prefix(limit)
            .map { project in
                TokenMixItem(
                    id: project.id,
                    label: projectDisplayName(project),
                    subtitle: L10n.text("\(project.totals.sessions) 个会话"),
                    input: project.totals.input,
                    output: project.totals.output,
                    cacheRead: project.totals.cacheRead,
                    cacheWrite: project.totals.cacheWrite,
                    costText: UIFormat.costLabel(project.totals),
                    targetID: project.id
                )
            }
    }

    static func modelMix(rows: [UsageStore.ModelRow], limit: Int = 6) -> [TokenMixItem] {
        rows
            .filter { $0.stats.tokens > 0 }
            .sorted { $0.stats.tokens > $1.stats.tokens }
            .prefix(limit)
            .map { row in
                TokenMixItem(
                    id: "\(row.tool)|\(row.model)",
                    label: row.model.isEmpty ? L10n.text("（未知模型）") : row.model,
                    subtitle: toolDisplayName(row.tool),
                    input: row.stats.input,
                    output: row.stats.output,
                    cacheRead: row.stats.cacheRead,
                    cacheWrite: row.stats.cacheWrite,
                    costText: UIFormat.sessionCost(row.stats),
                    targetID: row.model
                )
            }
    }

    /// 仅包含存在输入侧 Token 的模型；缺失输入侧的模型不伪造 0% 命中率。
    static func cacheHitItems(rows: [UsageStore.ModelRow], limit: Int = 6) -> [CacheHitItem] {
        rows
            .filter { $0.stats.inputSideTokens > 0 }
            .sorted { $0.stats.tokens > $1.stats.tokens }
            .prefix(limit)
            .compactMap { row -> CacheHitItem? in
                guard let rate = row.stats.cacheHitRate else { return nil }
                return CacheHitItem(
                    id: "\(row.tool)|\(row.model)",
                    label: row.model.isEmpty ? L10n.text("（未知模型）") : row.model,
                    subtitle: toolDisplayName(row.tool),
                    tool: row.tool,
                    hitRate: rate,
                    cacheRead: row.stats.cacheRead,
                    inputSideTokens: row.stats.inputSideTokens,
                    targetID: row.model
                )
            }
            .sorted { $0.hitRate > $1.hitRate }
    }

    /// 按顺时针 12 点起始的极坐标命中测试（匹配 Swift Charts SectorMark）。
    static func sliceID(at point: CGPoint, in size: CGSize,
                        slices: [UsageDonutSlice],
                        innerRatio: CGFloat = 0.56) -> String? {
        guard !slices.isEmpty, size.width > 0, size.height > 0 else { return nil }
        let radius = min(size.width, size.height) / 2
        let dx = point.x - size.width / 2
        let dy = point.y - size.height / 2
        let dist = hypot(dx, dy)
        guard dist >= radius * innerRatio, dist <= radius else { return nil }

        let total = slices.reduce(0.0) { $0 + max($1.value, 0) }
        guard total > 0 else { return nil }

        var angle = atan2(dy, dx) + .pi / 2
        if angle < 0 { angle += 2 * .pi }
        let fraction = Double(angle / (2 * .pi))

        var cursor = 0.0
        for slice in slices {
            let next = cursor + max(slice.value, 0) / total
            if fraction < next || slice.id == slices.last?.id {
                return slice.id
            }
            cursor = next
        }
        return slices.last?.id
    }

    /// 会话页按 Agent 汇总占比。
    static func sessionAgentSummary(rows: [SessionRowModel]) -> [SessionAgentSlice] {
        var counts: [String: (sessions: Int, tokens: Int64)] = [:]
        var totalTokens: Int64 = 0
        for row in rows {
            let cur = counts[row.tool] ?? (0, 0)
            counts[row.tool] = (cur.sessions + 1, cur.tokens + row.tokens)
            totalTokens += row.tokens
        }
        let totalSessions = max(rows.count, 1)
        return counts.map { tool, agg in
            let share = totalTokens > 0
                ? Double(agg.tokens) / Double(totalTokens)
                : Double(agg.sessions) / Double(totalSessions)
            return SessionAgentSlice(tool: tool, sessions: agg.sessions, tokens: agg.tokens, share: share)
        }
        .sorted { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.sessions > $1.sessions }
    }

    /// 会话页汇总指标，严格区分未计价与零值。
    static func sessionTotals(rows: [SessionRowModel]) -> (tokens: Int64, costText: String) {
        let tokens = rows.reduce(Int64(0)) { $0 + $1.tokens }
        let events = rows.reduce(Int64(0)) { $0 + $1.stats.events }
        let unpriced = rows.reduce(Int64(0)) { $0 + $1.stats.unpriced }
        let cost = rows.reduce(0.0) { $0 + $1.cost }
        let costText: String
        if events == 0 {
            costText = "—"
        } else if unpriced == events {
            costText = L10n.text("未计价")
        } else {
            costText = UIFormat.cost(cost)
        }
        return (tokens, costText)
    }
}

// ------------------------------------------------------------------ 通用配色与切换 ----

private enum DonutPalette {
    static let colors: [Color] = [.brand, .blue, .teal, .orange, .pink, .mint]

    static func color(for slice: UsageDonutSlice) -> Color {
        guard slice.colorIndex >= 0 else { return Color.secondary.opacity(0.45) }
        return colors[slice.colorIndex % colors.count]
    }
}

/// 卡片标题栏用的紧凑双项切换（Tokens / 费用），沿用 PageControl 质感但高度更轻巧。
struct CompactMetricToggle: View {
    @Binding var metric: UsageChartMetric

    var body: some View {
        HStack(spacing: 2) {
            ForEach(UsageChartMetric.allCases) { item in
                let selected = metric == item
                Button {
                    guard metric != item else { return }
                    metric = item
                } label: {
                    Text(item.title)
                        .font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(PageControl.pillSurface)
                                    .overlay(Capsule().strokeBorder(PageControl.pillBorder, lineWidth: 0.5))
                                    .shadow(color: PageControl.pillShadow, radius: 1, y: 0.5)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(PageControl.trackFill, in: Capsule())
        .overlay(Capsule().strokeBorder(PageControl.trackBorder, lineWidth: 0.5))
        .fixedSize()
    }
}

// ------------------------------------------------------------------ 1. 环形占比卡 ----

struct UsageDonutCard: View {
    @ObservedObject private var language = LanguageManager.shared
    let title: String
    let centerSubtitle: String
    let data: UsageDonutData
    @Binding var metric: UsageChartMetric
    let yi: Bool
    var onSelect: ((String) -> Void)? = nil

    @State private var hoveredID: String?
    @State private var hoverToken = HoverTokenBox()

    private var hoveredSlice: UsageDonutSlice? {
        guard let hoveredID else { return nil }
        return data.slices.first { $0.id == hoveredID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(title: title) {
                CompactMetricToggle(metric: $metric)
            }

            if data.slices.isEmpty {
                emptyMetricState
            } else {
                AdaptiveLeadingFixedLayout(
                    leadingWidth: 162,
                    minTrailingWidth: 180,
                    spacing: 18,
                    verticalSpacing: 14,
                    horizontalAlignment: .center,
                    stackCenterLeading: true
                ) {
                    donutCanvas
                    legendList.frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if metric == .cost, data.unpricedItemCount > 0, !data.slices.isEmpty {
                Text(L10n.text("已排除 \(data.unpricedItemCount) 项未计价数据"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
        .onChange(of: data) { _, _ in
            hoverToken.unregister()
            if hoveredID != nil { hoveredID = nil }
        }
        .onDisappear { hoverToken.unregister() }
    }

    private var emptyMetricState: some View {
        VStack(spacing: 6) {
            Image(systemName: metric == .cost ? "dollarsign.circle" : "chart.pie")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(metric == .cost ? L10n.text("当前范围暂无已计价数据") : L10n.text("暂无数据"))
                .font(.callout)
                .foregroundStyle(.secondary)
            if metric == .cost, data.unpricedItemCount > 0 {
                Text(L10n.text("共 \(data.unpricedItemCount) 项未计价"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 162)
    }

    private var donutCanvas: some View {
        Chart(data.slices) { slice in
            SectorMark(
                angle: .value("value", slice.value),
                innerRadius: .ratio(0.62),
                outerRadius: hoveredID == slice.id ? .ratio(1.0) : .ratio(0.93),
                angularInset: data.slices.count > 1 ? 1.8 : 0
            )
            .cornerRadius(4)
            .foregroundStyle(DonutPalette.color(for: slice).opacity(
                hoveredID == nil || hoveredID == slice.id ? 0.92 : 0.36
            ))
        }
        .chartLegend(.hidden)
        .frame(width: 162, height: 162)
        .overlay { centerReadout.allowsHitTesting(false) }
        .overlay {
            GeometryReader { geo in
                Color.clear
                    .contentShape(Circle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard !ScrollActivity.shared.isScrolling else { return }
                            let next = UsageChartBuilder.sliceID(
                                at: location, in: geo.size, slices: data.slices)
                            if hoveredID != next { hoveredID = next }
                            hoverToken.setActive(next != nil) {
                                if hoveredID != nil { hoveredID = nil }
                            }
                        case .ended:
                            hoverToken.unregister()
                            if hoveredID != nil { hoveredID = nil }
                        }
                    }
                    .onTapGesture {
                        if let target = hoveredSlice?.targetID {
                            onSelect?(target)
                        }
                    }
            }
        }
        .transaction { $0.animation = nil }
    }

    private var centerReadout: some View {
        VStack(spacing: 2) {
            if let slice = hoveredSlice {
                Text(slice.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 86)
                Text(formatShare(slice.share))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(metric == .tokens ? UIFormat.compact(slice.tokens, yi: yi) : slice.costText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(L10n.text("合计"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(metric == .tokens
                     ? UIFormat.compact(data.totalTokens, yi: yi)
                     : UIFormat.cost(data.totalCost))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .frame(maxWidth: 90)
                Text(centerSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private var legendList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(data.slices) { slice in
                let isHovered = hoveredID == slice.id
                let clickable = slice.targetID != nil && onSelect != nil
                Button {
                    if let target = slice.targetID { onSelect?(target) }
                } label: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(DonutPalette.color(for: slice))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(slice.label)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let subtitle = slice.subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 6)
                        Text(formatShare(slice.share))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(metric == .tokens ? UIFormat.compact(slice.tokens, yi: yi) : slice.costText)
                            .font(.callout.monospacedDigit().weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .frame(minWidth: 52, alignment: .trailing)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isHovered ? Color.primary.opacity(0.06) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!clickable)
                .onHover { active in
                    if active {
                        guard !ScrollActivity.shared.isScrolling else { return }
                        if hoveredID != slice.id { hoveredID = slice.id }
                        hoverToken.setActive(true) {
                            if hoveredID != nil { hoveredID = nil }
                        }
                    } else if hoveredID == slice.id {
                        hoverToken.unregister()
                        hoveredID = nil
                    }
                }
                .help("\(slice.label) · \(UIFormat.compact(slice.tokens, yi: yi)) · \(slice.costText)")
            }
        }
    }

    private func formatShare(_ share: Double) -> String {
        let pct = share * 100
        if pct > 0 && pct < 0.1 { return "<0.1%" }
        return String(format: "%.1f%%", pct)
    }
}

// ------------------------------------------------------------------ 2. Token 四类堆叠横条 ----

struct TokenMixBarCard: View {
    @ObservedObject private var language = LanguageManager.shared
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let items: [TokenMixItem]
    let totalCount: Int
    let yi: Bool
    var onSelect: ((String) -> Void)? = nil

    @State private var hoveredID: String?

    private struct BarSegment: Identifiable {
        let id: String
        let itemID: String
        let kind: TokenKind
        let value: Double
    }

    private var segments: [BarSegment] {
        items.flatMap { item in
            TokenKind.allCases.map { kind in
                BarSegment(id: "\(item.id)|\(kind.rawValue)",
                           itemID: item.id,
                           kind: kind,
                           value: Double(item.value(for: kind)))
            }
        }
    }

    private var xTop: Double {
        TrendScale.niceCeiling(Double(items.map(\.tokens).max() ?? 0))
    }

    private var chartHeight: CGFloat {
        max(150, CGFloat(items.count) * 30 + 28)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(title: title) {
                if totalCount > items.count {
                    Text(L10n.text("前 \(items.count) / 共 \(totalCount)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                ForEach(TokenKind.allCases) { kind in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(kind.color)
                            .frame(width: 8, height: 8)
                        Text(kind.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            if items.isEmpty {
                Text(L10n.text("暂无数据"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                let top = xTop
                let domain = items.map(\.id)
                let itemMap = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
                Chart(segments) { seg in
                    BarMark(
                        x: .value("tokens", seg.value),
                        y: .value("item", seg.itemID),
                        height: .fixed(15)
                    )
                    .foregroundStyle(seg.kind.color.opacity(
                        hoveredID == nil || hoveredID == seg.itemID ? 0.90 : 0.36
                    ))
                }
                .chartXScale(domain: 0...top)
                .chartYScale(domain: domain)
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks(values: TrendScale.ticks(top: top)) { value in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(TrendScale.tokenLabel(v, yi: yi))
                                    .font(.caption2.monospacedDigit())
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(preset: .aligned, position: .leading, values: domain) { value in
                        AxisValueLabel {
                            if let id = value.as(String.self), let item = itemMap[id] {
                                Text(item.label)
                                    .font(.caption)
                                    .foregroundStyle(hoveredID == id ? Color.primary : Color.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(width: 100, alignment: .trailing)
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        TokenMixHoverOverlay(
                            proxy: proxy,
                            geo: geo,
                            itemMap: itemMap,
                            yi: yi,
                            hoveredID: $hoveredID,
                            onSelect: onSelect
                        )
                    }
                }
                .frame(height: chartHeight)
                .id(colorScheme)
                .transaction { $0.animation = nil }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
        .onChange(of: items) { _, _ in
            if hoveredID != nil { hoveredID = nil }
        }
    }
}

/// 独立悬停与浮卡层：hoverLocation 只在此子视图内更新，避免鼠标微移或滚动时 120Hz 重建 Swift Charts。
private struct TokenMixHoverOverlay: View {
    let proxy: ChartProxy
    let geo: GeometryProxy
    let itemMap: [String: TokenMixItem]
    let yi: Bool
    @Binding var hoveredID: String?
    let onSelect: ((String) -> Void)?

    @State private var hoverLocation: CGPoint = .zero
    @State private var tokenBox = HoverTokenBox()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard !ScrollActivity.shared.isScrolling else { return }
                        guard let frame = proxy.plotFrame.map({ geo[$0] }) else { return }
                        let next = proxy.value(atY: location.y - frame.origin.y, as: String.self)
                        if hoveredID != next { hoveredID = next }
                        if next != nil {
                            if abs(location.x - hoverLocation.x) >= 1 || abs(location.y - hoverLocation.y) >= 1 {
                                hoverLocation = location
                            }
                            tokenBox.setActive(true) {
                                if hoveredID != nil { hoveredID = nil }
                            }
                        } else {
                            tokenBox.unregister()
                        }
                    case .ended:
                        tokenBox.unregister()
                        if hoveredID != nil { hoveredID = nil }
                    }
                }
                .onTapGesture {
                    if let hoveredID, let target = itemMap[hoveredID]?.targetID {
                        onSelect?(target)
                    }
                }
                .onDisappear { tokenBox.unregister() }
            if let hoveredID, let item = itemMap[hoveredID] {
                tooltip(for: item, in: geo.size)
            }
        }
    }

    private func tooltip(for item: TokenMixItem, in size: CGSize) -> some View {
        let cardWidth: CGFloat = 196
        let cardHeight: CGFloat = 152
        let x = min(max(hoverLocation.x + 14, 4), max(size.width - cardWidth - 4, 4))
        let y = min(max(hoverLocation.y - cardHeight / 2, 4), max(size.height - cardHeight - 4, 4))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(item.label)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(UIFormat.compact(item.tokens, yi: yi))
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
            if let subtitle = item.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Divider()
            ForEach(TokenKind.allCases) { kind in
                HStack(spacing: 5) {
                    Circle().fill(kind.color).frame(width: 6, height: 6)
                    Text(kind.title).font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text(UIFormat.compact(item.value(for: kind), yi: yi))
                        .font(.caption2.monospacedDigit())
                }
            }
            Divider()
            HStack {
                Text(L10n.text("缓存命中率") + " " + UIFormat.percent(item.cacheHitRate))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(item.costText)
                    .font(.caption2.monospacedDigit().weight(.medium))
            }
        }
        .padding(9)
        .frame(width: cardWidth, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.cardBorder))
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        .offset(x: x, y: y)
        .allowsHitTesting(false)
    }
}

// ------------------------------------------------------------------ 3. 缓存命中率对比 ----

struct CacheHitComparisonCard: View {
    @ObservedObject private var language = LanguageManager.shared
    @Environment(\.colorScheme) private var colorScheme
    let items: [CacheHitItem]
    let yi: Bool
    var onSelect: ((String) -> Void)? = nil

    @State private var hoveredID: String?

    private var chartHeight: CGFloat {
        max(120, CGFloat(items.count) * 28 + 24)
    }

    var body: some View {
        let domain = items.map(\.id)
        let itemMap = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(title: L10n.text("缓存命中率对比")) {
                Text(L10n.text("输入侧缓存读取占比"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Chart(items) { item in
                BarMark(
                    x: .value("rate", item.hitRate),
                    y: .value("model", item.id),
                    height: .fixed(13)
                )
                .cornerRadius(4)
                .foregroundStyle(toolColor(item.tool).opacity(
                    hoveredID == nil || hoveredID == item.id ? 0.88 : 0.36
                ))
                .annotation(position: .trailing, alignment: .leading, spacing: 6) {
                    Text(String(format: "%.1f%%", item.hitRate))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .chartXScale(domain: 0...114)
            .chartYScale(domain: domain)
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                    AxisValueLabel {
                        if let pct = value.as(Int.self) {
                            Text("\(pct)%").font(.caption2.monospacedDigit())
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(preset: .aligned, position: .leading, values: domain) { value in
                    AxisValueLabel {
                        if let id = value.as(String.self), let item = itemMap[id] {
                            HStack(spacing: 5) {
                                Spacer(minLength: 0)
                                Circle().fill(toolColor(item.tool)).frame(width: 6, height: 6)
                                Text(item.label)
                                    .font(.caption)
                                    .foregroundStyle(hoveredID == id ? Color.primary : Color.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .frame(width: 148, alignment: .trailing)
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    CacheHitHoverOverlay(
                        proxy: proxy,
                        geo: geo,
                        itemMap: itemMap,
                        yi: yi,
                        hoveredID: $hoveredID,
                        onSelect: onSelect
                    )
                }
            }
            .frame(height: chartHeight)
            .id(colorScheme)
            .transaction { $0.animation = nil }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .onChange(of: items) { _, _ in
            if hoveredID != nil { hoveredID = nil }
        }
    }
}

private struct CacheHitHoverOverlay: View {
    let proxy: ChartProxy
    let geo: GeometryProxy
    let itemMap: [String: CacheHitItem]
    let yi: Bool
    @Binding var hoveredID: String?
    let onSelect: ((String) -> Void)?

    @State private var hoverLocation: CGPoint = .zero
    @State private var tokenBox = HoverTokenBox()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard !ScrollActivity.shared.isScrolling else { return }
                        guard let frame = proxy.plotFrame.map({ geo[$0] }) else { return }
                        let next = proxy.value(atY: location.y - frame.origin.y, as: String.self)
                        if hoveredID != next { hoveredID = next }
                        if next != nil {
                            if abs(location.x - hoverLocation.x) >= 1 || abs(location.y - hoverLocation.y) >= 1 {
                                hoverLocation = location
                            }
                            tokenBox.setActive(true) {
                                if hoveredID != nil { hoveredID = nil }
                            }
                        } else {
                            tokenBox.unregister()
                        }
                    case .ended:
                        tokenBox.unregister()
                        if hoveredID != nil { hoveredID = nil }
                    }
                }
                .onTapGesture {
                    if let hoveredID, let target = itemMap[hoveredID]?.targetID {
                        onSelect?(target)
                    }
                }
                .onDisappear { tokenBox.unregister() }
            if let hoveredID, let item = itemMap[hoveredID] {
                cacheTooltip(for: item, in: geo.size)
            }
        }
    }

    private func cacheTooltip(for item: CacheHitItem, in size: CGSize) -> some View {
        let cardWidth: CGFloat = 200
        let cardHeight: CGFloat = 86
        let x = min(max(hoverLocation.x + 14, 4), max(size.width - cardWidth - 4, 4))
        let y = min(max(hoverLocation.y - cardHeight / 2, 4), max(size.height - cardHeight - 4, 4))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(toolColor(item.tool)).frame(width: 6, height: 6)
                Text(item.label)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(String(format: "%.1f%%", item.hitRate))
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
            Divider()
            HStack {
                Text(L10n.text("缓存命中"))
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text(UIFormat.compact(item.cacheRead, yi: yi))
                    .font(.caption2.monospacedDigit())
            }
            HStack {
                Text(L10n.text("输入侧总计"))
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text(UIFormat.compact(item.inputSideTokens, yi: yi))
                    .font(.caption2.monospacedDigit())
            }
        }
        .padding(9)
        .frame(width: cardWidth, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.cardBorder))
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        .offset(x: x, y: y)
        .allowsHitTesting(false)
    }
}

// ------------------------------------------------------------------ 4. 会话底部分布面板 ----

struct SessionSummaryDock: View {
    @ObservedObject private var language = LanguageManager.shared
    @Environment(\.colorScheme) private var colorScheme
    let rows: [SessionRowModel]
    let yi: Bool
    let onSelectSession: (String) -> Void

    @AppStorage("tt.sessions.summaryCollapsed") private var collapsed = false
    @State private var hoveredSessionID: String?
    @State private var hoverToken = HoverTokenBox()

    var body: some View {
        let totals = UsageChartBuilder.sessionTotals(rows: rows)

        VStack(alignment: .leading, spacing: collapsed ? 0 : 12) {
            HStack(spacing: 8) {
                Text(L10n.text("会话分布"))
                    .font(.subheadline.weight(.semibold))
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(L10n.text("共 \(rows.count) 个会话"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("\(UIFormat.compact(totals.tokens, yi: yi)) Tokens")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(totals.costText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    collapsed.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text(collapsed ? L10n.text("展开图表") : L10n.text("收起"))
                        Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if !collapsed {
                let agents = UsageChartBuilder.sessionAgentSummary(rows: rows)
                let topSessions = Array(rows.filter { $0.tokens > 0 }
                    .sorted { $0.tokens > $1.tokens }
                    .prefix(4))
                AdaptiveDividedPairLayout(
                    minFirstWidth: 260,
                    minSecondWidth: 320,
                    horizontalSpacing: 20,
                    verticalSpacing: 14
                ) {
                    agentShareColumn(agents: agents)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Divider().frame(height: 112)
                    topSessionsColumn(topSessions: topSessions)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: collapsed ? 10 : 14)
        .onDisappear { hoverToken.unregister() }
    }

    private func agentShareColumn(agents: [SessionAgentSlice]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("Agent 分布"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            SegmentedBar(
                segments: agents.map {
                    SegmentedBarSegment(value: $0.share, color: toolColor($0.tool), minWidth: 4)
                },
                height: 8
            )

            VStack(alignment: .leading, spacing: 5) {
                ForEach(agents.prefix(4)) { item in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(toolColor(item.tool))
                            .frame(width: 7, height: 7)
                        Text(toolDisplayName(item.tool))
                            .font(.caption)
                            .lineLimit(1)
                        Text(L10n.text("\(item.sessions) 个会话"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(String(format: "%.1f%%", item.share * 100))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(UIFormat.compact(item.tokens, yi: yi))
                            .font(.caption.monospacedDigit().weight(.medium))
                            .frame(minWidth: 48, alignment: .trailing)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func topSessionsColumn(topSessions: [SessionRowModel]) -> some View {
        let topVal = TrendScale.niceCeiling(Double(topSessions.map(\.tokens).max() ?? 0))
        let domain = topSessions.map(\.id)
        let rowMap = Dictionary(uniqueKeysWithValues: topSessions.map { ($0.id, $0) })
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.text("高消耗会话"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(L10n.text("点击柱条选中会话"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if topSessions.isEmpty {
                Text(L10n.text("暂无数据"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 84)
            } else {
                Chart(topSessions) { row in
                    BarMark(
                        x: .value("tokens", Double(row.tokens)),
                        y: .value("session", row.id),
                        height: .fixed(12)
                    )
                    .cornerRadius(3)
                    .foregroundStyle(toolColor(row.tool).opacity(
                        hoveredSessionID == nil || hoveredSessionID == row.id ? 0.88 : 0.36
                    ))
                    .annotation(position: .trailing, alignment: .leading, spacing: 5) {
                        Text(UIFormat.compact(row.tokens, yi: yi))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .chartXScale(domain: 0...(topVal * 1.18))
                .chartYScale(domain: domain)
                .chartLegend(.hidden)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(preset: .aligned, position: .leading, values: domain) { value in
                        AxisValueLabel {
                            if let id = value.as(String.self), let row = rowMap[id] {
                                Text(row.title)
                                    .font(.caption2)
                                    .foregroundStyle(hoveredSessionID == id ? Color.primary : Color.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(width: 110, alignment: .trailing)
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    guard !ScrollActivity.shared.isScrolling else { return }
                                    guard let frame = proxy.plotFrame.map({ geo[$0] }) else { return }
                                    let next = proxy.value(atY: location.y - frame.origin.y, as: String.self)
                                    if hoveredSessionID != next { hoveredSessionID = next }
                                    hoverToken.setActive(next != nil) {
                                        if hoveredSessionID != nil { hoveredSessionID = nil }
                                    }
                                case .ended:
                                    hoverToken.unregister()
                                    if hoveredSessionID != nil { hoveredSessionID = nil }
                                }
                            }
                            .onTapGesture {
                                if let hoveredSessionID {
                                    onSelectSession(hoveredSessionID)
                                }
                            }
                    }
                }
                .frame(height: max(84, CGFloat(topSessions.count) * 23 + 4))
                .id(colorScheme)
                .transaction { $0.animation = nil }
            }
        }
    }
}
