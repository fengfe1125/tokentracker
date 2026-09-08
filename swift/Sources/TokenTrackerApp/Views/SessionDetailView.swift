//
//  SessionDetailView.swift
//  TokenTrackerApp
//
//  会话详情：分区卡片（会话信息 / 继续会话 / 按模型分解 / 观察区间）。
//  住在独立的浮动面板里（SessionDetailWindowController），不再是挤占
//  表格宽度的 inspector —— 那样一展开列表就被压得看不全。
//

import AppKit
import SwiftUI
import TokenTrackerCore

struct SessionDetailView: View {
    @ObservedObject var state: AppState
    @State private var detail: UsageStore.SessionDetail?

    private var yi: Bool { (state.settings["unit_yi"] as? NSNumber)?.boolValue ?? false }

    private var session: SessionRowModel? {
        guard let id = state.selectedSessionID else { return nil }
        return state.sessionRows.map(SessionRowModel.init).first { $0.id == id }
    }

    var body: some View {
        Group {
            if let session {
                content(session)
            } else {
                ContentUnavailableView("未选中会话", systemImage: "sidebar.right",
                                       description: Text("在会话记录里点一行"))
            }
        }
        .frame(minWidth: 320, minHeight: 260)
        .task(id: state.selectedSessionID) {
            detail = nil
            guard let session else { return }
            let loaded = await state.sessionDetail(tool: session.tool,
                                                   sessionID: session.sessionID)
            guard state.selectedSessionID == session.id else { return }  // 选中已变，丢弃迟到结果
            detail = loaded
        }
    }

    private func content(_ session: SessionRowModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(session.title)
                    .font(.headline)
                    .textSelection(.enabled)
                DetailCard(title: "会话信息") {
                    LabeledLine(label: "工具") {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(toolColor(session.tool))
                                .frame(width: 7, height: 7)
                            Text(session.toolName)
                        }
                    }
                    LabeledLine(label: "时间") {
                        Text([session.dateText, session.timeText]
                            .compactMap { $0 }.joined(separator: " "))
                            .monospacedDigit()
                    }
                    LabeledLine(label: "会话 ID") {
                        Text(session.sessionID)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    LabeledLine(label: "模型") {
                        Text(session.model.isEmpty ? "—" : session.model)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    if !session.project.isEmpty {
                        LabeledLine(label: "项目") {
                            Text(session.project)
                                .lineLimit(2)
                                .truncationMode(.head)
                                .textSelection(.enabled)
                        }
                        // claude 的 project 是 slug 不是路径，点了不会有反应，
                        // 与其留个死按钮不如不显示（真实目录在「继续会话」的命令里）
                        if FileManager.default.fileExists(atPath: session.project) {
                            Button {
                                NSWorkspace.shared.open(URL(fileURLWithPath: session.project))
                            } label: {
                                Label("在 Finder 中打开", systemImage: "folder")
                                    .font(.callout)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                ResumeSection(session: session, state: state)
                if let detail {
                    if !detail.activitySummary.isEmpty {
                        DetailCard(title: "工具与 Skill 摘要") {
                            ForEach(Array(detail.activitySummary.enumerated()), id: \.offset) { index, row in
                                if index > 0 { Divider() }
                                HStack(spacing: 8) {
                                    Text(row.name)
                                        .font(.callout)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(row.calls) 次")
                                        .font(.callout.monospacedDigit())
                                    if row.derived > 0 {
                                        Text("推断 \(row.derived)")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    } else {
                                        Text("已确认")
                                            .font(.caption2)
                                            .foregroundStyle(.green)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    DetailCard(title: "按模型分解") {
                        ForEach(Array(detail.models.enumerated()), id: \.element.model) { i, model in
                            if i > 0 { Divider() }   // 只加在行间，末行下面不留悬空线
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(model.model.isEmpty ? "（未知）" : model.model)
                                        .font(.callout)
                                        .lineLimit(1)
                                        .truncationMode(.head)
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
                            .padding(.vertical, 2)
                        }
                    }
                    if !detail.observationIntervals.isEmpty {
                        DetailCard(title: "观察区间（按观测时间估算）") {
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
                        DetailCard(title: "最近 Tool / Skill 活动") {
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
                                    Text(event.confidence == "exact" ? "已确认" : "推断")
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
        ["success": "成功", "error": "错误", "denied": "拒绝", "unknown": "未知"][status]
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
        .padding(12)
        .background(Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 详情里的「标签 : 值」一行
private struct LabeledLine<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 48, alignment: .leading)
            content()
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 继续会话：终端恢复（目录已移动时改选；失败复制命令到剪贴板）。
/// 对齐 resume.py：DSH 无 CLI 不支持恢复。
private struct ResumeSection: View {
    let session: SessionRowModel
    let state: AppState

    /// info() 会遍历 ~/.claude/projects 解析 jsonl + 查 CLI 路径，只能在后台算一次，
    /// 早先它是 computed property，每次 body 求值都重跑一遍（选中/hover/刷新都触发）。
    @State private var info: Resume.ResumeInfo?
    @State private var busy = false
    @State private var notice = ""

    private var terminalPref: String {
        state.settings["terminal_app"] as? String ?? "auto"
    }

    var body: some View {
        DetailCard(title: "继续会话") {
            if busy && info == nil {
                ProgressView().controlSize(.small)
            } else if let info, info.ok {
                Text(info.command)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    Button("▶ 在终端继续") { run(override: nil) }
                        .disabled(busy)
                    if info.cwdMissing {
                        Button("改选目录…") { pickDirectory() }
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
                    Text("这个会话刚活动过。Codex 不允许恢复仍在运行的会话"
                         + "（终端会提示 already has an active writer），"
                         + "先关掉那个窗口再试。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if let info {
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
        .task(id: session.id) {
            notice = ""
            await reload()
        }
    }

    /// 两种成因分开说：目录曾经记下过但没了，和压根没记下过
    /// （codex 有大量空 project，hermes 的 project 干脆不是路径）。
    private var cwdMissingHint: String {
        session.project.hasPrefix("/") || session.project.hasPrefix("-")
            ? "原项目目录已不在（移动或删除），可直接恢复（不 cd）或改选目录"
            : "这个会话没有记录可用的项目目录，会在终端的默认目录恢复，可改选目录"
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
            notice = await Task.detached(priority: .userInitiated) { () -> String in
                let resume = Resume()
                var command = fallback
                if let override {
                    let (cmd, _) = resume.shellLine(tool, sid, project, cwdOverride: override)
                    if let cmd { command = cmd }
                }
                if resume.openTerminal(command, pref: pref) { return "已在终端打开" }
                if resume.copyToClipboard(command) { return "终端打开失败，命令已复制到剪贴板" }
                return "终端打开失败"
            }.value
            busy = false
            if override != nil { await reload() }   // 改过目录，命令要跟着更新
        }
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "选择项目目录"
        if panel.runModal() == .OK, let url = panel.url {
            run(override: url.path)
        }
    }
}
