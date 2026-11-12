//
//  ScopeToolbar.swift
//  TokenTrackerApp
//
//  全局范围的工具栏控件：时间范围 + Agent。概览、用量、活动三页共用同一份
//  AppState.range / agentFilter，切页不用重选。
//

import SwiftUI
import TokenTrackerCore

struct ScopeToolbar: ToolbarContent {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject private var sidebar = SidebarPreferences.shared
    @ObservedObject var state: AppState
    /// 工具栏拥挤的页面把时间范围收成下拉
    var compact = false

    /// 顺序与隐藏沿用设置里的 Agent 列表；当前选中的即使被隐藏也保留在菜单里
    private var agents: [String] {
        sidebar.layout.agents.filter { sidebar.isVisible($0, in: .agents) || $0 == state.agentFilter }
    }

    private static let ranges: [(key: String, title: L10n.Template)] = [
        ("day", "今天"), ("week", "近 7 天"), ("month", "本月"), ("all", "全部"),
    ]

    private var rangeTitle: String {
        Self.ranges.first { $0.key == state.range }.map { L10n.text($0.title) } ?? state.range
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if compact {
                // 用 Menu 自带标题：菜单样式的 Picker 在窗口刚出现时偶尔渲染成空白按钮
                Menu(rangeTitle) {
                    ForEach(Self.ranges, id: \.key) { item in
                        Toggle(L10n.text(item.title), isOn: Binding(
                            get: { state.range == item.key },
                            set: { if $0 { state.range = item.key } }))
                    }
                }
                .fixedSize()
                .help(L10n.text("时间范围"))
            } else {
                Picker(L10n.text("时间范围"), selection: $state.range) {
                    ForEach(Self.ranges, id: \.key) { item in
                        Text(L10n.text(item.title)).tag(item.key)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu(state.agentFilter.map(toolDisplayName) ?? L10n.text("全部 Agent")) {
                Toggle(L10n.text("全部 Agent"), isOn: Binding(
                    get: { state.agentFilter == nil },
                    set: { if $0 { state.agentFilter = nil } }))
                Divider()
                ForEach(agents, id: \.self) { agent in
                    Toggle(toolDisplayName(agent), isOn: Binding(
                        get: { state.agentFilter == agent },
                        set: { if $0 { state.agentFilter = agent } }))
                }
            }
            .fixedSize()
            .help(L10n.text("只看某个 Agent 的用量"))
        }
    }
}
