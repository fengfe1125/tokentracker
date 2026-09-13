import SwiftUI
import TokenTrackerCore

/// Agent Activity 的完整浏览器：独立窗口、稳定游标分页、只读规范化元数据。
@MainActor
struct ActivityDetailView: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var state: AppState

    @State private var range: String
    @State private var agent: String?
    @State private var confidence: String
    @State private var status: String
    @State private var kind: ActivityKind?
    @State private var sessionID = ""
    @State private var query = ""
    @State private var rows: [ActivityEvent] = []
    @State private var skillRows: [UsageStore.ActivitySummaryRow] = []
    @State private var coverage: [String: ActivityAgentCoverage] = [:]
    @State private var nextBefore: Int64?
    @State private var nextBeforeID: Int64?
    @State private var loading = false

    init(state: AppState) {
        self.state = state
        let filter = state.activityPage.filter
        _range = State(initialValue: filter.range)
        _agent = State(initialValue: filter.agent)
        _confidence = State(initialValue: filter.confidence)
        _status = State(initialValue: "all")
        _kind = State(initialValue: nil)
    }

    private var reloadKey: String {
        [range, agent ?? "all", confidence, status, kind?.rawValue ?? "all", sessionID, query]
            .joined(separator: "|")
    }

    private var scopeTitle: String {
        switch kind {
        case .tool: return L10n.text("Tool 全部调用记录")
        case .skill: return L10n.text("Skill 全部调用记录")
        case .agent: return L10n.text("Agent / 子 Agent 关系")
        case nil: return L10n.text("完整时间线")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: L10n.text("Agent 活动详情"), subtitle: L10n.text("完整分页 · metadata-only · 不保存 Prompt、参数、输出或主机路径")) {
                filters
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    skillOverview
                    timeline
                }
                .padding(18)
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .task(id: reloadKey) {
            await reload()
        }
    }

    private var filters: some View {
        HStack(spacing: 7) {
            Picker(L10n.text("范围"), selection: $range) {
                Text(L10n.text("今天")).tag("day")
                Text(L10n.text("最近 7 天")).tag("week")
                Text(L10n.text("本月")).tag("month")
                Text(L10n.text("全部")).tag("all")
            }
            .labelsHidden().frame(width: 92)
            Picker("Agent", selection: $agent) {
                Text(L10n.text("全部 Agent")).tag(String?.none)
                ForEach(ScannerRegistry.all, id: \.self) { name in
                    Text(toolDisplayName(name)).tag(Optional(name))
                }
            }
            .labelsHidden().frame(width: 116)
            Picker(L10n.text("类型"), selection: $kind) {
                Text(L10n.text("全部类型")).tag(ActivityKind?.none)
                Text("Tool").tag(ActivityKind?.some(.tool))
                Text("Skill").tag(ActivityKind?.some(.skill))
                Text("Agent").tag(ActivityKind?.some(.agent))
            }
            .labelsHidden().frame(width: 100)
            Picker(L10n.text("证据"), selection: $confidence) {
                Text(L10n.text("包含推断")).tag("all")
                Text(L10n.text("已确认")).tag("exact")
                Text(L10n.text("只看推断")).tag("derived")
            }
            .labelsHidden().frame(width: 98)
            Picker(L10n.text("状态"), selection: $status) {
                Text(L10n.text("全部状态")).tag("all")
                Text(L10n.text("成功")).tag("success")
                Text(L10n.text("错误")).tag("error")
                Text(L10n.text("拒绝")).tag("denied")
                Text(L10n.text("未知")).tag("unknown")
            }
            .labelsHidden().frame(width: 92)
            TextField("Session ID", text: $sessionID)
                .textFieldStyle(.roundedBorder).frame(width: 130)
            TextField(L10n.text("搜索 Agent / Skill / Tool"), text: $query)
                .textFieldStyle(.roundedBorder).frame(width: 190)
        }
    }

    private var skillOverview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.text("Skill 总览")).font(.headline)
                Spacer()
                Text(L10n.text("共 \(skillRows.count) 个已观测 Skill"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 8)], spacing: 8) {
                ForEach(ScannerRegistry.all, id: \.self) { name in
                    let item = coverage[name]
                    let capability = item?.capability ?? activityCapability(agent: name, category: "skills")
                    HStack(spacing: 8) {
                        Circle().fill(toolColor(name)).frame(width: 8, height: 8)
                        Text(toolDisplayName(name)).font(.callout.weight(.medium))
                        Spacer()
                        if capability == .unknown || capability == .unavailable {
                            Text(activityCapabilityLabel(capability))
                                .font(.caption).foregroundStyle(.orange)
                        } else {
                            Text(L10n.text("\(item?.calls ?? 0) 次"))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(activityCapabilityLabel(capability))
                                .font(.caption).foregroundStyle(capability == .derived ? .orange : .green)
                        }
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            if !skillRows.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("已观测 Skill")).font(.subheadline.weight(.medium))
                    ForEach(skillRows, id: \.name) { row in
                        HStack {
                            Text(row.name)
                            Spacer()
                            Text(L10n.text("\(row.calls) 次 · 确认 \(row.exact) · 推断 \(row.derived)"))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                }
                .padding(.top, 3)
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5))
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(scopeTitle).font(.headline)
                Spacer()
                Text(L10n.text("当前页 \(rows.count) 条"))
                    .font(.caption).foregroundStyle(.secondary)
                if loading { ProgressView().controlSize(.small) }
            }
            if rows.isEmpty && !loading {
                ContentUnavailableView(L10n.text("暂无符合条件的活动"), systemImage: "clock")
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, event in
                        ActivityDetailRow(event: event)
                        Divider()
                    }
                }
                if nextBefore != nil {
                    Button(L10n.text("加载更早 100 条")) {
                        Task { await loadMore() }
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 7)
                } else if !rows.isEmpty {
                    Text(L10n.text("已到达当前筛选条件的最早记录"))
                        .font(.caption).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 5)
                }
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5))
    }

    private func reload() async {
        rows = []
        nextBefore = nil
        nextBeforeID = nil
        loading = true
        async let page = state.activityTimelinePage(
            range: range, agent: agent, sessionID: clean(sessionID), confidence: confidence,
            status: status == "all" ? nil : status,
            limit: 100, before: nil, beforeID: nil, kind: kind, query: clean(query))
        async let loadedCoverage = state.activitySkillCoverage(range: range, agent: agent)
        async let loadedSkills = state.activitySkillSummary(range: range, agent: agent, confidence: "all")
        let result = await (page, loadedCoverage, loadedSkills)
        guard !Task.isCancelled else { return }
        if let page = result.0 {
            rows = page.rows
            nextBefore = page.nextBefore
            nextBeforeID = page.nextBeforeID
        }
        coverage = result.1
        skillRows = result.2
        loading = false
    }

    private func loadMore() async {
        guard !loading, let before = nextBefore else { return }
        loading = true
        let page = await state.activityTimelinePage(
            range: range, agent: agent, sessionID: clean(sessionID), confidence: confidence,
            status: status == "all" ? nil : status,
            limit: 100, before: before, beforeID: nextBeforeID, kind: kind, query: clean(query))
        guard !Task.isCancelled else { return }
        if let page {
            rows.append(contentsOf: page.rows)
            nextBefore = page.nextBefore
            nextBeforeID = page.nextBeforeID
        }
        loading = false
    }

    private func clean(_ value: String) -> String? {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}

private struct ActivityDetailRow: View {
    @ObservedObject private var language = LanguageManager.shared
    let event: ActivityEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(activityDetailDate(event.startedAt ?? event.endedAt))
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 132, alignment: .leading)
            Circle().fill(toolColor(event.agent)).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(event.skillName.isEmpty ? event.rawName : event.skillName)
                        .font(.callout.weight(.medium))
                    Text(activityDetailKind(event.eventKind))
                        .font(.caption2).foregroundStyle(.secondary)
                    if event.eventLayer == .requestFallback {
                        Text(L10n.text("未确认执行"))
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
                HStack(spacing: 7) {
                    Text("Agent: \(toolDisplayName(event.agent))")
                    if !event.sessionID.isEmpty { Text("Session: \(event.sessionID)") }
                    if !event.parentCallID.isEmpty { Text(L10n.text("父调用: \(event.parentCallID)")) }
                    Text(activityStatusLabel(event.status))
                    if let duration = event.durationMs { Text("\(duration)ms") }
                }
                .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            EvidencePill(exact: event.confidence == "exact" ? 1 : 0,
                         derived: event.confidence == "derived" ? 1 : 0)
        }
        .padding(.vertical, 8)
    }
}

private func activityDetailDate(_ ms: Int64?) -> String {
    guard let ms, ms > 0 else { return L10n.text("未知时间") }
    let formatter = DateFormatter()
    formatter.locale = L10n.locale
    formatter.setLocalizedDateFormatFromTemplate("MMMdHHmmss")
    return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
}

private func activityDetailKind(_ kind: ActivityKind) -> String {
    switch kind {
    case .tool: return "Tool"
    case .skill: return "Skill"
    case .agent: return "Agent"
    }
}
