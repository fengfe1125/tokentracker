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

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if compact {
                rangePicker.pickerStyle(.menu).fixedSize()
            } else {
                rangePicker.pickerStyle(.segmented)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("Agent", selection: $state.agentFilter) {
                Text(L10n.text("全部 Agent")).tag(String?.none)
                Divider()
                ForEach(agents, id: \.self) { agent in
                    Text(toolDisplayName(agent)).tag(Optional(agent))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help(L10n.text("只看某个 Agent 的用量"))
        }
    }

    private var rangePicker: some View {
        Picker(L10n.text("时间范围"), selection: $state.range) {
            Text(L10n.text("今天")).tag("day")
            Text(L10n.text("近 7 天")).tag("week")
            Text(L10n.text("本月")).tag("month")
            Text(L10n.text("全部")).tag("all")
        }
        .labelsHidden()
    }
}
