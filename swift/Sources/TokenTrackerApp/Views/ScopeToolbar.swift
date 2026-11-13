//
//  ScopeToolbar.swift
//  TokenTrackerApp
//
//  全局范围栏：时间范围 + Agent，放在内容区顶部。概览、用量、活动三页共用同一份
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
        HStack(spacing: 10) {
            leading()
            Picker(L10n.text("时间范围"), selection: $state.range) {
                ForEach(Self.ranges, id: \.key) { item in
                    Text(L10n.text(item.title)).tag(item.key)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    FilterChip(selected: state.agentFilter == nil) {
                        state.agentFilter = nil
                    } label: {
                        Text(L10n.text("全部 Agent"))
                    }
                    ForEach(agents, id: \.self) { agent in
                        FilterChip(selected: state.agentFilter == agent) {
                            state.agentFilter = state.agentFilter == agent ? nil : agent
                        } label: {
                            Circle().fill(toolColor(agent)).frame(width: 7, height: 7)
                            Text(toolDisplayName(agent))
                        }
                        .help(L10n.text("只看某个 Agent 的用量"))
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.vertical, 8)
    }
}

extension ScopeBar where Leading == EmptyView {
    init(state: AppState) { self.init(state: state) { EmptyView() } }
}
