//
//  ReportsView.swift
//  TokenTrackerApp
//
//  本地周报：左侧按周选择，右侧为该周快照（汇总、与上周对比、项目投入、
//  模型与费用依据、预算与生成时健康）。生成与导出在窗口工具栏。
//

import SwiftUI
import TokenTrackerCore

struct ReportsView: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var model: InsightsModel
    @Environment(\.unitYi) private var yi
    @State private var selectedID: String?
    @State private var week = Date()
    @State private var showGenerate = false
    @State private var reportExportQuery: UsageQuery?
    @State private var showExport = false

    private var report: WeeklyReport? {
        model.reports.first { $0.id == selectedID } ?? model.reports.first
    }

    var body: some View {
        Group {
            if model.reports.isEmpty {
                ContentUnavailableView {
                    Label(L10n.text("尚无周报"), systemImage: "doc.text")
                } description: {
                    Text(L10n.text("启动扫描完成后自动生成最近一个完整周，也可以按需生成。"))
                } actions: {
                    Button(L10n.text("生成周报")) { generate(for: Date()) }
                }
            } else {
                HStack(spacing: 0) {
                    weekList
                    Divider()
                    ScrollView {
                        if let report { detail(report) }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle(L10n.text("本地周报"))
        .navigationSubtitle(report.map(weekLabel) ?? "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showGenerate = true } label: {
                    Label(L10n.text("生成周报"), systemImage: "plus")
                }
                .help(L10n.text("生成周报"))
                .popover(isPresented: $showGenerate, arrowEdge: .bottom) { generatePopover }
                Menu {
                    Button(L10n.text("导出 Markdown")) { if let report { model.exportReport(report) } }
                    Button(L10n.text("导出数据")) {
                        reportExportQuery = report?.query ?? UsageQuery.period("week")
                        showExport = true
                    }
                } label: {
                    Label(L10n.text("导出"), systemImage: "square.and.arrow.up")
                }
                .disabled(report == nil)
                .help(L10n.text("导出"))
            }
        }
        .onAppear { model.refresh() }
        .sheet(isPresented: $showExport) { ExportSheet(model: model, queryOverride: reportExportQuery) }
    }

    private func generate(for date: Date) {
        selectedID = nil
        model.mutate { try $0.generateWeeklyReport(now: date, regenerate: true) }
    }

    private var generatePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("生成周报")).font(.headline)
            Text(L10n.text("选择任意一天，生成它之前最近的一个完整自然周。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DatePicker(L10n.text("周次参考日期"), selection: $week, in: ...Date(),
                       displayedComponents: .date)
            HStack {
                Spacer()
                Button(L10n.text("取消")) { showGenerate = false }
                Button(L10n.text("生成此前完整周")) {
                    generate(for: week)
                    showGenerate = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    // ------------------------------------------------------------ 周列表 ----

    private func dates(_ report: WeeklyReport) -> (start: Date, lastDay: Date, zone: TimeZone) {
        let zone = TimeZone(identifier: report.query.timeZoneID) ?? .current
        let start = Date(timeIntervalSince1970: Double(report.query.start ?? 0) / 1000)
        // end 是下一周一 00:00（半开区间），减 1 秒落回周日
        let lastDay = Date(timeIntervalSince1970: Double(report.query.end ?? 0) / 1000 - 1)
        return (start, lastDay, zone)
    }

    /// "11月2日 – 11月8日"（按报告自己的时区）
    private func weekLabel(_ report: WeeklyReport) -> String {
        let (start, lastDay, zone) = dates(report)
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: start) + " – " + formatter.string(from: lastDay)
    }

    private func year(_ report: WeeklyReport) -> String {
        let (start, _, zone) = dates(report)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return String(calendar.component(.year, from: start))
    }

    private var weekList: some View {
        List(selection: Binding(get: { report?.id }, set: { selectedID = $0 })) {
            ForEach(model.reports) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(weekLabel(item))
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(year(item) + " · " + UIFormat.compact(item.totals.tokens, yi: yi)
                         + " · " + UIFormat.costLabel(item.totals))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 3)
                .tag(item.id)
            }
        }
        .listStyle(.inset)
        .frame(width: 180)
    }

    // -------------------------------------------------------------- 详情 ----

    private func detail(_ report: WeeklyReport) -> some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(weekLabel(report) + " · " + year(report))
                        .font(.title3.weight(.semibold))
                    Text(L10n.text("自然周：周一至周日 · 本地规则 · 快照不会随补扫静默变化"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    let now = Date(timeIntervalSince1970: Double(report.query.end ?? 0) / 1000 + 3600)
                    let zone = TimeZone(identifier: report.query.timeZoneID) ?? .current
                    model.mutate { try $0.generateWeeklyReport(now: now, timeZone: zone, regenerate: true) }
                } label: {
                    Label(L10n.text("重新生成"), systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
            TotalsView(totals: report.totals)
            changeCard(report)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Metrics.sectionSpacing) {
                    projectsCard(report).frame(minWidth: 280)
                    modelsCard(report).frame(minWidth: 280)
                }
                VStack(spacing: Metrics.sectionSpacing) {
                    projectsCard(report)
                    modelsCard(report)
                }
            }
            healthCard(report)
            Text(L10n.text("时区：\(report.query.timeZoneID) · 规则 v\(report.ruleVersion) · 生成于 \(Date(timeIntervalSince1970: Double(report.generatedAt) / 1000).formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)))"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(Metrics.pagePadding)
    }

    private func changeCard(_ report: WeeklyReport) -> some View {
        let delta = report.totals.tokens - report.previous.tokens
        let percent: String? = report.previous.tokens > 0
            ? String(format: "%+.0f%%", Double(delta) / Double(report.previous.tokens) * 100) : nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: delta > 0 ? "arrow.up.right" : delta < 0 ? "arrow.down.right" : "equal")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(L10n.text("相比上一自然周：\(UIFormat.signedCompact(delta, yi: yi)) Token"))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let percent {
                    Text(percent)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(L10n.text("上一周 \(UIFormat.compact(report.previous.tokens, yi: yi))"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(L10n.text("覆盖不完整时，变化不代表实际增长。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func projectsCard(_ report: WeeklyReport) -> some View {
        let rows = Array(report.projects.prefix(10))
        let top = rows.map(\.totals.tokens).max() ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            CardHeader(title: L10n.text("项目投入")) {
                if report.projects.count > rows.count {
                    Text(L10n.text("前 \(rows.count) / 共 \(report.projects.count)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if rows.isEmpty { emptyRows }
            ForEach(rows) { project in
                ShareRow(fraction: top > 0 ? Double(project.totals.tokens) / Double(top) : 0,
                         tint: .accentColor,
                         primary: UIFormat.compact(project.totals.tokens, yi: yi),
                         secondary: UIFormat.costLabel(project.totals)) {
                    Text(projectDisplayName(project)).font(.callout).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func modelsCard(_ report: WeeklyReport) -> some View {
        let rows = Array(report.models.prefix(10))
        let top = rows.map(\.totals.tokens).max() ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            CardHeader(title: L10n.text("模型与费用依据")) {
                if report.models.count > rows.count {
                    Text(L10n.text("前 \(rows.count) / 共 \(report.models.count)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if rows.isEmpty { emptyRows }
            ForEach(rows) { row in
                ShareRow(fraction: top > 0 ? Double(row.totals.tokens) / Double(top) : 0,
                         tint: .indigo,
                         primary: UIFormat.compact(row.totals.tokens, yi: yi),
                         secondary: UIFormat.costLabel(row.totals)) {
                    Text(row.id.isEmpty ? L10n.text("（未知模型）") : row.id)
                        .font(.callout).lineLimit(1).truncationMode(.middle)
                }
            }
            if !report.costSources.isEmpty {
                Divider().padding(.vertical, 4)
                ForEach(report.costSources) { row in
                    HStack {
                        Text(costSourceName(row.id))
                        Spacer(minLength: 8)
                        Text(UIFormat.costLabel(row.totals)).monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func healthCard(_ report: WeeklyReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(title: L10n.text("预算与生成时健康"))
            ForEach(report.budgets) { risk in
                Label(L10n.label(risk.title) + " · " + UIFormat.riskDetail(risk),
                      systemImage: risk.level > 0 ? "exclamationmark.triangle" : "gauge.with.needle")
                    .font(.caption)
                    .foregroundStyle(risk.level > 0 ? .orange : .secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], spacing: 8) {
                ForEach(report.health) { health in
                    HStack(spacing: 7) {
                        Circle().fill(toolColor(health.id)).frame(width: 7, height: 7)
                        Text(toolDisplayName(health.id)).font(.callout).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(L10n.label(health.state))
                            .font(.caption)
                            .foregroundStyle(health.state == "正常" ? .green : .orange)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 7)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            Text(L10n.text("执行活动 \(report.activityCount.formatted()) 次；调用成功不代表任务质量。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var emptyRows: some View {
        Text(L10n.text("暂无数据"))
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 50)
    }
}
