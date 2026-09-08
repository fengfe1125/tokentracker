//
//  OverviewView.swift
//  TokenTrackerApp
//
//  概览：cc-switch 风格使用统计 —— 总览大卡（真实消耗 Tokens / 总请求数 /
//  总成本）/ 2×2 输入输出明细卡 / 缓存命中率进度条 / 使用趋势平滑折线
//  （成本虚线走右侧轴）/ 订阅配额卡 / 模型榜。数据对齐 UsageStore.stats/daily。
//

import SwiftUI
import TokenTrackerCore

struct OverviewView: View {
    @ObservedObject var state: AppState

    private var yi: Bool { (state.settings["unit_yi"] as? NSNumber)?.boolValue ?? false }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "用量概览", subtitle: updatedText) {
                Picker("时间范围", selection: $state.range) {
                    Text("今天").tag("day")
                    Text("本周").tag("week")
                    Text("本月").tag("month")
                    Text("全部").tag("all")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                Menu {
                    Picker("刷新间隔", selection: intervalSelection) {
                        Text("30s").tag(30)
                        Text("1分钟").tag(60)
                        Text("5分钟").tag(300)
                        Text("10分钟").tag(600)
                    }
                } label: {
                    Label(intervalLabel, systemImage: "arrow.clockwise")
                        .font(.callout)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button {
                    state.requestScan()
                } label: {
                    Label(state.scanning ? "扫描中…" : "扫描",
                          systemImage: state.scanning
                              ? "arrow.triangle.2.circlepath" : "magnifyingglass")
                }
                .disabled(state.scanning)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryCard
                    detailGrid
                    hitRateCard
                    trendCard
                    quotaSection
                    modelSection
                }
                .padding(20)
            }
        }
        .navigationTitle("用量概览")
    }

    private var updatedText: String? {
        state.updatedAt.map {
            "更新于 " + UIFormat.dateTime(ms: Int64($0.timeIntervalSince1970 * 1000))
        }
    }

    /// 刷新间隔下拉（cc-switch 式）：读写设置键 scan_interval
    private var intervalSelection: Binding<Int> {
        Binding(get: { state.scanIntervalSeconds },
                set: { state.updateSetting(key: "scan_interval", value: $0) })
    }

    private var intervalLabel: String {
        switch state.scanIntervalSeconds {
        case 30: return "30s"
        case 300: return "5m"
        case 600: return "10m"
        default: return "1m"
        }
    }

    // -------------------------------------------------------- 总览大卡 ----

    private var summaryCard: some View {
        let total = state.statTotal
        return HStack(alignment: .center, spacing: 16) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 44, height: 44)
                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("真实消耗 Tokens")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // cc-switch 风格：完整千分位大数字 + 万换算副标签
                    Text(total.tokens, format: .number)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(UIFormat.wan(total.tokens))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("总请求数")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(total.events)")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.blue)
                }
                .frame(minWidth: 72, alignment: .leading)
                Divider()
                    .frame(height: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text("总成本")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(UIFormat.costPrecise(total.cost))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.green)
                }
                .padding(.leading, 14)
                .frame(minWidth: 88, alignment: .leading)
            }
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(16)
        .modifier(CardBackground())
    }

    // -------------------------------------------------------- 明细卡 ----

    private var detailGrid: some View {
        let t = state.statTotal
        let cards: [(title: String, value: String, icon: String, tint: Color)] = [
            ("新增输入", UIFormat.tokens(t.input, yi: yi), "arrow.down.to.line", .blue),
            ("Output", UIFormat.tokens(t.output, yi: yi), "arrow.up.to.line", .purple),
            ("创建", UIFormat.tokens(t.cacheWrite, yi: yi), "internaldrive", .secondary),
            ("命中", UIFormat.tokens(t.cacheRead, yi: yi), "sparkles", .indigo),
        ]
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                   GridItem(.flexible(), spacing: 12)],
                         spacing: 12) {
            ForEach(cards, id: \.title) { card in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: card.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(card.tint == .secondary ? Color.secondary : card.tint)
                        Text(card.title)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Text(card.value)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
            }
        }
    }

    // ---------------------------------------------------- 缓存命中率 ----

    private var hitRate: Double? {
        let t = state.statTotal
        guard t.tokens > 0 else { return nil }
        return Double(t.cacheRead) / Double(t.tokens) * 100
    }

    private var hitRateCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("缓存命中率")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(UIFormat.percent(hitRate))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.green)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.green.opacity(0.15))
                    Capsule()
                        .fill(Color.green)
                        .frame(width: geo.size.width * min(1, (hitRate ?? 0) / 100))
                }
            }
            .frame(height: 6)
        }
        .padding(16)
        .modifier(CardBackground())
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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("使用趋势")
                    .font(.headline)
                Spacer()
                Text(rangeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if trendPoints.isEmpty {
                ContentUnavailableView("暂无数据", systemImage: "chart.xyaxis.line",
                                       description: Text("点右上角「扫描」"))
                    .frame(height: 220)
            } else {
                HandDrawnTrendChart(points: trendPoints,
                                    isHourly: state.range == "day")
                trendLegend
            }
        }
        .padding(16)
        .modifier(CardBackground())
    }

    private var rangeLabel: String {
        ["day": "今天", "week": "本周", "month": "本月", "all": "全部"][state.range] ?? state.range
    }

    private var trendLegend: some View {
        let items: [(name: String, color: Color)] = [
            ("成本", .red), ("缓存创建", .orange), ("缓存命中", .purple),
            ("输入", .blue), ("输出", .green),
        ]
        return HStack(spacing: 14) {
            ForEach(items, id: \.name) { item in
                HStack(spacing: 4) {
                    Circle().fill(item.color).frame(width: 7, height: 7)
                    Text(item.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // ---------------------------------------------------------- 配额 ----

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("订阅配额")
                .font(.headline)
            if state.quotaEntries.isEmpty {
                Text("未配置配额")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                    GridItem(.flexible(), spacing: 12)],
                          spacing: 12) {
                    ForEach(state.quotaEntries, id: \.id) { entry in
                        QuotaCard(entry: entry)
                    }
                }
            }
        }
    }

    // -------------------------------------------------------- 模型榜 ----

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("模型榜")
                .font(.headline)
            if state.modelRows.isEmpty {
                Text("暂无数据")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(state.modelRows.prefix(10).enumerated()),
                            id: \.element.model) { index, row in
                        HStack {
                            Text("\(index + 1)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .frame(width: 20)
                            Circle().fill(toolColor(row.tool)).frame(width: 8, height: 8)
                            Text(row.model.isEmpty ? "（未知模型）" : row.model)
                                .font(.callout)
                                .lineLimit(1)
                            Spacer()
                            Text(UIFormat.tokens(row.stats.tokens, yi: yi))
                                .font(.callout.monospacedDigit())
                            Text(UIFormat.cost(row.stats.cost))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .trailing)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(index.isMultiple(of: 2) ? Color.primary.opacity(0.02) : .clear)
                    }
                }
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

/// 卡片统一背景：白底 + 圆角 + 轻阴影
private struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
    }
}

/// 配额卡：品牌色圆环 = 最紧窗口，右侧窗口明细行
private struct QuotaCard: View {
    let entry: MenuBarQuotaEntry

    private var tightest: MenuBarQuotaWindow? {
        MenuBarFmt.bestWindow(entry)
    }

    var body: some View {
        HStack(spacing: 14) {
            RingView(pct: tightest?.pct, role: MenuBarFmt.quotaUrgency(tightest?.pct),
                     hasData: tightest?.pct != nil)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.name)
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text(entry.windows.contains { $0.source == "official" } ? "官方" : "本地估算")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)
                }
                ForEach(entry.windows, id: \.label) { window in
                    HStack {
                        Text(window.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(MenuBarFmt.quotaMarker(window))\(window.pct.map { String(format: "%.0f%%", $0) } ?? "—")")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(urgencyColor(window.pct))
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
    }

    private func urgencyColor(_ pct: Double?) -> Color {
        switch MenuBarFmt.quotaUrgency(pct) {
        case "quota_crit": return .red
        case "quota_warn": return .orange
        default: return .secondary
        }
    }
}

/// 配额圆环（卡片版）：轨道 + 填充角
private struct RingView: View {
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
