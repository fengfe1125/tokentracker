//
//  UsageView.swift
//  TokenTrackerApp
//
//  用量：同一份范围下按 项目 / 会话 / 模型 三个角度看，标签在工具栏中间切换。
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
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(L10n.text("用量"), selection: $state.usageTab) {
                    Text(L10n.text("项目")).tag(UsageTab.projects)
                    Text(L10n.text("会话")).tag(UsageTab.sessions)
                    Text(L10n.text("模型")).tag(UsageTab.models)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ScopeToolbar(state: state, compact: true)
        }
    }
}

/// 模型标签：当前范围内的全部模型，点一行带着模型筛选去看项目。
struct ModelsView: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var state: AppState
    @Environment(\.unitYi) private var yi

    var body: some View {
        let rows = state.modelRows
        let top = rows.map(\.stats.tokens).max() ?? 0
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if rows.isEmpty {
                    ContentUnavailableView(L10n.text("暂无数据"), systemImage: "cpu",
                                           description: Text(L10n.text("换个时间范围或 Agent，或等下一次扫描。")))
                        .frame(maxWidth: .infinity, minHeight: 220)
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().padding(.leading, Metrics.cardPadding) }
                    Button {
                        state.insights.query.model = row.model
                        state.usageTab = .projects
                        state.refreshVisibleData()
                    } label: {
                        ShareRow(fraction: top > 0 ? Double(row.stats.tokens) / Double(top) : 0,
                                 tint: toolColor(row.tool),
                                 primary: UIFormat.compact(row.stats.tokens, yi: yi),
                                 secondary: row.stats.events > 0 && row.stats.unpriced == row.stats.events
                                    ? L10n.text("未计价") : UIFormat.cost(row.stats.cost)) {
                            Circle().fill(toolColor(row.tool)).frame(width: 8, height: 8)
                            Text(row.model.isEmpty ? L10n.text("（未知模型）") : row.model)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(toolDisplayName(row.tool))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
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
            .padding(Metrics.pagePadding)
        }
        .pageChrome(title: L10n.text("模型"),
                    subtitle: L10n.text("\(rows.count) 个模型"))
    }
}
