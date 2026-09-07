//
//  SessionsView.swift
//  TokenTrackerApp
//
//  会话记录：可排序表头 + 搜索 + 详情检查器（按模型分解 + 观察区间 +
//  在 Finder 打开项目目录）。继续会话按钮在 Phase 4（resume.py 移植）接入。
//

import AppKit
import SwiftUI
import TokenTrackerCore

struct SessionsView: View {
    @ObservedObject var state: AppState
    let toolFilter: String?

    @State private var sortOrder = [KeyPathComparator(\SessionRowModel.sortTs, order: .reverse)]
    @State private var selectedID: String?
    @State private var detail: UsageStore.SessionDetail?
    @State private var showInspector = false

    private var yi: Bool { (state.settings["unit_yi"] as? NSNumber)?.boolValue ?? false }

    var body: some View {
        VStack(spacing: 0) {
            tableView
        }
        .navigationTitle(toolFilter.map { "\(toolDisplayName($0)) 的会话" } ?? "会话记录")
        .searchable(text: $state.sessionSearch, prompt: "搜索标题 / 项目 / 会话 / 模型")
        .onChange(of: state.sessionSearch) { _, _ in state.refreshData() }
        .onChange(of: selectedID) { _, _ in
            loadDetail()
            if selectedID != nil { showInspector = true }
        }
        .inspector(isPresented: $showInspector) {
            SessionInspector(state: state, detail: detail,
                             session: selectedSession, yi: yi)
        }
    }

    private var rows: [SessionRowModel] {
        state.sessionRows.map(SessionRowModel.init)
    }

    private var sortedRows: [SessionRowModel] {
        rows.sorted(using: sortOrder)
    }

    private var selectedSession: SessionRowModel? {
        rows.first { $0.id == selectedID }
    }

    private var tableView: some View {
        Table(sortedRows, selection: $selectedID, sortOrder: $sortOrder) {
            TableColumn("时间", value: \SessionRowModel.sortTs) { row in
                Text(row.lastSeen ?? "—")
                    .font(.callout)
                    .foregroundStyle(row.lastSeen == nil ? .tertiary : .primary)
            }
            .width(90)
            TableColumn("会话", value: \.title) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.callout)
                        .lineLimit(1)
                    if !row.project.isEmpty {
                        Text(row.project)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }
            TableColumn("工具", value: \.toolName) { row in
                Label(row.toolName, systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
                    .foregroundStyle(toolColor(row.tool))
                    .imageScale(.small)
            }
            .width(70)
            TableColumn("模型", value: \.model) { row in
                Text(row.model)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            TableColumn("Tokens", value: \SessionRowModel.tokens) { row in
                Text(UIFormat.tokens(row.tokens, yi: yi))
                    .font(.callout.monospacedDigit())
            }
            .width(80)
            TableColumn("成本", value: \SessionRowModel.cost) { row in
                Text(UIFormat.cost(row.cost))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(70)
        }
        .contextMenu(forSelectionType: String.self) { selection in
            if let id = selection.first, let row = rows.first(where: { $0.id == id }) {
                Button("在 Finder 中打开项目目录") { openInFinder(row.project) }
                Button("复制会话 ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(row.sessionID, forType: .string)
                }
            }
        }
    }

    private func loadDetail() {
        guard let session = selectedSession else {
            detail = nil
            return
        }
        detail = state.sessionDetail(tool: session.tool, sessionID: session.sessionID)
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
    var model: String { row.model }
    var lastSeen: String? { row.lastSeen?.split(separator: " ").last.map(String.init) }
    var sortTs: Int64 { row.ts ?? 0 }
    var tokens: Int64 { row.stats.tokens }
    var cost: Double { row.stats.cost }
}

/// 继续会话：终端恢复（目录已移动时改选；失败复制命令到剪贴板）。
/// 对齐 resume.py：DSH 无 CLI 不支持恢复。
private struct ResumeSection: View {
    let session: SessionRowModel
    let state: AppState
    @State private var notice = ""

    private var resume: Resume { Resume() }
    private var terminalPref: String {
        state.settings["terminal_app"] as? String ?? "auto"
    }
    private var info: Resume.ResumeInfo {
        resume.info(session.tool, session.sessionID, session.project)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("继续会话")
                .font(.subheadline.weight(.medium))
            if info.ok {
                Text(info.command)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    Button("▶ 在终端继续") { open() }
                    if info.cwdMissing {
                        Button("改选目录…") { pickDirectory() }
                            .foregroundStyle(.orange)
                    }
                }
                .font(.callout)
                .buttonStyle(.borderless)
                if info.cwdMissing {
                    Text("原项目目录已移动，可直接恢复（不 cd）或改选目录")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            } else {
                Text(info.reason)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if !notice.isEmpty {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func open(override: String? = nil) {
        var command = info.command
        if let override {
            let (cmd, _) = resume.shellLine(session.tool, session.sessionID,
                                            session.project, cwdOverride: override)
            if let cmd { command = cmd }
        }
        if resume.openTerminal(command, pref: terminalPref) {
            notice = "已在终端打开"
        } else if resume.copyToClipboard(command) {
            notice = "终端打开失败，命令已复制到剪贴板"
        } else {
            notice = "终端打开失败"
        }
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "选择项目目录"
        if panel.runModal() == .OK, let url = panel.url {
            open(override: url.path)
        }
    }
}
private struct SessionInspector: View {
    let state: AppState
    let detail: UsageStore.SessionDetail?
    let session: SessionRowModel?
    let yi: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let session {
                    Text(session.title)
                        .font(.headline)
                    HStack {
                        Label(session.toolName, systemImage: "circle.fill")
                            .foregroundStyle(toolColor(session.tool))
                            .font(.caption)
                        Text(session.sessionID)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if !session.project.isEmpty {
                        Button {
                            let url = URL(fileURLWithPath: session.project)
                            if FileManager.default.fileExists(atPath: session.project) {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Label("在 Finder 中打开项目目录", systemImage: "folder")
                                .font(.callout)
                        }
                        .buttonStyle(.borderless)
                    }
                    ResumeSection(session: session, state: state)
                }
                if let detail {
                    // 模型分解
                    VStack(alignment: .leading, spacing: 6) {
                        Text("按模型分解")
                            .font(.subheadline.weight(.medium))
                        ForEach(detail.models, id: \.model) { model in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(model.model.isEmpty ? "（未知）" : model.model)
                                        .font(.callout)
                                    Spacer()
                                    Text(UIFormat.tokens(model.stats.tokens, yi: yi))
                                        .font(.callout.monospacedDigit())
                                }
                                Text("输入 \(UIFormat.tokens(model.stats.input, yi: yi)) · "
                                     + "输出 \(UIFormat.tokens(model.stats.output, yi: yi)) · "
                                     + "缓存 \(UIFormat.tokens(model.stats.cacheRead + model.stats.cacheWrite, yi: yi)) · "
                                     + UIFormat.cost(model.stats.cost))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                            Divider()
                        }
                    }
                    // 观察区间（聚合快照工具的估算时间）
                    if !detail.observationIntervals.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("观察区间（按观测时间估算）")
                                .font(.subheadline.weight(.medium))
                            ForEach(Array(detail.observationIntervals.enumerated()), id: \.offset) { _, interval in
                                Text("\(UIFormat.dateTime(ms: interval.intervalStart)) → "
                                     + "\(UIFormat.dateTime(ms: interval.ts)) · "
                                     + UIFormat.tokens(interval.tokens, yi: yi))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .frame(minWidth: 300)
    }
}
