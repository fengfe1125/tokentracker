//
//  OverviewView.swift
//  TokenTrackerApp
//
//  概览：4 统计卡 / 每日趋势图（Swift Charts，线性/对数切换）/
//  订阅配额卡 / 模型榜。数据对齐网页端 app.js。
//

import Charts
import SwiftUI
import TokenTrackerCore

struct OverviewView: View {
    @ObservedObject var state: AppState
    /// nil = 未手动切换（按极值比自动选）；对齐网页端 localStorage tt.yscale
    @AppStorage("tt.yscale") private var yScaleManual: String = ""
    @State private var logScale = false

    private var yi: Bool { (state.settings["unit_yi"] as? NSNumber)?.boolValue ?? false }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                statCards
                chartCard
                quotaSection
                modelSection
            }
            .padding(24)
        }
        .navigationTitle("用量概览")
        .onAppear { applyAutoScale() }
        .onChange(of: state.dailyRows) { _, _ in
            if yScaleManual.isEmpty { applyAutoScale() }
        }
    }

    // ------------------------------------------------------------ 头部 ----

    private var header: some View {
        HStack(alignment: .center) {
            Picker("时间范围", selection: $state.range) {
                Text("今天").tag("day")
                Text("本周").tag("week")
                Text("本月").tag("month")
                Text("全部").tag("all")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
            Spacer()
            if let updatedAt = state.updatedAt {
                Text("更新于 \(UIFormat.dateTime(ms: Int64(updatedAt.timeIntervalSince1970 * 1000)))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Button {
                state.requestScan()
            } label: {
                Label(state.scanning ? "扫描中…" : "扫描日志",
                      systemImage: state.scanning ? "arrow.triangle.2.circlepath" : "magnifyingglass")
            }
            .disabled(state.scanning)
        }
    }

    // ------------------------------------------------------------ 统计卡 ----

    private var statCards: some View {
        let total = state.statTotal
        let cards: [(title: String, value: String, sub: String, warn: Bool)] = [
            ("Token 总量", UIFormat.tokens(total.tokens, yi: yi),
             "输入 \(UIFormat.tokens(total.input, yi: yi)) · 输出 \(UIFormat.tokens(total.output, yi: yi)) · 缓存读写均计入", false),
            ("成本估算", UIFormat.cost(total.cost),
             total.unpriced > 0 ? "⚠ \(total.unpriced) 条未计价" : "按 prices.json 计价", total.unpriced > 0),
            ("会话数", "\(total.sessions)",
             "\(state.statRows.count) 个工具当前有数据", false),
            ("缓存读取", UIFormat.tokens(total.cacheRead, yi: yi),
             "写入 \(UIFormat.tokens(total.cacheWrite, yi: yi))", false),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4),
                         spacing: 12) {
            ForEach(cards, id: \.title) { card in
                VStack(alignment: .leading, spacing: 6) {
                    Text(card.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(card.value)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(card.sub)
                        .font(.caption2)
                        .foregroundStyle(card.warn ? Color.orange : Color.secondary)
                        .lineLimit(2)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
            }
        }
    }

    // ------------------------------------------------------------ 趋势图 ----

    private struct DailyPoint: Identifiable {
        var id: String { "\(day)|\(tool)" }
        let day: String
        let tool: String
        let tokens: Double
    }

    private var chartPoints: [DailyPoint] {
        state.dailyRows.map {
            DailyPoint(day: $0.day, tool: $0.tool, tokens: Double($0.stats.tokens))
        }
    }

    /// 极值比悬殊（>30 倍）时自动用对数；手动切换后不再自动。
    private func applyAutoScale() {
        let values = chartPoints.map(\.tokens).filter { $0 > 0 }.sorted(by: >)
        logScale = values.count > 1 && values[0] / values[values.count - 1] > 30
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("每日趋势")
                    .font(.headline)
                Spacer()
                Button("Y 轴 · \(logScale ? "对数" : "线性")") {
                    logScale.toggle()
                    yScaleManual = logScale ? "log" : "linear"
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            if chartPoints.isEmpty {
                ContentUnavailableView("暂无数据", systemImage: "chart.bar",
                                       description: Text("点右上角「扫描日志」"))
                    .frame(height: 240)
            } else {
                Chart(chartPoints) { point in
                    BarMark(
                        x: .value("日期", point.day),
                        y: .value("Tokens", logScale ? max(point.tokens, 1) : point.tokens)
                    )
                    .foregroundStyle(by: .value("工具", toolDisplayName(point.tool)))
                }
                .chartYScale(type: logScale ? .log : .linear)
                .chartForegroundStyleScale(domain: ScannerRegistry.all.map(toolDisplayName),
                                           range: ScannerRegistry.all.map { toolColor($0) })
                .chartLegend(.hidden)
                .frame(height: 240)
            }
        }
        .padding(16)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
    }

    // ------------------------------------------------------------ 配额 ----

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("订阅配额")
                .font(.headline)
            if state.quotaEntries.isEmpty {
                Text("未配置配额")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2),
                          spacing: 12) {
                    ForEach(state.quotaEntries, id: \.id) { entry in
                        QuotaCard(entry: entry)
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------ 模型榜 ----

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
