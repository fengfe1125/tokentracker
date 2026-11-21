//
//  RootView.swift
//  TokenTrackerApp
//
//  主面板骨架：窗口工具栏中间是导航标签（TopTabBar），右侧是扫描状态与扫描，切页时不变；
//  工具栏下是高度固定的页面栏（范围 / 标题 + 页面操作），再下面是页面。快捷键 ⌘1–⌘6 切视图、⌘R 扫描。
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
        // 不用 NavigationStack：它会把页面标题画进工具栏，和中间的导航标签抢位置。
        // 工具栏只放固定的导航与扫描；页面标题、筛选与操作都在下面高度固定的页面栏里，
        // 切页时只换页面栏的内容，工具栏和页面栏本身不动。
        VStack(spacing: 0) {
            // 页面栏和内容是同一块背景，中间不画分隔线
            Color.clear.frame(height: showsPageBar ? Self.pageBarHeight : 0)
            page.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlayPreferenceValue(PageChromeKey.self, alignment: .top) { chrome in
            if showsPageBar { pageBar(chrome) }
        }
        .toolbar {
            // 整条顶栏是一个居中的工具栏项，宽度与窗口左右对称（左边让出红绿灯）：
            // 导航标签落在窗口正中，扫描控件贴右边，不再由系统决定摆放位置
            principalToolbarItem
        }
        // 工具栏不单独画背景，和页面栏、内容连成一整块
        .toolbarBackground(.hidden, for: .windowToolbar)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
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

    static let pageBarHeight: CGFloat = 44
    /// 顶栏左右各留出的宽度：左边是红绿灯，右边对称留同样的边距
    static let titlebarInset: CGFloat = 86

    @ToolbarContentBuilder
    private var principalToolbarItem: some ToolbarContent {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .principal) {
                topBar.frame(width: max(windowWidth - 2 * Self.titlebarInset, 480))
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) {
                topBar.frame(width: max(windowWidth - 2 * Self.titlebarInset, 480))
            }
        }
        #else
        ToolbarItem(placement: .principal) {
            topBar.frame(width: max(windowWidth - 2 * Self.titlebarInset, 480))
        }
        #endif
    }

    /// 顶栏：标签居中、扫描控件靠右。左边放一份隐藏的扫描控件占位，保证标签正好在中间；
    /// 放不下时依次去掉更新时间、把标签收成图标。
    private var topBar: some View {
        ViewThatFits(in: .horizontal) {
            topBarRow(compact: false, showTime: true)
            topBarRow(compact: false, showTime: false)
            topBarRow(compact: true, showTime: false)
        }
    }

    private func topBarRow(compact: Bool, showTime: Bool) -> some View {
        HStack(spacing: 0) {
            scanControls(showTime: showTime).hidden().accessibilityHidden(true)
            Spacer(minLength: 12)
            TopTabBar(state: state, compact: compact)
            Spacer(minLength: 12)
            scanControls(showTime: showTime)
        }
    }

    private func scanControls(showTime: Bool) -> some View {
        HStack(spacing: 2) {
            scanStatus(showTime: showTime)
            scanMenu
        }
        .fixedSize()
    }

    /// 只有带筛选或返回的页面才显示页面栏；端口、账号、设置、报告不显示
    /// （顶栏标签已经标出当前页，报告和设置的操作在各自左侧列表里），内容直接从顶栏下开始。
    /// 是否显示只看当前页，不等页面上报，切页时同一帧就定下来，不会先空一条再收起。
    private var showsPageBar: Bool {
        scoped || state.detail != nil || state.selection == .usage
    }

    /// 页面栏：左边是返回 / 全局范围（概览、用量、活动）或页面标题，右边是页面自己的操作。
    private func pageBar(_ chrome: PageChrome?) -> some View {
        HStack(spacing: 8) {
            if state.detail != nil {
                Button { state.closeDetail() } label: {
                    Label(L10n.text("返回"), systemImage: "chevron.left")
                }
                .buttonStyle(.pageIcon)
                .keyboardShortcut("[", modifiers: .command)
                .help(L10n.text("返回"))
            }
            chrome?.leading
            if scoped {
                // 时间范围与 Agent 在概览、用量、活动三页的同一位置，切页不挪
                ScopeBar(state: state)
                if state.selection == .usage {
                    // 固定在范围栏右侧：切 项目 / 会话 / 模型 时不会随右侧搜索框增减而左右乱跳
                    PageActionDivider()
                    SegmentedPillPicker(
                        accessibilityTitle: L10n.text("用量"),
                        selection: $state.usageTab,
                        options: [
                            SegmentedOption(value: UsageTab.projects, title: L10n.text("项目")),
                            SegmentedOption(value: UsageTab.sessions, title: L10n.text("会话")),
                            SegmentedOption(value: UsageTab.models, title: L10n.text("模型")),
                        ]
                    )
                }
                // 左边是固定筛选与视角，右边是当前页自己的搜索与操作
                Spacer(minLength: 8)
                if let subtitle = chrome?.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
            } else if let chrome, state.detail != nil || !chrome.subtitle.isEmpty {
                // 页面名已在顶栏标签上；只有详情页或带副标题（如周报的日期）时才写标题
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(chrome.title).font(.headline).lineLimit(1)
                    if !chrome.subtitle.isEmpty {
                        Text(chrome.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
            } else {
                Spacer(minLength: 8)
            }
            chrome?.actions
                .buttonStyle(.pageIcon)
                .fixedSize()
        }
        .padding(.horizontal, Metrics.pagePadding)
        .frame(height: Self.pageBarHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 下钻页：会话详情 / 活动明细。返回用页面栏的后退、Esc 或 ⌘[。
    @ViewBuilder
    private func detailPage(_ route: DetailRoute) -> some View {
        Group {
            switch route {
            case .session: SessionDetailView(state: state)
            case .activity: ActivityDetailView(state: state)
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
    private func scanStatus(showTime: Bool) -> some View {
        Button {
            state.insights.showHealth(rescan: { state.requestScan() })
        } label: {
            HStack(spacing: 5) {
                Image(systemName: state.dataError == nil ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.system(size: ToolbarChip.iconSize, weight: .medium))
                    .foregroundStyle(state.dataError == nil ? Color.secondary : Color.orange)
                if showTime {
                    Text(state.updatedAt.map {
                        L10n.text("更新于 ") + $0.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale))
                    } ?? L10n.text("尚未扫描"))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: ToolbarChip.height)
            .padding(.horizontal, showTime ? 10 : 4)
            .frame(height: ToolbarChip.height)
            .contentShape(Capsule())
        }
        .buttonStyle(ToolbarChipStyle())
        .help(L10n.text("数据健康"))
    }

    /// 扫描：左边立即扫描，右边的小箭头选择自动刷新间隔。
    private var scanMenu: some View {
        HStack(spacing: 0) {
            Button { state.requestScan() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: ToolbarChip.iconSize, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: ToolbarChip.height, height: ToolbarChip.height)
                    .contentShape(Capsule())
            }
            .buttonStyle(ToolbarChipStyle())
            .disabled(state.scanning)
            .help(state.scanning ? L10n.text("扫描中…") : L10n.text("立即扫描"))
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
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: ToolbarChip.height)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(ToolbarChipStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L10n.text("刷新间隔"))
        }
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
     "antigravity": "Antigravity", "go": "OpenCode Go"][id] ?? id
}

func toolColor(_ id: String) -> Color {
    guard let hex = MenuBarFmt.toolHex[id] else { return .secondary }
    let (r, g, b) = MenuBarFmt.hexRGB(hex)
    return Color(red: r, green: g, blue: b)
}
