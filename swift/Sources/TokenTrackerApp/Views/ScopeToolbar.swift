//
//  ScopeToolbar.swift
//  TokenTrackerApp
//
//  全局范围：时间范围 + Agent，放在页面栏（RootView）里。概览、用量、活动三页共用同一份
//  AppState.range / agentFilter，切页不用重选。前面可以放页面自己的分段控件。
//

import SwiftUI
import TokenTrackerCore

struct ScopeBar<Leading: View>: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject private var sidebar = SidebarPreferences.shared
    @ObservedObject var state: AppState
    @ViewBuilder var leading: () -> Leading

    /// 顺序与隐藏沿用设置里的 Agent 列表；当前选中的即使被隐藏也保留
    private var agents: [String] {
        sidebar.layout.agents.filter { sidebar.isVisible($0, in: .agents) || $0 == state.agentFilter }
    }

    private static var ranges: [(key: String, title: L10n.Template)] {
        [("day", "今天"), ("week", "近 7 天"), ("month", "本月"), ("all", "全部")]
    }

    var body: some View {
        HStack(spacing: 8) {
            leading()
            SegmentedPillPicker(
                accessibilityTitle: L10n.text("时间范围"),
                selection: $state.range,
                options: Self.ranges.map { SegmentedOption(value: $0.key, title: L10n.text($0.title)) }
            )
            agentMenu
        }
    }

    /// Agent 筛选：胶囊下拉菜单，选中特定 Agent 时带对应色点与柔和色调。
    private var agentMenu: some View {
        PageMenuPill(activeTint: state.agentFilter.map(toolColor)) {
            if let agent = state.agentFilter {
                Circle().fill(toolColor(agent)).frame(width: 7, height: 7)
                Text(toolDisplayName(agent))
            } else {
                Image(systemName: "person.2")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(L10n.text("全部 Agent"))
            }
        } content: {
            Picker("Agent", selection: $state.agentFilter) {
                Text(L10n.text("全部 Agent")).tag(String?.none)
                Divider()
                ForEach(agents, id: \.self) { agent in
                    Text(toolDisplayName(agent)).tag(Optional(agent))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .help(L10n.text("只看某个 Agent 的用量"))
    }
}

extension ScopeBar where Leading == EmptyView {
    init(state: AppState) { self.init(state: state) { EmptyView() } }
}
