//
//  TodayPulseView.swift
//  TokenTrackerApp
//
//  概览「今天」少小时实时脉冲面板（方案三）：
//  当今天活跃小时数 ≤ 2 时，替代空旷/过宽的单柱柱图，在原 220pt 槽位内展示：
//  左侧：今日活跃时段 + 较昨日同刻对比 + 24 小时迷你节奏条（悬停看明细）+ 四类 Token 横向构成；
//  右侧：今日主要会话排行（点击直达会话详情）+ 一键「切到柱图」入口。
//  达到 3 个活跃小时后自动切回 24 小时柱图。
//

import SwiftUI
import TokenTrackerCore

struct TodayPulseView: View {
    @ObservedObject private var language = LanguageManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let daySlots: [TrendPoint]
    let activePoints: [TrendPoint]
    let total: UsageStore.ToolStats
    let yesterdaySameTimeTokens: Int64?
    let sessions: [SessionRowModel]
    let yi: Bool
    let onSwitchToBarChart: () -> Void
    let onSelectSession: (String) -> Void

    @State private var hoveredHourID: String?
    @State private var hoverToken = HoverTokenBox()
    @State private var pulsing = false

    private var activeSummaryText: String {
        let active = activePoints.filter { $0.tokens > 0 }
        if active.count == 1, let only = active.first {
            let range = TodayTrendBuilder.hourRangeLabel(only.id)
            return L10n.text("\(range) · 活跃 1 小时")
        }
        let separator = L10n.isEnglish ? ", " : "、"
        let joined = active.map(\.id).joined(separator: separator)
        return L10n.text("活跃 \(active.count) 小时（\(joined)）")
    }

    private var yesterdayBadgeText: String? {
        guard let delta = TodayTrendBuilder.yesterdayDeltaPercent(
            todayTokens: total.tokens,
            yesterdaySameTimeTokens: yesterdaySameTimeTokens
        ) else { return nil }
        return L10n.text("较昨日同刻 \(TodayTrendBuilder.signedPercentText(delta))")
    }

    private var hoveredPoint: TrendPoint? {
        guard let hoveredHourID else { return nil }
        return daySlots.first { $0.id == hoveredHourID && !$0.isFuture }
    }

    private var topSessions: [SessionRowModel] {
        Array(sessions.filter { $0.tokens > 0 }
            .sorted { $0.tokens == $1.tokens ? $0.sortTs > $1.sortTs : $0.tokens > $1.tokens }
            .prefix(3))
    }

    var body: some View {
        AdaptiveEqualColumnsLayout(
            minColumnWidth: 235,
            spacing: 10,
            equalHeight: true,
            horizontalHeight: 220,
            minHorizontalWidthOverride: 475
        ) {
            leftPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            rightPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
        .onDisappear { hoverToken.unregister() }
    }

    // ------------------------------------------------------ 左侧：节奏 + 构成 ----

    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let hovered = hoveredPoint {
                    HStack(spacing: 6) {
                        Text(TodayTrendBuilder.hourRangeLabel(hovered.id))
                            .font(.caption.monospacedDigit().weight(.semibold))
                        if hovered.tokens > 0 {
                            Text(UIFormat.compact(Int64(hovered.tokens), yi: yi))
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(Color.brand)
                            if hovered.cost > 0 {
                                Text(UIFormat.costPrecise(hovered.cost))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text(L10n.text("无已记录用量"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                } else {
                    Text(activeSummaryText)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                if hoveredPoint == nil, let badge = yesterdayBadgeText {
                    Pill(text: badge, tint: .brand)
                }
            }
            .frame(height: 18)

            paceRail

            Spacer(minLength: 4)

            Divider()

            horizontalComposition
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sunkPanel(padding: 12, radius: 12)
    }

    private var paceRail: some View {
        let maxTokens = max(daySlots.map(\.tokens).max() ?? 0, 1)
        return VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(daySlots) { slot in
                    let isHovered = hoveredHourID == slot.id
                    let barHeight: CGFloat = {
                        if slot.isFuture { return 6 }
                        if slot.tokens <= 0 { return 4 }
                        return max(10, CGFloat(slot.tokens / maxTokens) * 34)
                    }()
                    let barColor: Color = {
                        if slot.isFuture { return Color.primary.opacity(0.04) }
                        if slot.tokens <= 0 { return Color.primary.opacity(0.11) }
                        if slot.isCurrent { return Color.brand }
                        return TokenKind.cacheRead.color.opacity(0.78)
                    }()
                    VStack(spacing: 3) {
                        if slot.isCurrent {
                            Circle()
                                .fill(Color.brand)
                                .frame(width: 5, height: 5)
                                .scaleEffect(pulsing ? 1.25 : 0.92)
                                .opacity(pulsing ? 0.65 : 1.0)
                        }
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(barColor)
                            .frame(height: barHeight)
                            .overlay {
                                if isHovered && !slot.isFuture {
                                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.6), lineWidth: 1)
                                }
                            }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering && !slot.isFuture {
                            guard !ScrollActivity.shared.isScrolling else { return }
                            if hoveredHourID != slot.id { hoveredHourID = slot.id }
                            hoverToken.setActive(true) {
                                if hoveredHourID != nil { hoveredHourID = nil }
                            }
                        } else if hoveredHourID == slot.id {
                            hoverToken.unregister()
                            hoveredHourID = nil
                        }
                    }
                }
            }
            .frame(height: 44)

            HStack {
                Text("00:00")
                Spacer()
                Text("06:00")
                Spacer()
                Text("12:00")
                Spacer()
                Text("18:00")
                Spacer()
                Text("23:00")
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.tertiary)
        }
    }

    private var horizontalComposition: some View {
        let sum = TokenKind.allCases.reduce(Int64(0)) { $0 + tokenValue($1) }
        return VStack(alignment: .leading, spacing: 8) {
            SegmentedBar(
                segments: TokenKind.allCases.map { kind in
                    SegmentedBarSegment(value: Double(tokenValue(kind)), color: kind.color, minWidth: 3)
                },
                height: 9
            )

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                      alignment: .leading, spacing: 6) {
                ForEach(TokenKind.allCases) { kind in
                    let value = tokenValue(kind)
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(kind.color)
                            .frame(width: 7, height: 7)
                        Text(kind.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(UIFormat.compact(value, yi: yi))
                            .font(.caption2.monospacedDigit().weight(.medium))
                            .lineLimit(1)
                        Text(UIFormat.share(value, of: sum))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    // ------------------------------------------------------ 右侧：今日主要会话 ----

    private var rightPanel: some View {
        let rows = topSessions
        let maxTok = max(rows.map(\.tokens).max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L10n.text("今日主要会话"))
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                TodayChartModePill(title: L10n.text("切到柱图"), active: false, action: onSwitchToBarChart)
            }

            if rows.isEmpty {
                Spacer(minLength: 0)
                Text(L10n.text("暂无会话"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                VStack(spacing: 2) {
                    ForEach(rows) { row in
                        sessionItem(row, maxTokens: maxTok)
                    }
                }
                Spacer(minLength: 0)
            }

            Divider()

            HStack(spacing: 6) {
                Text(L10n.text("活跃 ≥ 3 小时自动切回小时柱图"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if !rows.isEmpty {
                    Text(L10n.text("点击可看详情") + " ›")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sunkPanel(padding: 12, radius: 12)
    }

    private func sessionItem(_ row: SessionRowModel, maxTokens: Int64) -> some View {
        Button {
            onSelectSession(row.id)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(toolColor(row.tool))
                        .frame(width: 7, height: 7)
                    Text(row.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    Text(UIFormat.compact(row.tokens, yi: yi))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(Self.sessionMetaLine(row))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(row.costLabel)
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                MeterBar(fraction: Double(row.tokens) / Double(maxTokens),
                         tint: toolColor(row.tool), height: 2.5)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .hoverHighlight()
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -6)
        .help(row.sessionTooltip)
    }

    // ------------------------------------------------------ 辅助格式化 ----

    private func tokenValue(_ kind: TokenKind) -> Int64 {
        switch kind {
        case .cacheRead: total.cacheRead
        case .input: total.input
        case .cacheWrite: total.cacheWrite
        case .output: total.output
        }
    }

    static func sessionMetaLine(_ row: SessionRowModel, todayPrefix: String = UIFormat.todayString) -> String {
        var parts = [row.toolName]
        if row.folderShort != "—" { parts.append(row.folderShort) }
        let time = compactTodayTimeRange(row.fullTimeText, todayPrefix: todayPrefix)
        if time != "—" { parts.append(time) }
        return parts.joined(separator: " · ")
    }

    /// 去掉当天的 "yyyy-MM-dd " 日期前缀，只保留 "HH:mm → HH:mm" 或 "HH:mm"。
    nonisolated static func compactTodayTimeRange(_ fullRange: String, todayPrefix: String = UIFormat.todayString) -> String {
        let prefix = todayPrefix + " "
        return fullRange.replacingOccurrences(of: prefix, with: "")
    }
}

/// 概览「今天」脉冲 / 柱图模式切换胶囊按钮。
struct TodayChartModePill: View {
    let title: String
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: active ? .semibold : .medium))
                .lineLimit(1)
                .foregroundStyle(active ? Color.brand : (hovering ? Color.primary : Color.secondary))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(active ? Color.brand.opacity(0.14)
                                   : Color.primary.opacity(hovering ? 0.08 : 0.05))
                )
                .overlay(
                    Capsule().strokeBorder(active ? Color.clear : Color.primary.opacity(hovering ? 0.16 : 0.08),
                                           lineWidth: 0.5)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
