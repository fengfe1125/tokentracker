//
//  RootView.swift
//  TokenTrackerApp
//
//  主面板骨架：窗口工具栏中间是导航标签（TopTabBar），右侧是扫描状态与扫描；
//  内容区顶部是全局范围栏（ScopeBar），下面是页面。快捷键 ⌘1–⌘6 切视图、⌘R 扫描。
//

import SwiftUI
import TokenTrackerCore

struct RootView: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var state: AppState
    @ObservedObject private var sidebar = SidebarPreferences.shared

    @State private var windowWidth: CGFloat = 1080

    private var yi: Bool { state.prefs.unitYi }

    /// 时间范围和 Agent 筛选只对这三页有意义。
    private var scoped: Bool {
        state.detail == nil && [.overview, .usage, .activity].contains(state.selection)
    }

    var body: some View {
        // 不用 NavigationStack：它会把页面标题画进工具栏，和中间的导航标签抢位置
        Group {
            VStack(spacing: 0) {
                if scoped {
                    ScopeBar(state: state) {
                        if state.selection == .usage {
                            Picker(L10n.text("用量"), selection: $state.usageTab) {
                                Text(L10n.text("项目")).tag(UsageTab.projects)
                                Text(L10n.text("会话")).tag(UsageTab.sessions)
                                Text(L10n.text("模型")).tag(UsageTab.models)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                            Divider().frame(height: 16)
                        }
                    }
                    Divider()
                }
                page.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TopTabBar(state: state, compact: windowWidth < 980)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    scanStatus
                    scanMenu
                }
            }
        }
        .tint(.brand)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { windowWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in windowWidth = width }
            }
        }
        .background { HealthSheetHost(model: state.insights, yi: yi) }
        .frame(minWidth: 820, minHeight: 520)
        .environment(\.unitYi, yi)
        // 快捷键：⌘1–⌘6 按导航顺序切页 · ⌘R 扫描（⌘, 设置走系统 Settings 场景，⌘W 关闭面板）
        .background {
            VStack {
                ForEach(Array(TopTabBar.items(sidebar).prefix(9).enumerated()), id: \.element.id) { index, item in
                    Button("") { state.selection = item.selection }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
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

    @ViewBuilder
    private var page: some View {
        if let route = state.detail {
            detailPage(route)
        } else {
            switch state.selection {
            case .overview:
                OverviewView(state: state)
            case .usage:
                UsageView(state: state)
            case .ports:
                PortsView(model: state.ports, state: state)
            case .activity:
                ActivityView(state: state.activityPage, refresh: state.refreshActivity,
                             openDetail: state.showActivityDetail)
                    .equatable()
            case .reports:
                ReportsView(model: state.insights)
            case .accounts:
                AccountsView(state: state)
            case .settings:
                SettingsPanelView(state: state)
            }
        }
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
    private var scanStatus: some View {
        Button {
            state.insights.showHealth(rescan: { state.requestScan() })
        } label: {
            HStack(spacing: 5) {
                Image(systemName: state.dataError == nil ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(state.dataError == nil ? Color.secondary : Color.orange)
                if windowWidth >= 980 {
                    Text(state.updatedAt.map {
                        L10n.text("更新于 ") + $0.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale))
                    } ?? L10n.text("尚未扫描"))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .help(L10n.text("数据健康"))
    }

    /// 点按立即扫描，展开选择自动刷新间隔。
    private var scanMenu: some View {
        Menu {
            Picker(L10n.text("刷新间隔"), selection: Binding(
                get: { state.scanIntervalSeconds },
                set: { state.updateSetting(key: "scan_interval", value: $0) })) {
                Text("30s").tag(30)
                Text(L10n.text("1分钟")).tag(60)
                Text(L10n.text("5分钟")).tag(300)
                Text(L10n.text("10分钟")).tag(600)
            }
            .pickerStyle(.inline)
        } label: {
            Label(state.scanning ? L10n.text("扫描中…") : L10n.text("扫描"), systemImage: "arrow.clockwise")
        } primaryAction: {
            state.requestScan()
        }
        .disabled(state.scanning)
        .help(L10n.text("立即扫描"))
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
