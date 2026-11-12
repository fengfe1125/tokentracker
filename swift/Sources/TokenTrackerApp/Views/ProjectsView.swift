//
//  ProjectsView.swift
//  TokenTrackerApp
//
//  项目：范围筛选 → 汇总指标 → 项目列表（按占比排的行）；
//  点进单个项目后显示变化说明、趋势、Agent / 模型分布和主要会话。
//  搜索、预算、导出与项目管理在窗口工具栏。
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
        .frame(minWidth: 118, maxHeight: .infinity, alignment: .topLeading)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 放得下就一行四块；窄处（如报告页右栏）退成 2×2，数字不被压缩
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Metrics.gridSpacing) { tiles }
                    .fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Metrics.gridSpacing),
                                    GridItem(.flexible(), spacing: Metrics.gridSpacing)],
                          spacing: Metrics.gridSpacing) { tiles }
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

struct ProjectsView: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var model: InsightsModel
    @Environment(\.unitYi) private var yi
    @State private var range = "week"
    @State private var from = Calendar.current.startOfDay(for: Date())
    @State private var to = Date()
    @State private var rename = ""
    @State private var selected: ProjectSummary?
    @State private var showExport = false
    @State private var showBudget = false
    @State private var showAssignments = false
    @State private var showCreate = false
    @State private var showRename = false

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
                    projectList
                }
            }
            .padding(Metrics.pagePadding)
        }
        .navigationTitle(selected?.name ?? L10n.text("项目"))
        .navigationSubtitle(model.backfillProgress)
        .searchable(text: $model.search, placement: .toolbar, prompt: L10n.text("搜索项目"))
        .toolbar {
            if selected != nil {
                ToolbarItem(placement: .navigation) {
                    Button { showAll() } label: {
                        Label(L10n.text("所有项目"), systemImage: "chevron.left")
                    }
                    .help(L10n.text("所有项目"))
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
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
                    if selected != nil {
                        Divider()
                        Button(L10n.text("重命名…")) { showRename = true }
                        Button(L10n.text("调整归属")) { showAssignments = true }
                    }
                } label: {
                    Label(L10n.text("项目管理"), systemImage: "ellipsis.circle")
                }
                .help(L10n.text("项目管理"))
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
        .onChange(of: range) { _, _ in applyRange() }
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

    private func applyRange() {
        var query = UsageQuery.period(range)
        if range == "custom" {
            let calendar = Calendar.current
            query.start = Int64(calendar.startOfDay(for: from).timeIntervalSince1970 * 1000)
            query.end = Int64(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to))!
                .timeIntervalSince1970 * 1000)
        }
        query.projectID = model.query.projectID
        query.tool = model.query.tool
        query.model = model.query.model
        model.query = query
        model.refresh()
    }

    // ------------------------------------------------------------ 筛选 ----

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker(L10n.text("范围"), selection: $range) {
                    Text(L10n.text("今天")).tag("day")
                    Text(L10n.text("近 7 天")).tag("week")
                    Text(L10n.text("本月")).tag("month")
                    Text(L10n.text("全部")).tag("all")
                    Text(L10n.text("自定义")).tag("custom")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if model.busy { ProgressView().controlSize(.small) }
                Spacer(minLength: 8)
                Text(usageIntervalLabel(model.query))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if range == "custom" {
                HStack(spacing: 12) {
                    DatePicker(L10n.text("开始"), selection: $from, displayedComponents: .date)
                    DatePicker(L10n.text("结束（包含当天）"), selection: $to, displayedComponents: .date)
                    Button(L10n.text("应用")) { applyRange() }.disabled(from > to)
                }
                .fixedSize()
            }
            if model.query.tool != nil || model.query.model != nil {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text(L10n.text("筛选：") + (model.query.tool.map(toolDisplayName) ?? model.query.model ?? ""))
                    Button(L10n.text("清除筛选")) {
                        model.query.tool = nil
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
        let top = model.projects.map(\.totals.tokens).max() ?? 0
        if model.projects.isEmpty {
            if !model.busy {
                ContentUnavailableView(L10n.text("此范围暂无项目"), systemImage: "folder",
                                       description: Text(L10n.text("来源没有可靠工作目录的用量会保留在未归属中。")))
                    .frame(maxWidth: .infinity, minHeight: 220)
                    .card()
            }
        } else {
            VStack(spacing: 0) {
                ForEach(Array(model.projects.enumerated()), id: \.element.id) { index, project in
                    if index > 0 { Divider().padding(.leading, Metrics.cardPadding) }
                    Button { open(project) } label: { projectRow(project, top: top) }
                        .buttonStyle(.plain)
                }
                if model.projects.count >= 100 {
                    Divider()
                    Button(L10n.text("加载更多")) { model.refresh(more: true) }
                        .buttonStyle(.link)
                        .padding(10)
                }
            }
            .frame(maxWidth: .infinity)
            .card(padding: 0)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        }
    }

    private func projectRow(_ project: ProjectSummary, top: Int64) -> some View {
        let totals = project.totals
        var subtitle = L10n.text("\(totals.sessions) 个会话")
        if let last = project.lastActivity {
            subtitle += " · " + Date(timeIntervalSince1970: Double(last) / 1000)
                .formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(L10n.locale))
        }
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(risks(for: project.id, activeOnly: true)) { risk in
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
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Metrics.sectionSpacing) {
                breakdownCard(title: L10n.text("Agent 分布"), rows: model.agents, isTool: true)
                    .frame(minWidth: 300)
                breakdownCard(title: L10n.text("模型分布"), rows: model.breakdown, isTool: false)
                    .frame(minWidth: 300)
            }
            VStack(spacing: Metrics.sectionSpacing) {
                breakdownCard(title: L10n.text("Agent 分布"), rows: model.agents, isTool: true)
                breakdownCard(title: L10n.text("模型分布"), rows: model.breakdown, isTool: false)
            }
        }
        sessionsCard
    }

    private var trendCard: some View {
        let top = TrendScale.niceCeiling(Double(model.daily.map(\.totals.tokens).max() ?? 0))
        let labels: [String] = {
            let ids = model.daily.map(\.id)
            guard ids.count > 8 else { return ids }
            return (0..<6).map { ids[$0 * (ids.count - 1) / 5] }
        }()
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: L10n.text("项目趋势")) {
                if model.analyticsLoading { ProgressView().controlSize(.small) }
            }
            if model.daily.isEmpty {
                emptyRows
            } else {
                Chart(model.daily) { row in
                    BarMark(x: .value("day", row.id), y: .value("tokens", Double(row.totals.tokens)),
                            width: .ratio(0.62))
                        .foregroundStyle(Color.accentColor.opacity(0.85))
                }
                .chartYScale(domain: 0...top)
                .chartXAxis {
                    AxisMarks(values: labels) { value in
                        AxisValueLabel {
                            if let day = value.as(String.self) {
                                Text(String(day.suffix(5))).font(.caption2)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: TrendScale.ticks(top: top)) { value in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(TrendScale.tokenLabel(v, yi: yi)).font(.caption2)
                            }
                        }
                    }
                }
                .frame(height: 170)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func breakdownCard(title: String, rows: [UsageBreakdown], isTool: Bool) -> some View {
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
                    ShareRow(fraction: top > 0 ? Double(row.totals.tokens) / Double(top) : 0,
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
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var sessionsCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            CardHeader(title: L10n.text("主要会话"))
                .padding(.horizontal, Metrics.cardPadding)
                .padding(.top, Metrics.cardPadding)
                .padding(.bottom, 4)
            if model.sessions.isEmpty {
                emptyRows.padding(.bottom, Metrics.cardPadding)
            } else {
                ForEach(model.sessions) { session in
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
                }
                Color.clear.frame(height: 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 0)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    private var emptyRows: some View {
        Text(model.analyticsLoading ? L10n.text("正在加载分析…") : L10n.text("暂无数据"))
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 60)
    }
}
