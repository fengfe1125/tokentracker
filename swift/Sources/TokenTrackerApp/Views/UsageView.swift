//
//  UsageView.swift
//  TokenTrackerApp
//
//  用量：同一份范围下按 项目 / 会话 / 模型 三个角度看，标签在范围栏最前面切换（RootView）。
//

import SwiftUI
import TokenTrackerCore

struct UsageView: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var state: AppState

    var body: some View {
        Group {
            switch state.usageTab {
            case .projects:
                ProjectsView(model: state.insights, resetRange: { state.refreshVisibleData() })
            case .sessions:
                SessionsView(state: state)
            case .models:
                ModelsView(state: state)
            }
        }
    }
}

/// 模型标签：汇总指标 + 模型列表 + 占比/Token 构成/缓存命中率可视化，点任一项带着模型筛选去看项目。
struct ModelsView: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var state: AppState
    @Environment(\.unitYi) private var yi
    @State private var donutMetric: UsageChartMetric = .tokens

    private func openModelProjects(_ model: String) {
        state.insights.query.model = model
        state.usageTab = .projects
        state.refreshVisibleData()
    }

    var body: some View {
        let rows = state.modelRows
        let top = rows.map(\.stats.tokens).max() ?? 0
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                if rows.isEmpty {
                    ContentUnavailableView(L10n.text("暂无数据"), systemImage: "cpu",
                                           description: Text(L10n.text("换个时间范围或 Agent，或等下一次扫描。")))
                        .frame(maxWidth: .infinity, minHeight: 220)
                        .card()
                } else {
                    summaryTiles(rows)
                    modelList(rows, top: top)
                    modelAnalytics(rows)
                }
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.bottom, Metrics.pagePadding)
            .padding(.top, 10)
        }
        .pageChrome(title: L10n.text("模型"),
                    subtitle: L10n.text("\(rows.count) 个模型"))
    }

    @ViewBuilder
    private func summaryTiles(_ rows: [UsageStore.ModelRow]) -> some View {
        let totalTokens = rows.reduce(Int64(0)) { $0 + $1.stats.tokens }
        let totalEvents = rows.reduce(Int64(0)) { $0 + $1.stats.events }
        let totalUnpriced = rows.reduce(Int64(0)) { $0 + $1.stats.unpriced }
        let totalCost = rows.reduce(0.0) { $0 + $1.stats.cost }
        let totalCacheRead = rows.reduce(Int64(0)) { $0 + $1.stats.cacheRead }
        let totalInputSide = rows.reduce(Int64(0)) { $0 + $1.stats.inputSideTokens }
        let hitRate: Double? = totalInputSide > 0
            ? Double(totalCacheRead) / Double(totalInputSide) * 100 : nil
        let agentCount = Set(rows.map(\.tool)).count
        let primary = rows.max { $0.stats.tokens < $1.stats.tokens }
        let primaryName = primary.map { $0.model.isEmpty ? L10n.text("（未知模型）") : $0.model } ?? "—"
        let primaryShare = primary.map { UIFormat.share($0.stats.tokens, of: totalTokens) } ?? "—"
        let costValue: String = {
            if totalEvents == 0 { return "—" }
            if totalUnpriced == totalEvents { return L10n.text("未计价") }
            return UIFormat.cost(totalCost)
        }()
        let costCaption = totalUnpriced > 0 && totalUnpriced < totalEvents
            ? L10n.text("含 \(totalUnpriced) 条未计价")
            : L10n.text("含估算，非订阅账单")

        let tiles = Group {
            StatTile(title: L10n.text("活跃模型"),
                     value: rows.count.formatted(.number),
                     caption: L10n.text("跨 \(agentCount) 个 Agent"))
            StatTile(title: L10n.text("主力模型"),
                     value: primaryName,
                     caption: L10n.text("占比 \(primaryShare)"))
            StatTile(title: L10n.text("费用合计"),
                     value: costValue,
                     caption: costCaption)
            StatTile(title: L10n.text("缓存命中率"),
                     value: UIFormat.percent(hitRate)) {
                MeterBar(fraction: (hitRate ?? 0) / 100).padding(.top, 5)
            }
        }
        .frame(minWidth: 118, maxHeight: .infinity, alignment: .topLeading)

        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Metrics.gridSpacing) { tiles }
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Metrics.gridSpacing),
                                GridItem(.flexible(), spacing: Metrics.gridSpacing)],
                      spacing: Metrics.gridSpacing) { tiles }
        }
    }

    private func modelList(_ rows: [UsageStore.ModelRow], top: Int64) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().padding(.leading, Metrics.cardPadding) }
                Button {
                    openModelProjects(row.model)
                } label: {
                    ShareRow(fraction: top > 0 ? Double(row.stats.tokens) / Double(top) : 0,
                             tint: toolColor(row.tool),
                             primary: UIFormat.compact(row.stats.tokens, yi: yi),
                             secondary: UIFormat.sessionCost(row.stats)) {
                        Circle().fill(toolColor(row.tool)).frame(width: 8, height: 8)
                        Text(row.model.isEmpty ? L10n.text("（未知模型）") : row.model)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(toolDisplayName(row.tool))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let rate = row.stats.cacheHitRate {
                            let pct = String(format: "%.0f%%", rate)
                            Text(L10n.text("缓存 \(pct)"))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, Metrics.cardPadding)
                    .padding(.vertical, 3)
                    .hoverHighlight()
                }
                .buttonStyle(.plain)
                .help(L10n.text("查看用到这个模型的项目"))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .card(padding: 0)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    @ViewBuilder
    private func modelAnalytics(_ rows: [UsageStore.ModelRow]) -> some View {
        let donutData = UsageChartBuilder.modelDonut(rows: rows, metric: donutMetric)
        let mixItems = UsageChartBuilder.modelMix(rows: rows)
        let cacheItems = UsageChartBuilder.cacheHitItems(rows: rows)
        let activeCount = rows.filter { $0.stats.tokens > 0 }.count

        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Metrics.sectionSpacing) {
                UsageDonutCard(
                    title: L10n.text("模型占比"),
                    centerSubtitle: L10n.text("\(donutData.itemCount) 个模型"),
                    data: donutData,
                    metric: $donutMetric,
                    yi: yi,
                    onSelect: openModelProjects
                )
                .frame(minWidth: 360)
                TokenMixBarCard(
                    title: L10n.text("模型 Token 构成"),
                    items: mixItems,
                    totalCount: activeCount,
                    yi: yi,
                    onSelect: openModelProjects
                )
                .frame(minWidth: 360)
            }
            .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: Metrics.sectionSpacing) {
                UsageDonutCard(
                    title: L10n.text("模型占比"),
                    centerSubtitle: L10n.text("\(donutData.itemCount) 个模型"),
                    data: donutData,
                    metric: $donutMetric,
                    yi: yi,
                    onSelect: openModelProjects
                )
                TokenMixBarCard(
                    title: L10n.text("模型 Token 构成"),
                    items: mixItems,
                    totalCount: activeCount,
                    yi: yi,
                    onSelect: openModelProjects
                )
            }
        }

        if !cacheItems.isEmpty {
            CacheHitComparisonCard(items: cacheItems, yi: yi, onSelect: openModelProjects)
        }
    }
}
