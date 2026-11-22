//
//  SessionsView.swift
//  TokenTrackerApp
//
//  会话记录：工具栏搜索 + 可排序表。
//  单击选中；双击、回车、⌘I 或右键「查看详情」在主窗口里下钻到会话详情。
//

import AppKit
import SwiftUI
import TokenTrackerCore

struct SessionsView: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var state: AppState

    @State private var sortOrder = [KeyPathComparator(\SessionRowModel.sortTs, order: .reverse)]
    /// nil = 本视图还没发过查询（首次 .task 只记账不重查，避免和 RootView 的刷新撞车）
    @State private var lastQueriedSearch: String?
    @State private var cachedSortedRows: [SessionRowModel]

    init(state: AppState) {
        self.state = state
        let initialOrder = [KeyPathComparator(\SessionRowModel.sortTs, order: .reverse)]
        _sortOrder = State(initialValue: initialOrder)
        _cachedSortedRows = State(initialValue: Self.buildSortedRows(state.sessionRows, order: initialOrder))
    }

    private static func buildSortedRows(_ raw: [UsageStore.SessionRow],
                                        order: [KeyPathComparator<SessionRowModel>]) -> [SessionRowModel] {
        let today = UIFormat.todayString
        return raw.map { SessionRowModel(row: $0, today: today) }.sorted(using: order)
    }

    private func rebuildSortedRows() {
        cachedSortedRows = Self.buildSortedRows(state.sessionRows, order: sortOrder)
    }

    private var yi: Bool { state.prefs.unitYi }

    private var title: String {
        state.agentFilter.map { L10n.text("\(toolDisplayName($0)) 的会话") } ?? L10n.text("会话记录")
    }

    private var subtitle: String {
        let n = state.sessionRows.count
        if n >= AppState.sessionLimit { return L10n.text("最近 \(n) 个会话（查询上限）") }
        return state.sessionSearch.isEmpty ? L10n.text("共 \(n) 个会话") : L10n.text("匹配 \(n) 个会话")
    }

    var body: some View {
        VStack(spacing: 0) {
            tableView
            if let selected = selectedRow {
                Divider()
                selectedSessionCard(selected)
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.vertical, 10)
            } else if !cachedSortedRows.isEmpty {
                Divider()
                SessionSummaryDock(rows: cachedSortedRows, yi: yi) { id in
                    state.selectedSessionID = id
                }
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.vertical, 10)
            }
        }
        .pageChrome(title: title, subtitle: subtitle) {
            PageSearchField(text: $state.sessionSearch,
                            prompt: L10n.text("搜索标题 / 项目 / 会话 / 模型"))
                .frame(width: 220)
        }
        .onChange(of: state.sessionRows) { _, _ in rebuildSortedRows() }
        .onChange(of: sortOrder) { _, _ in rebuildSortedRows() }
        .onChange(of: language.locale) { _, _ in rebuildSortedRows() }
        // 搜索防抖：refreshData 连带跑统计、detectAll 和配额（含官方 HTTP），
        // 每敲一个字符跑一次太重
        .task(id: state.sessionSearch) {
            guard let last = lastQueriedSearch else {
                lastQueriedSearch = state.sessionSearch
                return
            }
            guard last != state.sessionSearch else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            lastQueriedSearch = state.sessionSearch
            state.refreshSessions()
        }
        // ⌘I 打开详情面板（对齐「显示简介」的习惯用法）
        .background {
            Button("") { state.showSessionDetail() }
                .keyboardShortcut("i", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
        }
    }

    // ------------------------------------------------------------ 表 ----

    private var sortedRows: [SessionRowModel] {
        cachedSortedRows
    }

    private var selectedRow: SessionRowModel? {
        guard let id = state.selectedSessionID else { return nil }
        return cachedSortedRows.first { $0.id == id }
    }

    private func selectedSessionCard(_ row: SessionRowModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(toolColor(row.tool))
                    .frame(width: 8, height: 8)
                Text(row.toolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("·")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(row.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Button {
                    state.selectedSessionID = row.id
                    state.showSessionDetail()
                } label: {
                    HStack(spacing: 3) {
                        Text(L10n.text("查看详情"))
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button {
                    state.selectedSessionID = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(L10n.text("关闭预览"))
            }
            SessionMetadataRows(
                tool: row.tool,
                timeText: row.fullTimeText,
                folderPath: row.workspacePath,
                folderExists: row.workspaceExists,
                fallbackProject: row.project,
                sessionID: row.sessionID,
                models: row.models,
                stats: row.stats,
                filePath: row.filePath,
                fileExists: row.fileExists,
                yi: yi,
                showTool: false,
                compact: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 12)
    }

    private var tableView: some View {
        Table(sortedRows, selection: $state.selectedSessionID, sortOrder: $sortOrder) {
            TableColumn(L10n.text("时间"), value: \SessionRowModel.sortTs) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.timeText)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(row.hasTime ? .primary : .tertiary)
                    if let date = row.dateText {
                        Text(date)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .help(row.fullTimeText)
            }
            .width(min: 60, ideal: 64, max: 96)
            TableColumn(L10n.text("会话"), value: \.title) { row in
                // 文件夹与会话 ID 并入会话列的副行，表格不再需要横向滚动
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title)
                        .font(.callout)
                        .lineLimit(1)
                    Text(row.sessionSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(row.sessionTooltip)
            }
            .width(min: 140, ideal: 180)
            TableColumn(L10n.text("工具"), value: \.toolName) { row in
                // 只给色点上色，文字保持 primary（整条 Label 染色在深色模式下读不清）
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(toolColor(row.tool))
                            .frame(width: 7, height: 7)
                        Text(row.toolName)
                            .font(.callout)
                            .lineLimit(1)
                    }
                    Text(row.modelShort)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.leading, 13)
                }
                .help(row.modelsText)
            }
            .width(min: 110, ideal: 135, max: 230)
            TableColumn(L10n.text("活动"), value: \SessionRowModel.activityExact) { row in
                VStack(alignment: .trailing, spacing: 1) {
                    Text(L10n.text("\(row.activityExact) 次"))
                        .font(.callout.monospacedDigit())
                    if row.activityDerived > 0 || row.skills > 0 {
                        Text(activitySubtitle(row))
                            .font(.caption2)
                            .foregroundStyle(row.activityDerived > 0 ? .orange : .secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 48, ideal: 54, max: 80)
            TableColumn("Tokens", value: \SessionRowModel.tokens) { row in
                Text(UIFormat.tokens(row.tokens, yi: yi))
                    .font(.callout.monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(UIFormat.sessionTokenBreakdown(row.stats, yi: yi))
            }
            .width(min: 58, ideal: 64, max: 96)
            TableColumn(L10n.text("成本"), value: \SessionRowModel.cost) { row in
                Text(row.costLabel)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(UIFormat.sessionTokenBreakdown(row.stats, yi: yi) + "\n" + row.costLabel)
            }
            .width(min: 54, ideal: 60, max: 92)
            TableColumn(L10n.text("文件")) { row in
                HStack {
                    Spacer(minLength: 0)
                    Button {
                        SessionFileActions.revealFile(row.filePath)
                    } label: {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 12.5))
                            .foregroundStyle(row.fileExists ? Color.secondary : Color.secondary.opacity(0.25))
                    }
                    .buttonStyle(.borderless)
                    .disabled(!row.fileExists)
                    .help(fileButtonHelp(row))
                    Spacer(minLength: 0)
                }
            }
            .width(36)
        }
        .contextMenu(forSelectionType: String.self) { selection in
            if let id = selection.first, let row = cachedSortedRows.first(where: { $0.id == id }) {
                Button(L10n.text("查看详情")) {
                    state.selectedSessionID = id
                    state.showSessionDetail()
                }
                Divider()
                Button(L10n.text("在 Finder 中显示记录文件")) {
                    SessionFileActions.revealFile(row.filePath)
                }
                .disabled(!row.fileExists)
                Button(L10n.text("在 Finder 中打开文件夹")) {
                    SessionFileActions.openFolder(row.workspacePath)
                }
                .disabled(!row.workspaceExists)
                Divider()
                Button(L10n.text("复制会话 ID")) {
                    SessionFileActions.copy(row.sessionID)
                }
                if !row.filePath.isEmpty {
                    Button(L10n.text("复制文件路径")) {
                        SessionFileActions.copy(row.filePath)
                    }
                }
            }
        } primaryAction: { selection in    // primaryAction = 双击
            if let id = selection.first {
                state.selectedSessionID = id
                state.showSessionDetail()
            }
        }
        .overlay {
            if sortedRows.isEmpty {
                ContentUnavailableView(
                    state.sessionSearch.isEmpty ? L10n.text("暂无会话") : L10n.text("没有匹配的会话"),
                    systemImage: state.sessionSearch.isEmpty
                        ? "list.bullet.rectangle" : "magnifyingglass",
                    description: Text(state.sessionSearch.isEmpty
                                      ? L10n.text("换个时间范围，或到概览点「扫描」") : L10n.text("试试清空搜索词")))
            }
        }
    }

    private func fileButtonHelp(_ row: SessionRowModel) -> String {
        if row.filePath.isEmpty { return L10n.text("未找到原记录文件") }
        let path = abbreviateHomePath(row.filePath)
        return row.fileExists
            ? "\(L10n.text("在 Finder 中显示"))\n\(path)"
            : "\(L10n.text("原记录文件已不存在"))\n\(path)"
    }
}

/// Table 需要 Identifiable + Comparable 键路径；包一层模型并预计算展示文本，
/// 避免表格滚动复用行时重复拼接字符串或格式化日期。
struct SessionRowModel: Identifiable {
    let row: UsageStore.SessionRow
    let id: String
    let toolName: String
    let title: String
    let folderShort: String
    let displayFolder: String
    let sessionSubtitle: String
    let sessionTooltip: String
    let models: [String]
    let modelShort: String
    let modelsText: String
    let timeText: String
    let dateText: String?
    let fullTimeText: String
    let costLabel: String

    init(row: UsageStore.SessionRow) {
        self.init(row: row, today: UIFormat.todayString)
    }

    init(row: UsageStore.SessionRow, today: String) {
        self.row = row
        self.id = "\(row.tool)|\(row.sessionID)"
        self.toolName = toolDisplayName(row.tool)

        let resolvedTitle: String
        if let t = row.title, !t.isEmpty {
            resolvedTitle = t
        } else if !row.workspacePath.isEmpty {
            resolvedTitle = (row.workspacePath as NSString).lastPathComponent
        } else {
            resolvedTitle = row.project.isEmpty ? row.sessionID : row.project
        }
        self.title = resolvedTitle

        let resolvedFolderShort: String
        if !row.workspacePath.isEmpty {
            resolvedFolderShort = (row.workspacePath as NSString).lastPathComponent
        } else if row.project.isEmpty {
            resolvedFolderShort = "—"
        } else if row.project.hasPrefix("/") {
            resolvedFolderShort = (row.project as NSString).lastPathComponent
        } else {
            resolvedFolderShort = row.project
        }
        self.folderShort = resolvedFolderShort

        let resolvedDisplayFolder = !row.workspacePath.isEmpty
            ? abbreviateHomePath(row.workspacePath) : row.project
        self.displayFolder = resolvedDisplayFolder

        var subParts: [String] = []
        if resolvedFolderShort != "—" { subParts.append(resolvedFolderShort) }
        if !row.sessionID.isEmpty { subParts.append(row.sessionID) }
        self.sessionSubtitle = subParts.isEmpty ? "—" : subParts.joined(separator: " · ")

        var tipLines = [resolvedTitle]
        if !resolvedDisplayFolder.isEmpty { tipLines.append(resolvedDisplayFolder) }
        if !row.sessionID.isEmpty { tipLines.append(row.sessionID) }
        self.sessionTooltip = tipLines.joined(separator: "\n")

        let filteredModels = row.models.filter { !$0.isEmpty }
        let resolvedModels = !filteredModels.isEmpty ? filteredModels : (row.model.isEmpty ? [] : [row.model])
        self.models = resolvedModels
        if let primary = resolvedModels.first {
            self.modelShort = resolvedModels.count > 1 ? "\(primary) +\(resolvedModels.count - 1)" : primary
        } else {
            self.modelShort = "—"
        }
        self.modelsText = resolvedModels.isEmpty ? "—" : resolvedModels.joined(separator: " · ")

        if let s = row.lastSeen {
            let parts = s.split(separator: " ")
            if parts.count == 2 {
                let d = String(parts[0])
                self.timeText = String(parts[1].prefix(5))
                self.dateText = d == today ? nil : d
            } else {
                self.timeText = "—"
                self.dateText = nil
            }
        } else {
            self.timeText = "—"
            self.dateText = nil
        }

        self.fullTimeText = UIFormat.sessionTimeRange(
            firstMs: row.firstTs, lastMs: row.ts, fallbackLastSeen: row.lastSeen
        )
        self.costLabel = UIFormat.sessionCost(row.stats)
    }

    var tool: String { row.tool }
    var sessionID: String { row.sessionID }
    var project: String { row.project }
    var workspacePath: String { row.workspacePath }
    var workspaceExists: Bool { row.workspaceExists }
    var filePath: String { row.filePath }
    var fileExists: Bool { row.fileExists }
    var stats: UsageStore.ToolStats { row.stats }
    var projectShort: String { folderShort }
    var model: String { row.model }
    var hasTime: Bool { row.lastSeen != nil || (row.ts ?? 0) > 0 }
    var firstTs: Int64? { row.firstTs }
    var sortTs: Int64 { row.ts ?? 0 }
    var activityExact: Int64 { row.activityExact }
    var activityDerived: Int64 { row.activityDerived }
    var skills: Int64 { row.skills }
    var tokens: Int64 { row.stats.tokens }
    var cost: Double { row.stats.cost }
    var isUnpriced: Bool { row.stats.events > 0 && row.stats.unpriced == row.stats.events }
}

private func activitySubtitle(_ row: SessionRowModel) -> String {
    var parts: [String] = []
    if row.activityDerived > 0 { parts.append(L10n.text("推断 \(row.activityDerived)")) }
    if row.skills > 0 { parts.append("Skill \(row.skills)") }
    return parts.joined(separator: " · ")
}
