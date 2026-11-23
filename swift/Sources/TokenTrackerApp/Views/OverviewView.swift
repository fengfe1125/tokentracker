//
//  OverviewView.swift
//  TokenTrackerApp
//
//  概览：配额条（各账号最紧的窗口）→ 指标行（Tokens / 费用 / 记录数 / 缓存命中率）→ Token 构成条 →
//  使用趋势 → 用量热力图 → Token 构成 / Agent / 模型分布。数据健康入口在顶栏扫描状态。
//  时间范围与扫描在窗口工具栏。数据对齐 UsageStore.stats/daily。
//

import SwiftUI
import TokenTrackerCore

struct OverviewView: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var state: AppState
    @ObservedObject private var heatmap: UsageHeatmapModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var slowLoading = false
    /// 今日活跃小时 ≤ 2 时默认展示脉冲面板；用户可临时切到 24 小时柱图查看。
    @State private var forceTodayBarChart = false

    init(state: AppState) {
        self.state = state
        self._heatmap = ObservedObject(wrappedValue: state.heatmap)
    }

    private var yi: Bool { state.prefs.unitYi }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gridSpacing) {
                if let error = state.dataError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                switch quotaPosition {
                case .left:
                    AdaptiveLeadingFixedLayout(leadingWidth: 300, minTrailingWidth: 480, spacing: Metrics.gridSpacing) {
                        quotaCard(wide: false)
                        heroCard
                    }
                case .top:
                    quotaCard(wide: true)
                    heroCard
                case .right:
                    AdaptiveSplitLayout(minLeadingWidth: 480, trailingWidth: 300, spacing: Metrics.gridSpacing) {
                        heroCard
                        quotaCard(wide: false)
                    }
                case .bottom, .hidden:
                    heroCard
                }
                UsageHeatmapView(model: heatmap, yi: yi)
                AdaptiveEqualColumnsLayout(minColumnWidth: 250, spacing: Metrics.gridSpacing) {
                    compositionCard
                    agentCard
                    modelCard
                }
                if quotaPosition == .bottom { quotaCard(wide: true) }
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.bottom, Metrics.pagePadding)
            .padding(.top, 10)
            // 热力图从「今天（1 行）」切到「近 7 天（7 行）」时带动下方卡片一起平滑滑动，
            // 避免子视图单独动画造成卡片间距撕裂或短暂重叠；TrendChart 与 HeatmapCanvas 已各自禁帧内插值。
            .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: heatmap.chart?.id)
        }
        // 切换范围时旧数据留在原处，不再整页盖遮罩（那会让窗口闪一下）；
        // 读得慢（超过 0.4 秒）才在顶部浮一个小提示，读失败才盖住内容
        .overlay(alignment: .top) {
            if slowLoading && state.loadedRange != state.range {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("正在读取用量…")).font(.callout)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 10)
                .transition(.opacity)
            }
        }
        .overlay {
            if state.loadedRange != state.range && !state.dataLoading && state.dataError != nil {
                ZStack {
                    Rectangle().fill(.regularMaterial)
                    ContentUnavailableView(L10n.text("用量读取失败，请重新扫描后重试"),
                                           systemImage: "exclamationmark.triangle")
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: slowLoading)
        .task(id: state.dataLoading) {
            guard state.dataLoading else { slowLoading = false; return }
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { slowLoading = true }
        }
        .pageChrome(title: L10n.text("用量概览"))
    }



    /// 实际展示数据的范围（与 dailyRows / statTotal 同步更新，避免切换瞬间标签和柱图 x 轴错位）
    private var displayedRange: String { state.loadedRange ?? state.range }

    private var rangeLabel: String {
        ["day": L10n.text("今天"), "week": L10n.text("近 7 天"), "month": L10n.text("本月"), "all": L10n.text("全部")][displayedRange] ?? displayedRange
    }

    // -------------------------------------------------------- 配额条 ----

    private var quotaPosition: OverviewQuotaPosition {
        OverviewQuotaPosition(rawValue: state.prefs.overviewQuotaPosition) ?? .right
    }

    /// 有官方数据的账号；配额不随时间范围和 Agent 筛选变化。同一账号的多把 API Key 合并为一行。
    private var quotaGroups: [SubscriptionCardGroup] {
        state.subscriptionGroups.filter {
            ($0.primary.snapshot.status == .current || $0.primary.snapshot.status == .stale)
                && !($0.primary.snapshot.windows.isEmpty && $0.primary.snapshot.balances.isEmpty)
        }
    }

    private var unreadableAccounts: Int {
        state.subscriptionCards.filter {
            switch $0.snapshot.status {
            case .signedOut, .expired, .forbidden, .failed: return true
            case .loading, .current, .stale, .unsupported: return false
            }
        }.count
    }

    /// 配额列表：每个账号一行，点一行去账号页看这个账号。
    /// 侧栏位置（左 / 右）纵向排列；页面顶部 / 底部时按宽度自适应多列。
    private func quotaCard(wide: Bool) -> some View {
        let groups = quotaGroups
        let limit = wide ? 12 : 8
        let shown = Array(groups.prefix(limit))
        return VStack(alignment: .leading, spacing: 4) {
            CardHeader(title: L10n.text("配额")) {
                HStack(spacing: 10) {
                    Button { state.selection = .accounts } label: {
                        HStack(spacing: 3) {
                            Text(L10n.text("账号"))
                            Image(systemName: "chevron.right").font(.caption2)
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.link)
                    quotaPositionMenu
                }
            }
            .padding(.bottom, 4)
            if groups.isEmpty && unreadableAccounts == 0 {
                Text(L10n.text("登录或添加 API Key 后，这里会显示官方配额与余额。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if wide {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: Metrics.gridSpacing)],
                          alignment: .leading, spacing: 4) {
                    ForEach(shown) { quotaButton($0) }
                }
            } else {
                ForEach(shown) { quotaButton($0) }
            }
            if groups.count > shown.count || unreadableAccounts > 0 {
                HStack(spacing: 8) {
                    if groups.count > shown.count {
                        Button { state.selection = .accounts } label: {
                            Pill(text: L10n.text("还有 \(groups.count - shown.count) 个账号"), tint: .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    if unreadableAccounts > 0 {
                        Button { state.selection = .accounts } label: {
                            Pill(text: L10n.text("\(unreadableAccounts) 个账号未能读取额度"), tint: .orange)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func quotaButton(_ group: SubscriptionCardGroup) -> some View {
        Button {
            state.accountFocus = group.id
            state.selection = .accounts
        } label: {
            QuotaRow(group: group)
                .padding(.vertical, 5)
                .padding(.horizontal, 6)
                .hoverHighlight()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -6)
    }

    /// 卡片右上角：直接改配额卡片的位置（同一设置也在「设置 › 外观与状态栏」）。
    private var quotaPositionMenu: some View {
        Menu {
            Picker(L10n.text("显示位置"), selection: Binding(
                get: { quotaPosition },
                set: { state.updateSetting(key: "overview_quota_position", value: $0.rawValue) }
            )) {
                ForEach(OverviewQuotaPosition.allCases) { position in
                    Label(position.title, systemImage: position.symbol).tag(position)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "rectangle.3.group")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.text("配额卡片显示位置"))
        .accessibilityLabel(L10n.text("配额卡片显示位置"))
    }

    // -------------------------------------------------------- 首屏大数字 ----

    private var scopeLabel: String {
        var parts = [L10n.text("真实消耗 Tokens"), rangeLabel]
        if let agent = state.agentFilter { parts.append(toolDisplayName(agent)) }
        return parts.joined(separator: " · ")
    }

    private var heroCard: some View {
        let total = state.statTotal
        let unpriced = total.events > 0 && total.unpriced == total.events
        let rawPoints = trendPoints
        let isToday = displayedRange == "day"
        let todayPulseEligible = isToday && TodayTrendBuilder.shouldUsePulsePanel(activeHourPoints: rawPoints)
        let showsTodayPulse = todayPulseEligible && !forceTodayBarChart
        let daySlots = isToday ? TodayTrendBuilder.daySlots(from: rawPoints) : []
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(scopeLabel).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Text(UIFormat.compact(total.tokens, yi: yi))
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .help(total.tokens.formatted(.number))
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: total.tokens)
            HStack(alignment: .top, spacing: 26) {
                kpi(L10n.text("费用合计"), unpriced ? L10n.text("未计价") : UIFormat.cost(total.cost),
                    help: L10n.text("含估算，非订阅账单"))
                kpi(L10n.text("用量记录数"), total.events.formatted(.number))
                kpi(L10n.text("会话"), total.sessions.formatted(.number))
                kpi(L10n.text("缓存命中率"), UIFormat.percent(total.cacheHitRate))
                Spacer(minLength: 0)
                trendLegend
                    .opacity(showsTodayPulse ? 0.45 : 1)
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: total.tokens)
            if rawPoints.isEmpty {
                ContentUnavailableView(L10n.text("暂无数据"), systemImage: "chart.bar.xaxis",
                                       description: Text(L10n.text("点右上角「扫描」")))
                    .frame(height: 220)
            } else if showsTodayPulse {
                TodayPulseView(
                    daySlots: daySlots,
                    activePoints: rawPoints,
                    total: total,
                    yesterdaySameTimeTokens: state.yesterdaySameTimeTokens,
                    sessions: state.sessionRows.map(SessionRowModel.init),
                    yi: yi,
                    onSwitchToBarChart: { forceTodayBarChart = true },
                    onSelectSession: { id in
                        state.selectedSessionID = id
                        state.showSessionDetail()
                    }
                )
            } else {
                let currentHour = Calendar.current.component(.hour, from: Date())
                let badgeOnLeading = currentHour >= 17
                ZStack(alignment: badgeOnLeading ? .topLeading : .topTrailing) {
                    TrendChart(points: isToday ? daySlots : rawPoints,
                               isHourly: isToday,
                               yi: yi,
                               currentTimeLabel: isToday ? TodayTrendBuilder.currentTimeLabel() : nil)
                        .equatable()
                    if todayPulseEligible && forceTodayBarChart {
                        TodayChartModePill(title: L10n.text("切回脉冲面板"), active: true) {
                            forceTodayBarChart = false
                        }
                        .padding(badgeOnLeading ? .leading : .trailing, 46)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .onChange(of: displayedRange) { _, next in
            if next != "day" { forceTodayBarChart = false }
        }
    }

    private func kpi(_ title: String, _ value: String, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
        }
        .help(help ?? "")
        .accessibilityElement(children: .combine)
    }

    // ------------------------------------------------------ Token 构成 ----

    private func tokens(_ kind: TokenKind, in stats: UsageStore.ToolStats) -> Int64 {
        switch kind {
        case .cacheRead: stats.cacheRead
        case .input: stats.input
        case .cacheWrite: stats.cacheWrite
        case .output: stats.output
        }
    }

    private var compositionCard: some View {
        let total = state.statTotal
        let sum = TokenKind.allCases.reduce(Int64(0)) { $0 + tokens($1, in: total) }
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: L10n.text("Token 构成")) {
                Text(rangeLabel).font(.caption).foregroundStyle(.secondary)
            }
            SegmentedBar(
                segments: TokenKind.allCases.map { kind in
                    SegmentedBarSegment(value: Double(tokens(kind, in: total)), color: kind.color, minWidth: 3)
                },
                height: 10
            )
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: sum)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading,
                      spacing: Metrics.gridSpacing) {
                ForEach(TokenKind.allCases) { kind in
                    let value = tokens(kind, in: total)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Circle().fill(kind.color).frame(width: 7, height: 7)
                            Text(kind.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Text(UIFormat.compact(value, yi: yi))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text(UIFormat.share(value, of: sum))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .contentTransition(.numericText())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(value.formatted(.number))
                }
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: sum)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // ------------------------------------------------------ 使用趋势 ----

    /// 每个时间桶跨工具聚合后的用量点（dailyRows 是 分桶×工具 粒度）
    private var trendPoints: [TrendPoint] {
        var order: [String] = []
        var acc: [String: (i: Double, o: Double, cr: Double, cw: Double, c: Double)] = [:]
        for row in state.dailyRows {
            if acc[row.day] == nil {
                order.append(row.day)
                acc[row.day] = (0, 0, 0, 0, 0)
            }
            let a = acc[row.day]!
            acc[row.day] = (a.i + Double(row.stats.input),
                            a.o + Double(row.stats.output),
                            a.cr + Double(row.stats.cacheRead),
                            a.cw + Double(row.stats.cacheWrite),
                            a.c + row.stats.cost)
        }
        return order.map {
            TrendPoint(id: $0, day: $0,
                       input: acc[$0]!.i, output: acc[$0]!.o,
                       cacheRead: acc[$0]!.cr, cacheWrite: acc[$0]!.cw,
                       cost: acc[$0]!.c)
        }
    }

    private var trendLegend: some View {
        HStack(spacing: 12) {
            ForEach(TokenKind.allCases) { kind in
                legendItem(kind.title, color: kind.color, line: false)
            }
            legendItem(L10n.text("成本"), color: .costSeries, line: true)
        }
    }

    private func legendItem(_ name: String, color: Color, line: Bool) -> some View {
        HStack(spacing: 4) {
            if line {
                Capsule().fill(color).frame(width: 10, height: 2)
            } else {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            }
            Text(name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    // ---------------------------------------------------- Agent / 模型 ----

    private func costText(_ stats: UsageStore.ToolStats) -> String {
        stats.events > 0 && stats.unpriced == stats.events
            ? L10n.text("未计价") : UIFormat.cost(stats.cost)
    }

    private var agentCard: some View {
        let rows = state.statRows
        let top = rows.map(\.tokens).max() ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            CardHeader(title: L10n.text("Agent 分布")) {
                Text(rangeLabel).font(.caption).foregroundStyle(.secondary)
            }
            if rows.isEmpty {
                emptyRows
            } else {
                ForEach(rows, id: \.tool) { row in
                    ShareRow(fraction: top > 0 ? Double(row.tokens) / Double(top) : 0,
                             tint: toolColor(row.tool),
                             primary: UIFormat.compact(row.tokens, yi: yi),
                             secondary: costText(row)) {
                        Circle().fill(toolColor(row.tool)).frame(width: 8, height: 8)
                        Text(toolDisplayName(row.tool)).font(.callout).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { state.agentFilter = state.agentFilter == row.tool ? nil : row.tool }
                    .help(state.agentFilter == row.tool ? L10n.text("显示全部 Agent")
                          : L10n.text("只看 \(toolDisplayName(row.tool))"))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var modelCard: some View {
        let rows = Array(state.modelRows.prefix(8))
        let top = rows.map(\.stats.tokens).max() ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            CardHeader(title: L10n.text("模型榜")) {
                if state.modelRows.count > rows.count {
                    Text(L10n.text("前 \(rows.count) / 共 \(state.modelRows.count)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if rows.isEmpty {
                emptyRows
            } else {
                ForEach(rows) { row in
                    ShareRow(fraction: top > 0 ? Double(row.stats.tokens) / Double(top) : 0,
                             tint: toolColor(row.tool),
                             primary: UIFormat.compact(row.stats.tokens, yi: yi),
                             secondary: costText(row.stats)) {
                        Circle().fill(toolColor(row.tool)).frame(width: 8, height: 8)
                        Text(row.model.isEmpty ? L10n.text("（未知模型）") : row.model)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help("\(toolDisplayName(row.tool)) · \(row.model)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var emptyRows: some View {
        Text(L10n.text("暂无数据"))
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 60)
    }
}

/// 概览页「配额」卡片的位置（settings.json `overview_quota_position`）。
enum OverviewQuotaPosition: String, CaseIterable, Identifiable {
    case right, left, top, bottom, hidden
    var id: String { rawValue }

    var title: String {
        switch self {
        case .right: L10n.text("主图右侧")
        case .left: L10n.text("主图左侧")
        case .top: L10n.text("页面顶部")
        case .bottom: L10n.text("页面底部")
        case .hidden: L10n.text("不显示")
        }
    }

    var symbol: String {
        switch self {
        case .right: "rectangle.righthalf.filled"
        case .left: "rectangle.lefthalf.filled"
        case .top: "rectangle.tophalf.filled"
        case .bottom: "rectangle.bottomhalf.filled"
        case .hidden: "eye.slash"
        }
    }
}

/// 概览配额列表里的一个账号：名称 + 最紧窗口的占用条与重置时间，或余额。
private struct QuotaRow: View {
    let group: SubscriptionCardGroup
    private var card: SubscriptionCard { group.primary }

    private var tightest: SubscriptionWindow? {
        card.snapshot.windows.filter { $0.usedPercent != nil }
            .max { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) }
    }

    var body: some View {
        let stale = card.snapshot.status == .stale
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(providerColor(card.account.provider)).frame(width: 7, height: 7)
                Text(card.account.provider.displayName).font(.callout.weight(.medium)).lineLimit(1)
                if stale {
                    Text(SubscriptionText.status(.stale)).font(.caption2).foregroundStyle(.orange)
                }
                Spacer(minLength: 6)
                if let tightest {
                    Text(SubscriptionText.percent(tightest.usedPercent ?? 0))
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(quotaColor(tightest.usedPercent))
                } else if let balance = card.snapshot.balances.first {
                    Text(SubscriptionText.money(balance.total, currency: balance.currency))
                        .font(.callout.monospacedDigit().weight(.semibold))
                }
            }
            if let tightest {
                MeterBar(fraction: (tightest.usedPercent ?? 0) / 100,
                         tint: quotaColor(tightest.usedPercent).opacity(stale ? 0.5 : 1), height: 4)
                Text(SubscriptionText.window(tightest)
                     + (tightest.resetsAt.map { " · " + L10n.text("\(L10n.Template(verbatim: SubscriptionText.time($0, relative: true))) 重置") } ?? ""))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            } else {
                Text(SubscriptionText.account(group))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        // 未能刷新时悬停说明原因（如网络超时），避免误以为登录失效。
        .help(stale ? (SubscriptionText.problem(card.snapshot, autoDiscovered: card.account.isAutoDiscovered)
                       ?? SubscriptionText.account(group))
              : SubscriptionText.account(group))
        .accessibilityElement(children: .combine)
    }
}

/// 配额圆环（卡片版）：轨道 + 填充角
struct RingView: View {
    @ObservedObject private var language = LanguageManager.shared
    let pct: Double?
    let role: String
    let hasData: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(ringColor.opacity(hasData ? 0.22 : 1), lineWidth: hasData ? 5 : 1.5)
            if let pct, hasData {
                Circle()
                    .trim(from: 0, to: max(0, min(1, pct / 100)))
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text(pct.map { String(format: "%.0f", $0) } ?? "—")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(hasData ? .primary : .tertiary)
        }
    }

    private var ringColor: Color {
        guard hasData else { return Color.secondary.opacity(0.5) }
        switch role {
        case "quota_crit": return .red
        case "quota_warn": return .orange
        default: return .green
        }
    }
}
