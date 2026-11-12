//
//  OverviewView.swift
//  TokenTrackerApp
//
//  概览：指标行（Tokens / 费用 / 记录数 / 缓存命中率）→ Token 构成条 →
//  使用趋势 → Agent 与模型分布 → 用量热力图 → 数据与风险。
//  时间范围与扫描在窗口工具栏。数据对齐 UsageStore.stats/daily。
//

import SwiftUI
import TokenTrackerCore

struct OverviewView: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var state: AppState

    private var yi: Bool { (state.settings["unit_yi"] as? NSNumber)?.boolValue ?? false }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                if let error = state.dataError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                statRow
                compositionCard
                trendCard
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Metrics.sectionSpacing) {
                        agentCard.frame(minWidth: 300)
                        modelCard.frame(minWidth: 300)
                    }
                    VStack(spacing: Metrics.sectionSpacing) {
                        agentCard
                        modelCard
                    }
                }
                UsageHeatmapView(model: state.heatmap, yi: yi)
                InsightsOverview(model: state.insights, rescan: { state.requestScan() })
            }
            .padding(Metrics.pagePadding)
        }
        .overlay {
            if state.loadedRange != state.range && (state.dataLoading || state.dataError != nil) {
                ZStack {
                    Rectangle().fill(.regularMaterial)
                    if state.dataLoading {
                        ProgressView(L10n.text("正在读取用量…"))
                    } else {
                        ContentUnavailableView(L10n.text("用量读取失败，请重新扫描后重试"),
                                               systemImage: "exclamationmark.triangle")
                    }
                }
            }
        }
        .navigationTitle(L10n.text("用量概览"))
        .navigationSubtitle(updatedText ?? "")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker(L10n.text("时间范围"), selection: $state.range) {
                    Text(L10n.text("今天")).tag("day")
                    Text(L10n.text("近 7 天")).tag("week")
                    Text(L10n.text("本月")).tag("month")
                    Text(L10n.text("全部")).tag("all")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItem(placement: .primaryAction) {
                // 点按立即扫描，展开选择自动刷新间隔
                Menu {
                    Picker(L10n.text("刷新间隔"), selection: intervalSelection) {
                        Text("30s").tag(30)
                        Text(L10n.text("1分钟")).tag(60)
                        Text(L10n.text("5分钟")).tag(300)
                        Text(L10n.text("10分钟")).tag(600)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(state.scanning ? L10n.text("扫描中…") : L10n.text("扫描"),
                          systemImage: "arrow.clockwise")
                } primaryAction: {
                    state.requestScan()
                }
                .disabled(state.scanning)
                .help(L10n.text("立即扫描"))
            }
        }
    }

    private var updatedText: String? {
        state.updatedAt.map {
            L10n.text("更新于 ") + UIFormat.dateTime(ms: Int64($0.timeIntervalSince1970 * 1000))
        }
    }

    /// 自动刷新间隔：读写设置键 scan_interval
    private var intervalSelection: Binding<Int> {
        Binding(get: { state.scanIntervalSeconds },
                set: { state.updateSetting(key: "scan_interval", value: $0) })
    }

    private var rangeLabel: String {
        ["day": L10n.text("今天"), "week": L10n.text("近 7 天"), "month": L10n.text("本月"), "all": L10n.text("全部")][state.range] ?? state.range
    }

    // -------------------------------------------------------- 指标行 ----

    private var statRow: some View {
        let total = state.statTotal
        let unpriced = total.events > 0 && total.unpriced == total.events
        return HStack(alignment: .top, spacing: Metrics.gridSpacing) {
            StatTile(title: L10n.text("真实消耗 Tokens"),
                     value: UIFormat.compact(total.tokens, yi: yi),
                     caption: total.tokens.formatted(.number))
            StatTile(title: L10n.text("费用合计"),
                     value: unpriced ? L10n.text("未计价") : UIFormat.cost(total.cost),
                     caption: L10n.text("含估算，非订阅账单"))
            StatTile(title: L10n.text("用量记录数"),
                     value: total.events.formatted(.number),
                     caption: L10n.text("\(total.sessions) 个会话"))
            StatTile(title: L10n.text("缓存命中率"),
                     value: UIFormat.percent(total.cacheHitRate)) {
                MeterBar(fraction: (total.cacheHitRate ?? 0) / 100)
                    .padding(.top, 5)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // ------------------------------------------------------ Token 构成 ----

    private func tokens(_ kind: TokenKind, in stats: UsageStore.ToolStats) -> Int64 {
        switch kind {
        case .cacheRead: stats.cacheRead
        case .input: stats.input
        case .cacheWrite: stats.cacheWrite
        case .output: stats.output
        }
    }

    private var compositionCard: some View {
        let total = state.statTotal
        let sum = TokenKind.allCases.reduce(Int64(0)) { $0 + tokens($1, in: total) }
        let largest = TokenKind.allCases.max { tokens($0, in: total) < tokens($1, in: total) }
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: L10n.text("Token 构成")) {
                Text(rangeLabel).font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(TokenKind.allCases) { kind in
                        let value = tokens(kind, in: total)
                        if value > 0 {
                            // 最大的一段吃掉剩余宽度；其余按占比，非零段至少 3pt 可见
                            if kind == largest {
                                Rectangle().fill(kind.color)
                            } else {
                                Rectangle().fill(kind.color)
                                    .frame(width: max(3, geo.size.width * Double(value) / Double(max(sum, 1))))
                            }
                        }
                    }
                    if sum == 0 { Rectangle().fill(Color.primary.opacity(0.08)) }
                }
                .clipShape(Capsule())
            }
            .frame(height: 10)
            HStack(alignment: .top, spacing: Metrics.gridSpacing) {
                ForEach(TokenKind.allCases) { kind in
                    let value = tokens(kind, in: total)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Circle().fill(kind.color).frame(width: 7, height: 7)
                            Text(kind.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Text(UIFormat.compact(value, yi: yi))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text(UIFormat.share(value, of: sum))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(value.formatted(.number))
                }
            }
        }
        .card()
    }

    // ------------------------------------------------------ 使用趋势 ----

    /// 每个时间桶跨工具聚合后的用量点（dailyRows 是 分桶×工具 粒度）
    private var trendPoints: [TrendPoint] {
        var order: [String] = []
        var acc: [String: (i: Double, o: Double, cr: Double, cw: Double, c: Double)] = [:]
        for row in state.dailyRows {
            if acc[row.day] == nil {
                order.append(row.day)
                acc[row.day] = (0, 0, 0, 0, 0)
            }
            let a = acc[row.day]!
            acc[row.day] = (a.i + Double(row.stats.input),
                            a.o + Double(row.stats.output),
                            a.cr + Double(row.stats.cacheRead),
                            a.cw + Double(row.stats.cacheWrite),
                            a.c + row.stats.cost)
        }
        return order.map {
            TrendPoint(id: $0, day: $0,
                       input: acc[$0]!.i, output: acc[$0]!.o,
                       cacheRead: acc[$0]!.cr, cacheWrite: acc[$0]!.cw,
                       cost: acc[$0]!.c)
        }
    }

    private var trendCard: some View {
        let points = trendPoints
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: L10n.text("使用趋势")) { trendLegend }
            if points.isEmpty {
                ContentUnavailableView(L10n.text("暂无数据"), systemImage: "chart.bar.xaxis",
                                       description: Text(L10n.text("点右上角「扫描」")))
                    .frame(height: 220)
            } else {
                TrendChart(points: points, isHourly: state.range == "day", yi: yi)
            }
        }
        .card()
    }

    private var trendLegend: some View {
        HStack(spacing: 12) {
            ForEach(TokenKind.allCases) { kind in
                legendItem(kind.title, color: kind.color, line: false)
            }
            legendItem(L10n.text("成本"), color: .costSeries, line: true)
        }
    }

    private func legendItem(_ name: String, color: Color, line: Bool) -> some View {
        HStack(spacing: 4) {
            if line {
                Capsule().fill(color).frame(width: 10, height: 2)
            } else {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            }
            Text(name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    // ---------------------------------------------------- Agent / 模型 ----

    private func costText(_ stats: UsageStore.ToolStats) -> String {
        stats.events > 0 && stats.unpriced == stats.events
            ? L10n.text("未计价") : UIFormat.cost(stats.cost)
    }

    private var agentCard: some View {
        let rows = state.statRows
        let top = rows.map(\.tokens).max() ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            CardHeader(title: L10n.text("Agent 分布")) {
                Text(rangeLabel).font(.caption).foregroundStyle(.secondary)
            }
            if rows.isEmpty {
                emptyRows
            } else {
                ForEach(rows, id: \.tool) { row in
                    ShareRow(fraction: top > 0 ? Double(row.tokens) / Double(top) : 0,
                             tint: toolColor(row.tool),
                             primary: UIFormat.compact(row.tokens, yi: yi),
                             secondary: costText(row)) {
                        Circle().fill(toolColor(row.tool)).frame(width: 8, height: 8)
                        Text(toolDisplayName(row.tool)).font(.callout).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { state.selection = .tool(row.tool) }
                    .help(L10n.text("查看 \(toolDisplayName(row.tool)) 的会话"))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var modelCard: some View {
        let rows = Array(state.modelRows.prefix(8))
        let top = rows.map(\.stats.tokens).max() ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            CardHeader(title: L10n.text("模型榜")) {
                if state.modelRows.count > rows.count {
                    Text(L10n.text("前 \(rows.count) / 共 \(state.modelRows.count)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if rows.isEmpty {
                emptyRows
            } else {
                ForEach(rows) { row in
                    ShareRow(fraction: top > 0 ? Double(row.stats.tokens) / Double(top) : 0,
                             tint: toolColor(row.tool),
                             primary: UIFormat.compact(row.stats.tokens, yi: yi),
                             secondary: costText(row.stats)) {
                        Circle().fill(toolColor(row.tool)).frame(width: 8, height: 8)
                        Text(row.model.isEmpty ? L10n.text("（未知模型）") : row.model)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help("\(toolDisplayName(row.tool)) · \(row.model)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var emptyRows: some View {
        Text(L10n.text("暂无数据"))
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 60)
    }
}

/// 配额圆环（卡片版）：轨道 + 填充角
struct RingView: View {
    @ObservedObject private var language = LanguageManager.shared
    let pct: Double?
    let role: String
    let hasData: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(ringColor.opacity(hasData ? 0.22 : 1), lineWidth: hasData ? 5 : 1.5)
            if let pct, hasData {
                Circle()
                    .trim(from: 0, to: max(0, min(1, pct / 100)))
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text(pct.map { String(format: "%.0f", $0) } ?? "—")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(hasData ? .primary : .tertiary)
        }
    }

    private var ringColor: Color {
        guard hasData else { return Color.secondary.opacity(0.5) }
        switch role {
        case "quota_crit": return .red
        case "quota_warn": return .orange
        default: return .green
        }
    }
}
