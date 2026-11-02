//
//  RootView.swift
//  TokenTrackerApp
//
//  主面板骨架：NavigationSplitView 侧栏（视图 + 7 工具数据源状态）+
//  详情区（概览 / 会话记录 / Agent 活动 / 设置）。快捷键 ⌘1/⌘2/⌘3 切视图、⌘R 扫描。
//

import SwiftUI
import TokenTrackerCore

struct RootView: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var state: AppState
    @ObservedObject private var sidebar = SidebarPreferences.shared

    private var yi: Bool { (state.settings["unit_yi"] as? NSNumber)?.boolValue ?? false }

    var body: some View {
        NavigationSplitView {
            List(selection: $state.selection) {
                Section {
                    ForEach(sidebar.layout.navigation.compactMap(SidebarNavigationItem.init(rawValue:))
                        .filter { sidebar.isVisible($0.id, in: .navigation) }) { item in
                        Label(item.title, systemImage: item.symbol).tag(item.selection)
                    }
                }
                if sidebar.layout.agents.contains(where: { sidebar.isVisible($0, in: .agents) }) {
                    Section(L10n.text("Agent 数据源")) {
                        ForEach(sidebar.layout.agents.filter { sidebar.isVisible($0, in: .agents) }, id: \.self) { name in
                            ToolSidebarRow(name: name,
                                           installed: state.detectInfo[name]?.installed ?? false,
                                           todayTokens: todayTokens(for: name),
                                           yi: yi)
                                .tag(NavSelection.tool(name))
                                .contextMenu {
                                    Button(L10n.text("数据健康")) {
                                        state.insights.showHealth(tool: name, rescan: { state.requestScan() })
                                    }
                                }
                        }
                    }
                }
                Section {
                    Label(L10n.text("设置"), systemImage: "gear")
                        .tag(NavSelection.settings)
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 180)
        } detail: {
            switch state.selection {
            case .projects:
                ProjectsView(model: state.insights)
            case .reports:
                ReportsView(model: state.insights)
            case .subscriptions:
                SubscriptionView(state: state)
            case .overview:
                OverviewView(state: state)
            case .sessions:
                SessionsView(state: state, toolFilter: nil)
            case .activity:
                ActivityView(state: state.activityPage, refresh: state.refreshActivity,
                             openDetail: state.showActivityDetail)
                    .equatable()
            case .tool(let id):
                SessionsView(state: state, toolFilter: id)
            case .settings:
                SettingsPanelView(state: state)
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        // 快捷键：⌘1/⌘2/⌘3 切视图 · ⌘R 扫描（⌘, 设置走系统 Settings 场景，⌘W 关闭面板）
        .background {
            VStack {
                Button("") { state.selection = .overview }
                    .keyboardShortcut("1", modifiers: .command)
                Button("") { state.selection = .sessions }
                    .keyboardShortcut("2", modifiers: .command)
                Button("") { state.selection = .activity }
                    .keyboardShortcut("3", modifiers: .command)
                Button("") { state.requestScan() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
        .onChange(of: state.selection) { _, _ in state.refreshVisibleData() }
        .onAppear { state.refreshVisibleData() }
    }

    private func todayTokens(for tool: String) -> Int64? {
        state.todayByTool[tool]
    }
}

/// 侧栏工具行：色点 + 名称 + 数据源状态 + 今日量
private struct ToolSidebarRow: View {
    @ObservedObject private var language = LanguageManager.shared
    let name: String
    let installed: Bool
    let todayTokens: Int64?
    let yi: Bool

    private var color: Color {
        guard let hex = MenuBarFmt.toolHex[name] else { return .secondary }
        let (r, g, b) = MenuBarFmt.hexRGB(hex)
        return Color(red: r, green: g, blue: b)
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(installed ? color : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            Text(toolDisplayName(name))
                .foregroundStyle(installed ? .primary : .secondary)
            Spacer()
            if let todayTokens, installed {
                Text(UIFormat.tokens(todayTokens, yi: yi))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !installed {
                Text(L10n.text("未检测到"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// 工具显示名（对齐网页端 TOOL 表）
func toolDisplayName(_ id: String) -> String {
    ["claude": "Claude Code", "codex": "Codex", "opencode": "opencode",
     "dsh": "DSH", "hermes": "Hermes", "kimi": "Kimi", "pi": "Pi",
     "go": "OpenCode Go"][id] ?? id
}

func toolColor(_ id: String) -> Color {
    guard let hex = MenuBarFmt.toolHex[id] else { return .secondary }
    let (r, g, b) = MenuBarFmt.hexRGB(hex)
    return Color(red: r, green: g, blue: b)
}
