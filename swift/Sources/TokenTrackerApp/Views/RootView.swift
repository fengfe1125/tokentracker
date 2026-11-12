//
//  RootView.swift
//  TokenTrackerApp
//
//  主面板骨架：NavigationSplitView 侧栏（五个入口，扫描状态与设置固定在底部）+
//  详情区。页面标题、操作与全局范围在窗口工具栏。快捷键 ⌘1–⌘5 切视图、⌘R 扫描。
//

import SwiftUI
import TokenTrackerCore

struct RootView: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var state: AppState
    @ObservedObject private var sidebar = SidebarPreferences.shared

    @State private var columns = NavigationSplitViewVisibility.all

    private var yi: Bool { (state.settings["unit_yi"] as? NSNumber)?.boolValue ?? false }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: $state.selection) {
                Section {
                    ForEach(sidebar.layout.navigation.compactMap(SidebarNavigationItem.init(rawValue:))
                        .filter { sidebar.isVisible($0.id, in: .navigation) }) { item in
                        Label(item.title, systemImage: item.symbol).tag(item.selection)
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    scanStatusRow
                    settingsRow
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 300)
        } detail: {
            if let route = state.detail {
                detailPage(route)
            } else {
            switch state.selection {
            case .overview:
                OverviewView(state: state)
            case .usage:
                UsageView(state: state)
            case .activity:
                ActivityView(state: state.activityPage, refresh: state.refreshActivity,
                             openDetail: state.showActivityDetail)
                    .equatable()
                    .toolbar { ScopeToolbar(state: state, compact: true) }
            case .reports:
                ReportsView(model: state.insights)
            case .accounts:
                AccountsView(state: state)
            case .settings:
                SettingsPanelView(state: state)
            }
            }
        }
        .background { HealthSheetHost(model: state.insights, yi: yi) }
        .frame(minWidth: 820, minHeight: 520)
        .environment(\.unitYi, yi)
        // 每个页面都至少有这一项，窗口工具栏常驻，切页时标题栏高度不跳
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation { columns = columns == .detailOnly ? .all : .detailOnly }
                } label: {
                    Label(L10n.text("切换侧栏"), systemImage: "sidebar.leading")
                }
                .help(L10n.text("切换侧栏"))
            }
        }
        // 快捷键：⌘1/⌘2/⌘3 切视图 · ⌘R 扫描（⌘, 设置走系统 Settings 场景，⌘W 关闭面板）
        .background {
            VStack {
                Button("") { state.selection = .overview }
                    .keyboardShortcut("1", modifiers: .command)
                Button("") { state.selection = .usage }
                    .keyboardShortcut("2", modifiers: .command)
                Button("") { state.selection = .activity }
                    .keyboardShortcut("3", modifiers: .command)
                Button("") { state.selection = .reports }
                    .keyboardShortcut("4", modifiers: .command)
                Button("") { state.selection = .accounts }
                    .keyboardShortcut("5", modifiers: .command)
                Button("") { state.requestScan() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
        .onChange(of: state.selection) { _, _ in state.refreshVisibleData() }
        .onChange(of: state.usageTab) { _, _ in state.refreshVisibleData() }
        .onAppear { state.refreshVisibleData() }
    }

    /// 下钻页：会话详情 / 活动明细。返回用工具栏的后退、Esc 或 ⌘[。
    @ViewBuilder
    private func detailPage(_ route: DetailRoute) -> some View {
        Group {
            switch route {
            case .session: SessionDetailView(state: state)
            case .activity: ActivityDetailView(state: state)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { state.closeDetail() } label: {
                    Label(L10n.text("返回"), systemImage: "chevron.left")
                }
                .keyboardShortcut("[", modifiers: .command)
                .help(L10n.text("返回"))
            }
        }
        .background {
            Button("") { state.closeDetail() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .allowsHitTesting(false)
        }
    }

    /// 扫描状态：上次更新时间；点按查看各数据源的健康状况。
    private var scanStatusRow: some View {
        Button {
            state.insights.showHealth(rescan: { state.requestScan() })
        } label: {
            HStack(spacing: 6) {
                if state.scanning {
                    ProgressView().controlSize(.mini)
                    Text(L10n.text("扫描中…"))
                } else {
                    Image(systemName: state.dataError == nil ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(state.dataError == nil ? Color.secondary : Color.orange)
                    Text(state.updatedAt.map {
                        L10n.text("更新于 ") + $0.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale))
                    } ?? L10n.text("尚未扫描"))
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.text("数据健康"))
    }

    /// 设置固定在侧栏底部，不和数据页面混排。
    private var settingsRow: some View {
        let selected = state.selection == .settings
        return Button {
            state.selection = .settings
        } label: {
            Label(L10n.text("设置"), systemImage: "gearshape")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(selected ? Color.primary.opacity(0.1) : .clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 数据健康面板：附着在主窗口上。单独成一个视图是为了订阅 InsightsModel 的变化。
private struct HealthSheetHost: View {
    @ObservedObject var model: InsightsModel
    let yi: Bool

    var body: some View {
        Color.clear
            .sheet(item: $model.healthRequest) { request in
                HealthView(model: model, tool: request.tool, rescan: request.rescan)
                    .appLanguage()
                    .environment(\.unitYi, yi)
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
