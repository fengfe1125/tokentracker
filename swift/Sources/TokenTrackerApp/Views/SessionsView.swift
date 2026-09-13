//
//  SessionsView.swift
//  TokenTrackerApp
//
//  会话记录：固定顶栏（标题 + 搜索）+ 可排序表。
//  详情走独立浮动面板（SessionDetailWindowController），不再挤占表格宽度。
//

import AppKit
import SwiftUI
import TokenTrackerCore

struct SessionsView: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var state: AppState
    let toolFilter: String?

    @State private var sortOrder = [KeyPathComparator(\SessionRowModel.sortTs, order: .reverse)]
    /// nil = 本视图还没发过查询（首次 .task 只记账不重查，避免和 RootView 的刷新撞车）
    @State private var lastQueriedSearch: String?

    private var yi: Bool { (state.settings["unit_yi"] as? NSNumber)?.boolValue ?? false }

    private var title: String {
        toolFilter.map { L10n.text("\(toolDisplayName($0)) 的会话") } ?? L10n.text("会话记录")
    }

    private var subtitle: String {
        let n = state.sessionRows.count
        if n >= AppState.sessionLimit { return L10n.text("最近 \(n) 个会话（查询上限）") }
        return state.sessionSearch.isEmpty ? L10n.text("共 \(n) 个会话") : L10n.text("匹配 \(n) 个会话")
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: title, subtitle: subtitle) { searchField }
            tableView
        }
        .navigationTitle(title)
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
        .onChange(of: state.selectedSessionID) { _, _ in state.autoShowSessionDetail() }
        // ⌘I 打开详情面板（对齐「显示简介」的习惯用法）
        .background {
            Button("") { state.showSessionDetail() }
                .keyboardShortcut("i", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
        }
    }

    // ------------------------------------------------------------ 搜索 ----

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.tertiary)
            TextField(L10n.text("搜索标题 / 项目 / 会话 / 模型"), text: $state.sessionSearch)
                .textFieldStyle(.plain)
                .frame(width: 210)
            if !state.sessionSearch.isEmpty {
                Button {
                    state.sessionSearch = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    // ------------------------------------------------------------ 表 ----

    private var rows: [SessionRowModel] {
        state.sessionRows.map(SessionRowModel.init)
    }

    private var sortedRows: [SessionRowModel] {
        rows.sorted(using: sortOrder)
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
            }
            .width(min: 76, ideal: 84)
            TableColumn(L10n.text("会话"), value: \.title) { row in
                Text(row.title)
                    .font(.callout)
                    .lineLimit(1)
            }
            .width(min: 140, ideal: 240)
            TableColumn(L10n.text("项目"), value: \.projectShort) { row in
                Text(row.projectShort)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(row.project)
            }
            .width(min: 90, ideal: 150)
            TableColumn(L10n.text("工具"), value: \.toolName) { row in
                // 只给色点上色，文字保持 primary（整条 Label 染色在深色模式下读不清）
                HStack(spacing: 6) {
                    Circle()
                        .fill(toolColor(row.tool))
                        .frame(width: 7, height: 7)
                    Text(row.toolName)
                        .font(.callout)
                        .lineLimit(1)
                }
            }
            .width(min: 84, ideal: 96)
            TableColumn(L10n.text("模型"), value: \.model) { row in
                Text(row.model)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .width(min: 90, ideal: 150)
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
            .width(min: 76, ideal: 92)
            TableColumn("Tokens", value: \SessionRowModel.tokens) { row in
                Text(UIFormat.tokens(row.tokens, yi: yi))
                    .font(.callout.monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 78, ideal: 90)
            TableColumn(L10n.text("成本"), value: \SessionRowModel.cost) { row in
                Text(UIFormat.cost(row.cost))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 66, ideal: 76)
        }
        .contextMenu(forSelectionType: String.self) { selection in
            if let id = selection.first, let row = rows.first(where: { $0.id == id }) {
                Button(L10n.text("查看详情")) {
                    state.selectedSessionID = id
                    state.showSessionDetail()
                }
                Divider()
                Button(L10n.text("在 Finder 中打开项目目录")) { openInFinder(row.project) }
                Button(L10n.text("复制会话 ID")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(row.sessionID, forType: .string)
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

    private func openInFinder(_ project: String) {
        guard !project.isEmpty else { return }
        let url = URL(fileURLWithPath: project)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: project, isDirectory: &isDir) {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Table 需要 Identifiable + Comparable 键路径；包一层模型。
struct SessionRowModel: Identifiable {
    let row: UsageStore.SessionRow
    var id: String { "\(row.tool)|\(row.sessionID)" }
    var tool: String { row.tool }
    var sessionID: String { row.sessionID }
    var toolName: String { toolDisplayName(row.tool) }
    var title: String {
        if let title = row.title, !title.isEmpty { return title }
        return row.project.isEmpty ? row.sessionID : row.project
    }
    var project: String { row.project }
    /// 列表里只显示最后一段（完整路径进 tooltip）；claude 的 slug 原样留着
    var projectShort: String {
        guard !row.project.isEmpty else { return "—" }
        guard row.project.hasPrefix("/") else { return row.project }
        return (row.project as NSString).lastPathComponent
    }
    var model: String { row.model }
    var hasTime: Bool { row.lastSeen != nil }

    /// last_seen 是 SQLite datetime()："YYYY-MM-DD HH:MM:SS"
    private var lastSeenParts: (date: String, time: String)? {
        guard let s = row.lastSeen else { return nil }
        let parts = s.split(separator: " ")
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1].prefix(5)))   // 秒对用户没意义
    }
    var timeText: String { lastSeenParts?.time ?? "—" }
    /// 当天的行省略日期（此前整列只留时刻，昨天和上周长得一模一样）
    var dateText: String? {
        guard let date = lastSeenParts?.date, date != UIFormat.todayString else { return nil }
        return date
    }

    var sortTs: Int64 { row.ts ?? 0 }
    var activityExact: Int64 { row.activityExact }
    var activityDerived: Int64 { row.activityDerived }
    var skills: Int64 { row.skills }
    var tokens: Int64 { row.stats.tokens }
    var cost: Double { row.stats.cost }
}

private func activitySubtitle(_ row: SessionRowModel) -> String {
    var parts: [String] = []
    if row.activityDerived > 0 { parts.append(L10n.text("推断 \(row.activityDerived)")) }
    if row.skills > 0 { parts.append("Skill \(row.skills)") }
    return parts.joined(separator: " · ")
}
