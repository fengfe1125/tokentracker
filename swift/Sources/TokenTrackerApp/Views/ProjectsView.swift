//
//  ProjectsView.swift
//  TokenTrackerApp
//
//  项目：范围筛选 → 汇总指标 → 项目占比与 Token 构成可视化 → 项目列表（按占比排的行）→ Agent / 模型分布；
//  点进单个项目后显示变化说明、趋势、Agent / 模型分布和主要会话。
//  搜索、预算、导出与项目管理在页面栏。
//

import Charts
import SwiftUI
import TokenTrackerCore

/// 汇总指标：四个指标块 + 一行构成 + 一行统计覆盖。项目、报告和数据健康共用。
struct TotalsView: View {
    @ObservedObject private var language = LanguageManager.shared
    @Environment(\.unitYi) private var yi
    let totals: UsageTotals

    private var cacheHitRate: Double? {
        let inputSide = totals.input + totals.cacheRead + totals.cacheWrite
        return inputSide > 0 ? Double(totals.cacheRead) / Double(inputSide) * 100 : nil
    }

    private func compact(_ value: Int64) -> String { UIFormat.compact(value, yi: yi) }

    @ViewBuilder
    private var tiles: some View {
        Group {
            StatTile(title: L10n.text("真实消耗 Tokens"), value: compact(totals.tokens),
                     caption: totals.tokens.formatted(.number))
            StatTile(title: L10n.text("费用合计"), value: UIFormat.costLabel(totals),
                     caption: L10n.text("含估算，非订阅账单"))
            StatTile(title: L10n.text("会话"), value: totals.sessions.formatted(.number),
                     caption: L10n.text("\(totals.records.formatted(.number)) 条用量记录"))
            StatTile(title: L10n.text("缓存命中率"), value: UIFormat.percent(cacheHitRate)) {
                MeterBar(fraction: (cacheHitRate ?? 0) / 100).padding(.top, 5)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 放得下就一行四块；窄处（如报告页右栏）退成 2×2，数字不被压缩
            AdaptiveTileGridLayout(maxColumns: 4, fallbackColumns: 2,
                                   minColumnWidth: 118, spacing: Metrics.gridSpacing) {
                tiles
            }
            Text(L10n.text("非缓存输入 \(compact(totals.input)) · 输出 \(compact(totals.output)) · 缓存读 \(compact(totals.cacheRead)) · 缓存写 \(compact(totals.cacheWrite))"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if totals.unpriced > 0 || totals.unallocatedTokens > 0 {
                Text(L10n.text("未计价 \(totals.unpriced.formatted(.number)) 条 · 时间未分配 \(compact(totals.unallocatedTokens)) Token"))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// 未归属是 Core 给的固定名称，按界面语言显示；用户自己的项目名原样保留。
func projectDisplayName(_ project: ProjectSummary) -> String {
    project.id == "unassigned" ? L10n.text("未归属") : project.name
}

struct ProjectsView: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var model: InsightsModel
    /// 清除自定义日期后，让全局范围重新接管
    var resetRange: () -> Void = {}
    @Environment(\.unitYi) private var yi
    @State private var showCustom = false
    @State private var from = Calendar.current.startOfDay(for: Date())
    @State private var to = Date()
    @State private var rename = ""
    @State private var selected: ProjectSummary?
    @State private var showExport = false
    @State private var showBudget = false
    @State private var showAssignments = false
    @State private var showCreate = false
    @State private var showRename = false
    @State private var donutMetric: UsageChartMetric = .tokens

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                filterBar
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red)
                }
                TotalsView(totals: model.totals)
                if let selected {
                    detail(selected)
                } else {
                    if !model.projects.isEmpty {
                        projectShareCharts
                    }
                    projectList
                    if !model.projects.isEmpty {
                        projectBreakdowns
                    }
                }
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.bottom, Metrics.pagePadding)
            .padding(.top, 10)
        }
        .pageChrome(title: selected.map(projectDisplayName) ?? L10n.text("项目"),
                    subtitle: [selected.map(projectDisplayName), model.backfillProgress]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                    leading: {
            if selected != nil {
                Button { showAll() } label: {
                    Label(L10n.text("所有项目"), systemImage: "chevron.left")
                }
                .buttonStyle(.pageIcon)
                .help(L10n.text("所有项目"))
            }
        }) {
            HStack(spacing: 8) {
                PageSearchField(text: $model.search, prompt: L10n.text("搜索项目"))
                    .frame(width: 144)
                PageActionDivider()
                HStack(spacing: 2) {
                    Button { showBudget = true } label: {
                        Label(L10n.text("预算"), systemImage: "gauge.with.needle")
                    }
                    .help(selected == nil ? L10n.text("全局预算") : L10n.text("项目预算"))
                    Button { showExport = true } label: {
                        Label(L10n.text("导出"), systemImage: "square.and.arrow.up")
                    }
                    .help(L10n.text("导出当前筛选的数据"))
                    Menu {
                        Button(L10n.text("项目管理")) { showCreate = true }
                        Button(L10n.text("自定义日期范围…")) { showCustom = true }
                        if selected != nil {
                            Divider()
                            Button(L10n.text("重命名…")) { showRename = true }
                            Button(L10n.text("调整归属")) { showAssignments = true }
                        }
                    } label: {
                        Label(L10n.text("项目管理"), systemImage: "ellipsis.circle")
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .help(L10n.text("项目管理"))
                }
            }
        }
        .onChange(of: model.busy) { _, busy in
            if !busy, let id = model.query.projectID,
               let project = model.projects.first(where: { $0.id == id }) {
                if selected?.id != id { rename = project.name }
                selected = project
            } else if !busy, model.query.projectID == nil {
                selected = nil
            }
        }
        .task(id: model.search) {
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled { model.refresh() }
        }
        .sheet(isPresented: $showCreate) { ProjectCreateSheet(model: model) }
        .sheet(isPresented: $showExport) { ExportSheet(model: model) }
        .sheet(isPresented: $showBudget) { BudgetSheet(model: model, projectID: selected?.id) }
        .sheet(isPresented: $showAssignments) { AssignmentSheet(model: model, projectID: selected?.id) }
        .alert(L10n.text("项目名称"), isPresented: $showRename) {
            TextField(L10n.text("项目名称"), text: $rename)
            Button(L10n.text("保存名称")) {
                guard let id = selected?.id else { return }
                let name = rename
                model.mutate { try $0.renameProject(id, name: name) }
            }
            Button(L10n.text("取消"), role: .cancel) { rename = selected?.name ?? "" }
        }
    }

    private func showAll() {
        selected = nil
        model.query.projectID = nil
        model.refresh()
    }

    private func open(_ project: ProjectSummary) {
        selected = project
        rename = project.name
        model.query.projectID = project.id
        model.refresh()
    }

    private func applyCustomRange() {
        let calendar = Calendar.current
        model.query.start = Int64(calendar.startOfDay(for: from).timeIntervalSince1970 * 1000)
        model.query.end = Int64(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to))!
            .timeIntervalSince1970 * 1000)
        model.customRange = true
        model.refresh()
    }

    private func clearCustomRange() {
        showCustom = false
        model.customRange = false
        resetRange()
    }

    // ------------------------------------------------------------ 筛选 ----

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "calendar").foregroundStyle(.secondary)
                Text(usageIntervalLabel(model.query))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if model.customRange {
                    Button(L10n.text("恢复全局范围")) { clearCustomRange() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                Spacer(minLength: 0)
                // 固定占位：加载转圈出现、消失时这一行不变高
                ProgressView().controlSize(.small)
                    .opacity(model.busy ? 1 : 0)
            }
            .frame(height: 18)
            if showCustom || model.customRange {
                HStack(spacing: 12) {
                    DatePicker(L10n.text("开始"), selection: $from, displayedComponents: .date)
                    DatePicker(L10n.text("结束（包含当天）"), selection: $to, displayedComponents: .date)
                    Button(L10n.text("应用")) { applyCustomRange() }.disabled(from > to)
                    if !model.customRange {
                        Button(L10n.text("取消")) { showCustom = false }
                    }
                }
                .fixedSize()
            }
            if model.query.model != nil {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text(L10n.text("筛选：") + (model.query.model ?? ""))
                    Button(L10n.text("清除筛选")) {
                        model.query.model = nil
                        model.refresh()
                    }
                    .buttonStyle(.link)
                }
                .font(.caption)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.1), in: Capsule())
            }
        }
    }

    // -------------------------------------------------------- 项目列表 ----

    private func risks(for projectID: String, activeOnly: Bool) -> [RiskNotice] {
        model.risks.filter { $0.projectID == projectID && (!activeOnly || $0.level > 0) }
    }

    @ViewBuilder
    private var projectList: some View {
        let projects = model.projects
        let top = projects.map(\.totals.tokens).max() ?? 0
        if projects.isEmpty {
            if !model.busy {
                ContentUnavailableView(L10n.text("此范围暂无项目"), systemImage: "folder",
                                       description: Text(L10n.text("来源没有可靠工作目录的用量会保留在未归属中。")))
                    .frame(maxWidth: .infinity, minHeight: 220)
                    .card()
            }
        } else {
            let hasLoadMore = projects.count >= 100
            let risksByProject = Dictionary(
                grouping: model.risks.filter { $0.level > 0 && $0.projectID != nil },
                by: { $0.projectID! }
            )
            LazyVStack(spacing: 0) {
                ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
                    let isFirst = index == 0
                    let isLast = !hasLoadMore && index == projects.count - 1
                    VStack(spacing: 0) {
                        if index > 0 { Divider().padding(.leading, Metrics.cardPadding) }
                        Button { open(project) } label: {
                            ProjectListRow(
                                project: project,
                                top: top,
                                activeRisks: risksByProject[project.id] ?? [],
                                yi: yi,
                                locale: language.locale
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .background(CardListRowBackground(isFirst: isFirst, isLast: isLast))
                    .modifier(CardListRowClip(isFirst: isFirst, isLast: isLast))
                }
                if hasLoadMore {
                    VStack(spacing: 0) {
                        Divider()
                        Button(L10n.text("加载更多")) { model.refresh(more: true) }
                            .buttonStyle(.link)
                            .padding(10)
                            .frame(maxWidth: .infinity)
                    }
                    .background(CardListRowBackground(isFirst: false, isLast: true))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // -------------------------------------------------------- 项目可视化 ----

    @ViewBuilder
    private var projectShareCharts: some View {
        let donutData = UsageChartBuilder.projectDonut(projects: model.projects, metric: donutMetric)
        let mixItems = UsageChartBuilder.projectMix(projects: model.projects)
        let activeProjectCount = model.projects.filter { $0.totals.tokens > 0 }.count
        let openByID: (String) -> Void = { id in
            if let project = model.projects.first(where: { $0.id == id }) {
                open(project)
            }
        }

        AdaptiveEqualColumnsLayout(minColumnWidth: 420, spacing: Metrics.sectionSpacing, equalHeight: true) {
            UsageDonutCard(
                title: L10n.text("项目占比"),
                centerSubtitle: L10n.text("\(donutData.itemCount) 个项目"),
                data: donutData,
                metric: $donutMetric,
                yi: yi,
                onSelect: openByID
            )
            TokenMixBarCard(
                title: L10n.text("项目 Token 构成"),
                items: mixItems,
                totalCount: activeProjectCount,
                yi: yi,
                onSelect: openByID
            )
        }
    }

    @ViewBuilder
    private var projectBreakdowns: some View {
        let filterModel: (String) -> Void = { modelName in
            model.query.model = model.query.model == modelName ? nil : modelName
            model.refresh()
        }

        // 搜索项目名时隐藏全局 Agent / 模型卡片，避免和已筛选的项目列表口径混在一起
        if model.search.isEmpty && (!model.agents.isEmpty || !model.breakdown.isEmpty) {
            AdaptiveEqualColumnsLayout(minColumnWidth: 300, spacing: Metrics.sectionSpacing, equalHeight: true) {
                breakdownCard(title: L10n.text("Agent 分布"), rows: model.agents, isTool: true)
                breakdownCard(title: L10n.text("模型分布"), rows: model.breakdown, isTool: false,
                              onSelect: filterModel)
            }
        }
    }

    // -------------------------------------------------------- 项目详情 ----

    @ViewBuilder
    private func detail(_ project: ProjectSummary) -> some View {
        let notices = risks(for: project.id, activeOnly: false)
        if model.explanation != nil || !notices.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                // 有比较结论时直接用结论做标题，避免「消耗变化 / 消耗变化」重复
                CardHeader(title: model.explanation.map { L10n.label($0.status) } ?? L10n.text("消耗变化")) {
                    if model.analyticsLoading { ProgressView().controlSize(.small) }
                }
                ForEach(notices) { risk in
                    Label(UIFormat.riskDetail(risk),
                          systemImage: risk.level > 0 ? "exclamationmark.triangle" : "gauge.with.needle")
                        .font(.caption)
                        .foregroundStyle(risk.level > 0 ? .orange : .secondary)
                }
                if let explanation = model.explanation {
                    Text(UIFormat.explanation(explanation))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup(L10n.text("查看比较依据")) {
                        ExplanationEvidence(explanation: explanation, inspect: model.inspectChange)
                            .padding(.top, 4)
                    }
                    .font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
        trendCard
        AdaptiveEqualColumnsLayout(minColumnWidth: 300, spacing: Metrics.sectionSpacing, equalHeight: true) {
            breakdownCard(title: L10n.text("Agent 分布"), rows: model.agents, isTool: true)
            breakdownCard(title: L10n.text("模型分布"), rows: model.breakdown, isTool: false)
        }
        sessionsCard
    }

    private var trendCard: some View {
        let points: [TrendPoint] = model.daily.map { row in
            let pricedCost = (row.totals.records > 0 && row.totals.unpriced == row.totals.records) ? 0 : row.totals.cost
            return TrendPoint(
                id: row.id,
                day: row.id,
                input: Double(row.totals.input),
                output: Double(row.totals.output),
                cacheRead: Double(row.totals.cacheRead),
                cacheWrite: Double(row.totals.cacheWrite),
                cost: pricedCost
            )
        }
        let hasCost = points.contains { $0.cost > 0 }
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: L10n.text("项目趋势")) {
                HStack(spacing: 12) {
                    if !points.isEmpty {
                        ForEach(TokenKind.allCases) { kind in
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 2).fill(kind.color).frame(width: 8, height: 8)
                                Text(kind.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        if hasCost {
                            HStack(spacing: 4) {
                                Capsule().fill(Color.costSeries).frame(width: 10, height: 2)
                                Text(L10n.text("成本")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    if model.analyticsLoading { ProgressView().controlSize(.small) }
                }
            }
            if points.isEmpty {
                emptyRows
            } else {
                TrendChart(points: points, isHourly: false, yi: yi)
                    .equatable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func breakdownCard(title: String, rows: [UsageBreakdown], isTool: Bool,
                               onSelect: ((String) -> Void)? = nil) -> some View {
        let shown = Array(rows.prefix(8))
        let top = shown.map(\.totals.tokens).max() ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            CardHeader(title: title) {
                if rows.count > shown.count {
                    Text(L10n.text("前 \(shown.count) / 共 \(rows.count)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if shown.isEmpty {
                emptyRows
            } else {
                ForEach(shown) { row in
                    let tint = isTool ? toolColor(row.id) : Color.accentColor
                    let rowView = ShareRow(fraction: top > 0 ? Double(row.totals.tokens) / Double(top) : 0,
                                           tint: tint,
                                           primary: UIFormat.compact(row.totals.tokens, yi: yi),
                                           secondary: UIFormat.costLabel(row.totals)) {
                        if isTool { Circle().fill(tint).frame(width: 8, height: 8) }
                        Text(isTool ? toolDisplayName(row.id)
                             : row.id.isEmpty ? L10n.text("（未知模型）") : row.id)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let onSelect, !row.id.isEmpty {
                        Button { onSelect(row.id) } label: {
                            rowView
                                .padding(.horizontal, 6)
                                .hoverHighlight()
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, -6)
                        .help(L10n.text("查看用到这个模型的项目"))
                    } else {
                        rowView
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }

    private var sessionsCard: some View {
        let sessions = model.sessions
        return LazyVStack(alignment: .leading, spacing: 0) {
            CardHeader(title: L10n.text("主要会话"))
                .padding(.horizontal, Metrics.cardPadding)
                .padding(.top, Metrics.cardPadding)
                .padding(.bottom, sessions.isEmpty ? 4 : 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CardListRowBackground(isFirst: true, isLast: false))
            if sessions.isEmpty {
                emptyRows
                    .padding(.bottom, Metrics.cardPadding)
                    .background(CardListRowBackground(isFirst: false, isLast: true))
            } else {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    let isLast = index == sessions.count - 1
                    Button { model.onSession?(session.tool, session.sessionID) } label: {
                        HStack(spacing: 8) {
                            Circle().fill(toolColor(session.tool)).frame(width: 7, height: 7)
                            Text(session.title.isEmpty ? session.sessionID : session.title)
                                .font(.callout)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(UIFormat.compact(session.totals.tokens, yi: yi))
                                .font(.callout.monospacedDigit())
                            Text(UIFormat.costLabel(session.totals))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 64, alignment: .trailing)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, Metrics.cardPadding)
                        .padding(.vertical, 7)
                        .hoverHighlight()
                    }
                    .buttonStyle(.plain)
                    .help(toolDisplayName(session.tool))
                    .padding(.bottom, isLast ? 8 : 0)
                    .background(CardListRowBackground(isFirst: false, isLast: isLast))
                    .modifier(CardListRowClip(isFirst: false, isLast: isLast))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyRows: some View {
        Text(model.analyticsLoading ? L10n.text("正在加载分析…") : L10n.text("暂无数据"))
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 60)
    }
}

private struct ProjectListRow: View, Equatable {
    let project: ProjectSummary
    let top: Int64
    let activeRisks: [RiskNotice]
    let yi: Bool
    let locale: Locale

    nonisolated static func == (lhs: ProjectListRow, rhs: ProjectListRow) -> Bool {
        lhs.project.id == rhs.project.id
            && lhs.project.name == rhs.project.name
            && lhs.project.totals == rhs.project.totals
            && lhs.project.lastActivity == rhs.project.lastActivity
            && lhs.top == rhs.top
            && lhs.activeRisks == rhs.activeRisks
            && lhs.yi == rhs.yi
            && lhs.locale == rhs.locale
    }

    var body: some View {
        let totals = project.totals
        var subtitle = L10n.text("\(totals.sessions) 个会话")
        if let last = project.lastActivity {
            subtitle += " · " + UIFormat.abbreviatedDate(ms: last, locale: locale)
        }
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(projectDisplayName(project))
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(activeRisks) { risk in
                    Label(UIFormat.riskDetail(risk), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                MeterBar(fraction: top > 0 ? Double(totals.tokens) / Double(top) : 0,
                         tint: .accentColor, height: 3)
                    .padding(.top, 2)
                Text(L10n.text("输入 \(UIFormat.compact(totals.input, yi: yi)) · 输出 \(UIFormat.compact(totals.output, yi: yi)) · 缓存读 \(UIFormat.compact(totals.cacheRead, yi: yi)) · 缓存写 \(UIFormat.compact(totals.cacheWrite, yi: yi))"))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            VStack(alignment: .trailing, spacing: 3) {
                Text(UIFormat.compact(totals.tokens, yi: yi))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(UIFormat.costLabel(totals))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 76, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Metrics.cardPadding)
        .padding(.vertical, 11)
        .hoverHighlight()
        .help(totals.tokens.formatted(.number) + " Token")
    }
}
