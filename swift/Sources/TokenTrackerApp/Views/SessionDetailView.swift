//
//  SessionDetailView.swift
//  TokenTrackerApp
//
//  会话详情：分区卡片（会话信息 / 继续会话 / 按模型分解 / 观察区间）。
//  从会话表下钻进入的页面（原先是独立浮动面板），不再是挤占
//  表格宽度的 inspector —— 那样一展开列表就被压得看不全。
//

import AppKit
import SwiftUI
import TokenTrackerCore

struct SessionDetailView: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var state: AppState
    @State private var detail: UsageStore.SessionDetail?

    private var yi: Bool { state.prefs.unitYi }

    private var session: SessionRowModel? {
        guard let id = state.selectedSessionID else { return nil }
        return state.sessionRows.first { "\($0.tool)|\($0.sessionID)" == id }.map(SessionRowModel.init)
    }

    var body: some View {
        Group {
            if let session {
                Group {
                    if state.sessionDetailTab == "timeline" {
                        SessionTimelineView(state: state, tool: session.tool, sessionID: session.sessionID)
                            .padding(Metrics.pagePadding)
                    } else if state.sessionDetailTab == "conversation" {
                        SessionTranscriptView(
                            session: session,
                            filePath: (detail?.filePath.isEmpty == false ? detail?.filePath : nil) ?? session.filePath,
                            pathResolved: detail != nil,
                            metadata: transcriptMetadata(session))
                    } else {
                        content(session)
                    }
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            } else {
                ContentUnavailableView(L10n.text("未选中会话"), systemImage: "sidebar.right",
                                       description: Text(L10n.text("在会话记录里点一行")))
            }
        }
        .pageChrome(title: session?.title ?? L10n.text("会话详情"),
                    subtitle: session.map { toolDisplayName($0.tool) + " · " + $0.folderShort } ?? "") {
            HStack(spacing: 8) {
                SegmentedPillPicker(
                    accessibilityTitle: L10n.text("详情"),
                    selection: $state.sessionDetailTab,
                    options: [
                        SegmentedOption(value: "overview", title: L10n.text("概览")),
                        SegmentedOption(value: "conversation", title: L10n.text("对话")),
                        SegmentedOption(value: "timeline", title: L10n.text("执行时间线")),
                    ]
                )
                PageActionDivider()
                // 不用回到列表也能连续翻看
                HStack(spacing: 2) {
                    Button { state.stepSession(by: -1) } label: {
                        Label(L10n.text("上一个会话"), systemImage: "chevron.up")
                    }
                    .disabled(!state.canStepSession(by: -1))
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .help(L10n.text("上一个会话"))
                    Button { state.stepSession(by: 1) } label: {
                        Label(L10n.text("下一个会话"), systemImage: "chevron.down")
                    }
                    .disabled(!state.canStepSession(by: 1))
                    .keyboardShortcut(.downArrow, modifiers: .command)
                    .help(L10n.text("下一个会话"))
                }
            }
        }
        .task(id: state.selectedSessionID) {
            detail = nil
            guard let session else { return }
            let loaded = await state.sessionDetail(tool: session.tool,
                                                   sessionID: session.sessionID)
            guard state.selectedSessionID == session.id else { return }  // 选中已变，丢弃迟到结果
            detail = loaded
        }
    }

    /// 导出 Markdown 的抬头信息：与「会话信息」卡片同口径
    private func transcriptMetadata(_ session: SessionRowModel) -> TranscriptMarkdown.Metadata {
        let folder = (detail?.workspacePath.isEmpty == false ? detail?.workspacePath : nil) ?? session.workspacePath
        let models: [String] = {
            if let loaded = detail?.models.map(\.model).filter({ !$0.isEmpty }), !loaded.isEmpty { return loaded }
            return session.models
        }()
        let time = UIFormat.sessionTimeRange(firstMs: detail?.firstTs ?? session.firstTs,
                                             lastMs: detail?.lastTs ?? session.row.ts,
                                             fallbackLastSeen: session.row.lastSeen)
        return TranscriptMarkdown.Metadata(
            title: session.title, agentName: toolDisplayName(session.tool), sessionID: session.sessionID,
            workspace: folder, timeRange: time, models: models,
            sourcePath: (detail?.filePath.isEmpty == false ? detail?.filePath : nil) ?? session.filePath)
    }

    private func content(_ session: SessionRowModel) -> some View {
        let effectiveStats = detail?.total ?? session.stats
        let effectiveFolder = (detail?.workspacePath.isEmpty == false ? detail?.workspacePath : nil)
            ?? session.workspacePath
        let effectiveFolderExists = (detail?.workspacePath.isEmpty == false)
            ? (detail?.workspaceExists ?? false) : session.workspaceExists
        let effectiveFile = (detail?.filePath.isEmpty == false ? detail?.filePath : nil)
            ?? session.filePath
        let effectiveFileExists = (detail?.filePath.isEmpty == false)
            ? (detail?.fileExists ?? false) : session.fileExists
        let effectiveModels: [String] = {
            if let loaded = detail?.models.map(\.model).filter({ !$0.isEmpty }), !loaded.isEmpty {
                return loaded
            }
            return session.models
        }()
        let effectiveTime = UIFormat.sessionTimeRange(
            firstMs: detail?.firstTs ?? session.firstTs,
            lastMs: detail?.lastTs ?? session.row.ts,
            fallbackLastSeen: session.row.lastSeen)

        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(session.title)
                    .font(.headline)
                    .textSelection(.enabled)
                DetailCard(title: L10n.text("会话信息")) {
                    SessionMetadataRows(
                        tool: session.tool,
                        timeText: effectiveTime,
                        folderPath: effectiveFolder,
                        folderExists: effectiveFolderExists,
                        fallbackProject: session.project,
                        sessionID: session.sessionID,
                        models: effectiveModels,
                        stats: effectiveStats,
                        filePath: effectiveFile,
                        fileExists: effectiveFileExists,
                        yi: yi,
                        showTool: true,
                        compact: false)
                }
                ResumeSection(session: session, state: state)
                if let detail {
                    if !detail.activitySummary.isEmpty {
                        DetailCard(title: L10n.text("工具与 Skill 摘要")) {
                            ForEach(Array(detail.activitySummary.enumerated()), id: \.offset) { index, row in
                                if index > 0 { Divider() }
                                HStack(spacing: 8) {
                                    Text(row.name)
                                        .font(.callout)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(L10n.text("\(row.calls) 次"))
                                        .font(.callout.monospacedDigit())
                                    if row.derived > 0 {
                                        Text(L10n.text("推断 \(row.derived)"))
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    } else {
                                        Text(L10n.text("已确认"))
                                            .font(.caption2)
                                            .foregroundStyle(.green)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    DetailCard(title: L10n.text("按模型分解")) {
                        ForEach(Array(detail.models.enumerated()), id: \.element.model) { i, model in
                            if i > 0 { Divider() }   // 只加在行间，末行下面不留悬空线
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(model.model.isEmpty ? L10n.text("（未知）") : model.model)
                                        .font(.callout)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                    Spacer()
                                    Text(UIFormat.tokens(model.stats.tokens, yi: yi))
                                        .font(.callout.monospacedDigit())
                                }
                                Text(UIFormat.sessionTokenBreakdown(model.stats, yi: yi)
                                     + " · " + UIFormat.sessionCost(model.stats))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    if !detail.observationIntervals.isEmpty {
                        DetailCard(title: L10n.text("观察区间（按观测时间估算）")) {
                            ForEach(Array(detail.observationIntervals.enumerated()),
                                    id: \.offset) { _, interval in
                                Text("\(UIFormat.dateTime(ms: interval.intervalStart)) → "
                                     + "\(UIFormat.dateTime(ms: interval.ts)) · "
                                     + UIFormat.tokens(interval.tokens, yi: yi))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !detail.activity.isEmpty {
                        DetailCard(title: L10n.text("最近 Tool / Skill 活动")) {
                            ForEach(Array(detail.activity.prefix(40).enumerated()), id: \.offset) { index, event in
                                if index > 0 { Divider() }
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(toolColor(event.agent))
                                        .frame(width: 7, height: 7)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(event.skillName.isEmpty
                                             ? event.rawName : "Skill · \(event.skillName)")
                                            .font(.callout)
                                            .lineLimit(1)
                                        Text("\(activityStatus(event.status)) · "
                                             + UIFormat.dateTime(ms: event.startedAt ?? event.endedAt))
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    Text(event.confidence == "exact" ? L10n.text("已确认") : L10n.text("推断"))
                                        .font(.caption2)
                                        .foregroundStyle(event.confidence == "exact" ? Color.green : Color.orange)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                } else {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
            .padding(14)
        }
    }

    private func activityStatus(_ status: String) -> String {
        ["success": L10n.text("成功"), "error": L10n.text("错误"), "denied": L10n.text("拒绝"), "unknown": L10n.text("未知")][status]
            ?? status
    }
}

/// 分区卡片：标题 + 内容，避免整块详情是一摞裸 VStack。
private struct DetailCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 12)
    }
}

/// 继续会话：终端恢复（目录已移动时改选；失败复制命令到剪贴板）。
/// 对齐 resume.py：DSH 无 CLI 不支持恢复。
private struct ResumeSection: View {
    @ObservedObject private var language = LanguageManager.shared
    let session: SessionRowModel
    let state: AppState

    /// info() 会遍历 ~/.claude/projects 解析 jsonl + 查 CLI 路径，只能在后台算一次，
    /// 早先它是 computed property，每次 body 求值都重跑一遍（选中/hover/刷新都触发）。
    @State private var info: Resume.ResumeInfo?
    @State private var busy = false
    @State private var notice: L10n.Template = ""

    private var terminalPref: String {
        state.prefs.terminalApp
    }

    var body: some View {
        DetailCard(title: L10n.text("继续会话")) {
            if busy && info == nil {
                ProgressView().controlSize(.small)
            } else if let info, info.ok {
                Text(info.command)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    Button(L10n.text("▶ 在终端继续")) { run(override: nil) }
                        .disabled(busy)
                    if info.cwdMissing {
                        Button(L10n.text("改选目录…")) { pickDirectory() }
                            .foregroundStyle(.orange)
                            .disabled(busy)
                    }
                }
                .font(.callout)
                .buttonStyle(.borderless)
                if info.cwdMissing {
                    Text(cwdMissingHint)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if maybeActiveCodex {
                    Text(L10n.text("这个会话刚活动过。Codex 不允许恢复仍在运行的会话")
                         + L10n.text("（终端会提示 already has an active writer），")
                         + L10n.text("先关掉那个窗口再试。"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if let info {
                Text(L10n.label(info.reason))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if !notice.key.isEmpty {
                Text(L10n.text(notice))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: session.id) {
            notice = ""
            await reload()
        }
    }

    /// 两种成因分开说：目录曾经记下过但没了，和压根没记下过
    /// （codex 有大量空 project，hermes 的 project 干脆不是路径）。
    private var cwdMissingHint: String {
        session.project.hasPrefix("/") || session.project.hasPrefix("-")
            ? L10n.text("原项目目录已不在（移动或删除），可直接恢复（不 cd）或改选目录")
            : L10n.text("这个会话没有记录可用的项目目录，会在终端的默认目录恢复，可改选目录")
    }

    /// 10 分钟内还有事件的 codex 会话大概率仍开着（仅提示，不禁用按钮）
    private var maybeActiveCodex: Bool {
        guard session.tool == "codex", session.sortTs > 0 else { return false }
        return Date().timeIntervalSince1970 * 1000 - Double(session.sortTs) < 10 * 60 * 1000
    }

    private func reload() async {
        busy = true
        let tool = session.tool, sid = session.sessionID, project = session.project
        info = await Task.detached(priority: .userInitiated) {
            Resume().info(tool, sid, project)
        }.value
        busy = false
    }

    /// 打开终端会同步等 osascript 退出（Terminal 冷启动能等上一两秒），
    /// 一并放后台，别卡住界面。
    private func run(override: String?) {
        guard let current = info, current.ok else { return }
        let tool = session.tool, sid = session.sessionID, project = session.project
        let pref = terminalPref
        let fallback = current.command
        busy = true
        Task {
            notice = await Task.detached(priority: .userInitiated) { () -> L10n.Template in
                let resume = Resume()
                var command = fallback
                if let override {
                    let (cmd, _) = resume.shellLine(tool, sid, project, cwdOverride: override)
                    if let cmd { command = cmd }
                }
                if resume.openTerminal(command, pref: pref) { return L10n.message("已在终端打开") }
                if resume.copyToClipboard(command) { return L10n.message("终端打开失败，命令已复制到剪贴板") }
                return L10n.message("终端打开失败")
            }.value
            busy = false
            if override != nil { await reload() }   // 改过目录，命令要跟着更新
        }
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L10n.text("选择项目目录")
        if panel.runModal() == .OK, let url = panel.url {
            run(override: url.path)
        }
    }
}
