import SwiftUI
import TokenTrackerCore

@MainActor
struct ActivityView: View, @MainActor Equatable {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var state: ActivityPageState
    let refresh: () -> Void
    let openDetail: () -> Void

    private var snapshot: ActivityDashboardSnapshot { state.snapshot }
    private var exactCalls: Int64 { snapshot.exactRows.reduce(0) { $0 + $1.calls } }
    private var derivedCalls: Int64 { snapshot.derivedRows.reduce(0) { $0 + $1.calls } }
    private var exactSkillCalls: Int64 { snapshot.exactSkillRows.reduce(0) { $0 + $1.calls } }
    private var observedSkillCalls: Int64 { snapshot.skillRows.reduce(0) { $0 + $1.calls } }
    private var failures: Int64 {
        snapshot.exactRows.reduce(0) { $0 + $1.errors + $1.denied }
    }
    private var unknownResults: Int64 { snapshot.exactRows.reduce(0) { $0 + $1.unknown } }
    private var selectedSkillCapability: ActivityCapability? {
        state.agent.map { activityCapability(agent: $0, category: "skills") }
    }
    private var unknownSkillAgentCount: Int {
        snapshot.skillCoverage.values.filter {
            $0.capability == .unknown || $0.capability == .unavailable
        }.count
    }
    private var visibleTimelineRows: ArraySlice<ActivityEvent> { snapshot.timelineRows.prefix(30) }

    static func == (lhs: ActivityView, rhs: ActivityView) -> Bool {
        lhs.state === rhs.state
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: L10n.text("Agent 活动"), subtitle: L10n.text("工具与 Skill 使用 · 仅保存活动元数据")) {
                filters
            }
            List {
                evidenceNotice
                    .activityListRow()
                metrics
                    .activityListRow()
                skillCoverageCard
                    .activityListRow()
                HStack(alignment: .top, spacing: 12) {
                    rankingCard(title: L10n.text("工具榜"), rows: snapshot.toolRows, skill: false)
                    rankingCard(title: L10n.text("Skill 榜"), rows: snapshot.skillRows, skill: true)
                }
                .activityListRow()
                matrixCard
                    .activityListRow()
                timelineHeader
                    .activityListRow(bottom: 2)
                if snapshot.timelineRows.isEmpty {
                    ContentUnavailableView(L10n.text("暂无活动"), systemImage: "clock")
                        .frame(height: 130)
                        .activityTimelineListRow(bottom: 12)
                } else {
                    ForEach(visibleTimelineRows, id: \.srcKey) { event in
                        ActivityTimelineRow(event: event)
                            .activityTimelineListRow(
                                bottom: event.srcKey == visibleTimelineRows.last?.srcKey ? 12 : 2)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(L10n.text("Agent 活动"))
        .onChange(of: state.range) { _, _ in refresh() }
        .onChange(of: state.agent) { _, _ in refresh() }
        .onChange(of: state.confidence) { _, _ in refresh() }
    }

    private var filters: some View {
        HStack(spacing: 8) {
            Picker(L10n.text("范围"), selection: $state.range) {
                Text(L10n.text("今天")).tag("day")
                Text(L10n.text("最近 7 天")).tag("week")
                Text(L10n.text("本月")).tag("month")
                Text(L10n.text("全部")).tag("all")
            }
            .labelsHidden()
            .frame(width: 96)
            Picker("Agent", selection: $state.agent) {
                Text(L10n.text("全部 Agent")).tag(String?.none)
                ForEach(ScannerRegistry.all, id: \.self) { agent in
                    Text(toolDisplayName(agent)).tag(Optional(agent))
                }
            }
            .labelsHidden()
            .frame(width: 118)
            Picker(L10n.text("证据"), selection: $state.confidence) {
                Text(L10n.text("包含推断")).tag("all")
                Text(L10n.text("只看已确认")).tag("exact")
                Text(L10n.text("只看推断")).tag("derived")
            }
            .labelsHidden()
            .frame(width: 118)
        }
    }

    private var evidenceNotice: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "shield.lefthalf.filled")
                if derivedCalls > 0 {
                    Text(L10n.text("有 \(derivedCalls) 次保守推断，始终与 \(exactCalls) 次确认调用分开。"))
                } else {
                    Text(L10n.text("当前范围没有推断调用；确认数据不会混入推断结果。"))
                }
            }
            Spacer()
            if let last = snapshot.lastScan, last.done {
                Text(L10n.text("最近扫描：Token +\(last.added) · 活动 +\(last.activityAdded) / 补全 \(last.activityUpdated)"))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
    }

    private var metrics: some View {
        let values: [(String, String, String, Color)] = [
                    (L10n.text("已确认活动"), "\(exactCalls)", L10n.text("来自 \(snapshot.exactRows.count) 个 Agent"), .green),
            (L10n.text("推断调用"), "\(derivedCalls)", L10n.text("不计入确认总数"), .orange),
            (L10n.text("Skill 使用"), selectedSkillCapability == .unknown || selectedSkillCapability == .unavailable
                ? L10n.text("不可判定") : "\(observedSkillCalls)",
             selectedSkillCapability == .unknown || selectedSkillCapability == .unavailable
                ? L10n.text("该 Agent 没有明确 Skill 事件")
                : L10n.text("确认 \(exactSkillCalls) · 推断 \(max(0, observedSkillCalls - exactSkillCalls))"),
             .primary),
            (L10n.text("错误 / 拒绝"), "\(failures)", L10n.text("\(unknownResults) 次结果未知"), .red),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.0).font(.caption).foregroundStyle(.secondary)
                    Text(item.1)
                        .font(.system(size: 25, weight: .semibold, design: .rounded))
                        .foregroundStyle(item.3)
                        .monospacedDigit()
                    Text(item.2).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5))
            }
        }
    }

    private var skillCoverageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.text("Agent × Skill 能力覆盖")).font(.headline)
                Spacer()
                if unknownSkillAgentCount > 0 {
                    Text(L10n.text("\(unknownSkillAgentCount) 个 Agent 无法判定"))
                        .font(.caption2).foregroundStyle(.orange)
                } else {
                    Text(L10n.text("已观测调用与日志能力分开")).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8)], spacing: 8) {
                ForEach(ScannerRegistry.all, id: \.self) { agent in
                    let item = snapshot.skillCoverage[agent]
                    let capability = item?.capability ?? activityCapability(agent: agent, category: "skills")
                    HStack(spacing: 7) {
                        Circle().fill(toolColor(agent)).frame(width: 7, height: 7)
                        Text(toolDisplayName(agent)).font(.callout.weight(.medium))
                        Spacer()
                        if capability == .unknown || capability == .unavailable {
                            Text(activityCapabilityLabel(capability))
                                .font(.caption2).foregroundStyle(.orange)
                        } else {
                            Text(L10n.text("\(item?.calls ?? 0) 次"))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(activityCapabilityLabel(capability))
                                .font(.caption2).foregroundStyle(capability == .derived ? .orange : .green)
                        }
                    }
                    .padding(.horizontal, 9).padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5))
    }

    private func rankingCard(title: String, rows: [UsageStore.ActivitySummaryRow], skill: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if skill && (selectedSkillCapability == .unknown || selectedSkillCapability == .unavailable) {
                    Text(L10n.text("不可判定")).font(.caption2).foregroundStyle(.orange)
                } else {
                    Text(L10n.text("Top \(min(10, rows.count)) / 共 \(rows.count) 项"))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Button(L10n.text("查看全部")) { openDetail() }
                    .buttonStyle(.link).font(.caption)
            }
            if skill && (selectedSkillCapability == .unknown || selectedSkillCapability == .unavailable) {
                ContentUnavailableView(L10n.text("Skill 不可判定"), systemImage: "questionmark.circle",
                                       description: Text(L10n.text("该 Agent 没有明确 Skill 事件，不能显示为 0 次。")))
                    .frame(minHeight: 190)
            } else if rows.isEmpty {
                ContentUnavailableView(L10n.text("暂无活动"), systemImage: "waveform.path.ecg")
                    .frame(minHeight: 190)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(rows.prefix(10), id: \.name) { row in
                        ActivityRankingRow(row: row, skill: skill)
                        Divider()
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5))
    }

    private var matrixCard: some View {
        let agents = ScannerRegistry.all
        let matrix = canonicalMatrix
        let allTools = matrixTools(matrix)
        let tools = Array(allTools.prefix(7))
        let maximum = max(1, agents.flatMap { agent in tools.map { matrix[agent]?[$0] ?? 0 } }.max() ?? 1)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.text("Agent × 工具矩阵")).font(.headline)
                Spacer()
                Text(L10n.text("Top \(tools.count) / 共 \(allTools.count) · 颜色越深，调用越多"))
                    .font(.caption2).foregroundStyle(.tertiary)
                Button(L10n.text("查看全部")) { openDetail() }
                    .buttonStyle(.link).font(.caption)
            }
            if tools.isEmpty {
                ContentUnavailableView(L10n.text("暂无矩阵数据"), systemImage: "square.grid.3x3")
                    .frame(height: 150)
            } else {
                ScrollView(.horizontal) {
                    Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                        GridRow {
                            Color.clear.frame(width: 112, height: 20)
                            ForEach(tools, id: \.self) { tool in
                                Text(tool).font(.caption2).foregroundStyle(.tertiary)
                                    .lineLimit(1).frame(width: 78)
                            }
                        }
                        ForEach(agents, id: \.self) { agent in
                            GridRow {
                                HStack(spacing: 6) {
                                    Circle().fill(toolColor(agent)).frame(width: 7, height: 7)
                                    Text(toolDisplayName(agent)).font(.caption).lineLimit(1)
                                    Spacer()
                                }.frame(width: 112)
                                ForEach(tools, id: \.self) { tool in
                                    let count = matrix[agent]?[tool] ?? 0
                                    Text(count == 0 ? "—" : "\(count)")
                                        .font(.caption.monospacedDigit().weight(count == maximum ? .semibold : .regular))
                                        .frame(width: 78, height: 30)
                                        .background(heatColor(count: count, maximum: maximum),
                                                    in: RoundedRectangle(cornerRadius: 7))
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5))
    }

    private var timelineHeader: some View {
        HStack {
            Text(L10n.text("最近活动")).font(.headline)
            Spacer()
            Text(L10n.text("最近 \(visibleTimelineRows.count) 条预览 · 当前已载入 \(snapshot.timelineRows.count) 条"))
                .font(.caption2).foregroundStyle(.tertiary)
            Button(L10n.text("打开完整详情")) { openDetail() }
                .buttonStyle(.link).font(.caption)
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5))
    }

    private var canonicalMatrix: [String: [String: Int64]] {
        Dictionary(uniqueKeysWithValues: ScannerRegistry.all.map { agent in
            let rows = snapshot.matrixRows[agent] ?? []
            return (agent, Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0.calls) }))
        })
    }

    private func matrixTools(_ matrix: [String: [String: Int64]]) -> [String] {
        var totals: [String: Int64] = [:]
        for values in matrix.values { for (tool, count) in values { totals[tool, default: 0] += count } }
        return totals.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map(\.key)
    }

    private func heatColor(count: Int64, maximum: Int64) -> Color {
        guard count > 0 else { return Color.secondary.opacity(0.06) }
        return Color.green.opacity(0.10 + 0.58 * Double(count) / Double(maximum))
    }
}

private struct ActivityListRowModifier: ViewModifier {
    let top: CGFloat
    let bottom: CGFloat

    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(top: top, leading: 20, bottom: bottom, trailing: 20))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

private extension View {
    func activityListRow(top: CGFloat = 8, bottom: CGFloat = 8) -> some View {
        modifier(ActivityListRowModifier(top: top, bottom: bottom))
    }

    func activityTimelineListRow(bottom: CGFloat) -> some View {
        padding(.horizontal, 14)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.10), lineWidth: 0.5))
            .activityListRow(top: 2, bottom: bottom)
    }
}

private struct ActivityRankingRow: View {
    @ObservedObject private var language = LanguageManager.shared
    let row: UsageStore.ActivitySummaryRow
    let skill: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(skill ? L10n.text("最近 \(activityRelativeTime(row.lastUsed))") : activityStatusText(row))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            Text("\(row.calls)").font(.callout.monospacedDigit())
            Text(L10n.text("\(row.sessions) 会话")).font(.caption2).foregroundStyle(.secondary)
            EvidencePill(exact: row.exact, derived: row.derived)
        }
        .padding(.vertical, 7)
    }
}

private struct ActivityTimelineRow: View {
    @ObservedObject private var language = LanguageManager.shared
    let event: ActivityEvent

    var body: some View {
        HStack(spacing: 9) {
            Text(activityRelativeTime(event.startedAt ?? event.endedAt ?? 0))
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 66, alignment: .leading)
            Circle().fill(toolColor(event.agent)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.skillName.isEmpty ? event.rawName : "Skill · \(event.skillName)")
                    .font(.callout.weight(.medium))
                let duration = event.durationMs.map { " · \($0)ms" } ?? ""
                let fallback = event.eventLayer == .requestFallback ? L10n.text(" · 未确认执行") : ""
                Text("\(activityKindLabel(event.eventKind)) · \(toolDisplayName(event.agent)) · "
                     + "\(activityStatusLabel(event.status))\(duration)\(fallback)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            EvidencePill(exact: event.confidence == "exact" ? 1 : 0,
                         derived: event.confidence == "derived" ? 1 : 0)
        }
        .padding(.vertical, 5)
    }
}

struct EvidencePill: View {
    @ObservedObject private var language = LanguageManager.shared
    let exact: Int64
    let derived: Int64

    var body: some View {
        HStack(spacing: 3) {
            if exact > 0 { pill(L10n.text("已确认"), color: .green) }
            if derived > 0 { pill(L10n.text("推断"), color: .orange) }
        }
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.09), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.55), lineWidth: 0.7))
    }
}

private func activityStatusText(_ row: UsageStore.ActivitySummaryRow) -> String {
    L10n.text("成功 \(row.success) · 错误 \(row.errors) · 拒绝 \(row.denied) · 未知 \(row.unknown)")
}

func activityStatusLabel(_ status: String) -> String {
    ["success": L10n.text("成功"), "error": L10n.text("错误"), "denied": L10n.text("拒绝"), "unknown": L10n.text("未知")][status] ?? status
}

private func activityKindLabel(_ kind: ActivityKind) -> String {
    switch kind {
    case .tool: return "Tool"
    case .skill: return "Skill"
    case .agent: return "Agent"
    }
}

func activityCapabilityLabel(_ capability: ActivityCapability) -> String {
    switch capability {
    case .exact: return L10n.text("已确认")
    case .derived: return L10n.text("可推断")
    case .unknown: return L10n.text("未知")
    case .unavailable: return L10n.text("不可用")
    }
}

private func activityRelativeTime(_ ms: Int64) -> String {
    guard ms > 0 else { return "—" }
    let seconds = max(0, Int(Date().timeIntervalSince1970 - Double(ms) / 1000))
    if seconds < 60 { return L10n.text("刚刚") }
    if seconds < 3600 { return L10n.text("\(seconds / 60) 分钟前") }
    if seconds < 86_400 { return L10n.text("\(seconds / 3600) 小时前") }
    return L10n.text("\(seconds / 86_400) 天前")
}
