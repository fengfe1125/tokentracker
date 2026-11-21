import SwiftUI
import TokenTrackerCore

@MainActor
struct ActivityView: View, @MainActor Equatable {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var state: ActivityPageState
    let refresh: () -> Void
    let openDetail: (ActivityKind?, String?) -> Void

    @State private var showCoverage = false

    private var snapshot: ActivityDashboardSnapshot { state.snapshot }
    private var exactCalls: Int64 { snapshot.exactRows.reduce(0) { $0 + $1.calls } }
    private var derivedCalls: Int64 { snapshot.derivedRows.reduce(0) { $0 + $1.calls } }
    private var exactSkillCalls: Int64 { snapshot.exactSkillRows.reduce(0) { $0 + $1.calls } }
    private var derivedSkillCalls: Int64 { snapshot.derivedSkillRows.reduce(0) { $0 + $1.calls } }
    private var observedSkillCalls: Int64 { snapshot.skillRows.reduce(0) { $0 + $1.calls } }
    private var agentCalls: Int64 { snapshot.agentRows.reduce(0) { $0 + $1.calls } }
    private var activeSummaryRows: [UsageStore.ActivitySummaryRow] {
        switch state.confidence {
        case "derived": return snapshot.derivedRows
        case "all": return snapshot.exactRows + snapshot.derivedRows
        default: return snapshot.exactRows
        }
    }
    private var successCount: Int64 { activeSummaryRows.reduce(0) { $0 + $1.success } }
    private var failureCount: Int64 { activeSummaryRows.reduce(0) { $0 + $1.errors + $1.denied } }
    private var unknownResults: Int64 { activeSummaryRows.reduce(0) { $0 + $1.unknown } }
    private var activeSessions: Int64 { snapshot.exactRows.reduce(0) { $0 + $1.sessions } }
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
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                metrics
                if hasNoActivity {
                    emptyCard
                } else {
                    activityBreakdown
                }
                coverageDisclosure
            }
            .padding(Metrics.pagePadding)
        }
        .pageChrome(title: L10n.text("Agent 活动")) { filters }
        .onChange(of: state.range) { _, _ in refresh() }
        .onChange(of: state.agent) { _, _ in refresh() }
        .onChange(of: state.confidence) { _, _ in refresh() }
    }

    /// 整个范围内没有任何工具、Skill 或时间线记录。
    private var hasNoActivity: Bool {
        snapshot.toolRows.isEmpty && snapshot.skillRows.isEmpty && snapshot.timelineRows.isEmpty
    }

    private var emptyCard: some View {
        ContentUnavailableView {
            Label(L10n.text("此范围暂无活动"), systemImage: "waveform.path.ecg")
        } description: {
            if state.confidence == "exact", derivedCalls > 0 {
                Text(L10n.text("当前范围没有已确认调用，但有 \(derivedCalls) 次推断记录；可切换证据级别查看。"))
            } else {
                Text(L10n.text("换个时间范围或 Agent，或等下一次扫描。"))
            }
        } actions: {
            if state.confidence == "exact", derivedCalls > 0 {
                Button(L10n.text("包含推断查看")) { state.confidence = "all" }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .card()
    }

    @ViewBuilder
    private var activityBreakdown: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Metrics.sectionSpacing) {
                rankingCard(title: L10n.text("工具榜"), rows: snapshot.toolRows, skill: false)
                    .frame(minWidth: 300)
                rankingCard(title: L10n.text("Skill 榜"), rows: snapshot.skillRows, skill: true)
                    .frame(minWidth: 300)
            }
            VStack(spacing: Metrics.sectionSpacing) {
                rankingCard(title: L10n.text("工具榜"), rows: snapshot.toolRows, skill: false)
                rankingCard(title: L10n.text("Skill 榜"), rows: snapshot.skillRows, skill: true)
            }
        }
        matrixCard
        timelineCard
    }

    private var confidenceMeta: (icon: String, label: String, tint: Color?) {
        switch state.confidence {
        case "all":
            return ("line.3.horizontal.decrease.circle", L10n.text("包含推断"), .orange)
        case "derived":
            return ("sparkle.magnifyingglass", L10n.text("只看推断"), .orange)
        default:
            return ("checkmark.shield", L10n.text("已确认"), nil)
        }
    }

    private var filters: some View {
        let meta = confidenceMeta
        return PageMenuPill(activeTint: meta.tint) {
            Image(systemName: meta.icon)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(meta.tint ?? Color.secondary)
            Text(meta.label)
        } content: {
            Picker(L10n.text("证据"), selection: $state.confidence) {
                Text(L10n.text("已确认")).tag("exact")
                Text(L10n.text("包含推断")).tag("all")
                Text(L10n.text("只看推断")).tag("derived")
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .help(L10n.text("筛选活动证据级别"))
    }

    private var successRateText: String {
        let known = successCount + failureCount
        guard known > 0 else { return "—" }
        return String(format: "%.1f%%", Double(successCount) / Double(known) * 100)
    }

    private var successCaption: String {
        let known = successCount + failureCount
        if known == 0 && unknownResults > 0 {
            return L10n.text("\(unknownResults) 次结果未知")
        }
        if unknownResults > 0 {
            return L10n.text("成功 \(successCount) · 失败 \(failureCount) · 未知 \(unknownResults)")
        }
        return L10n.text("成功 \(successCount) · 失败 \(failureCount)")
    }

    private var metrics: some View {
        let primaryTitle: String
        let primaryValue: String
        let primaryCaption: String
        let primaryTint: Color
        if state.confidence == "derived" {
            primaryTitle = L10n.text("推断调用")
            primaryValue = derivedCalls.formatted()
            primaryCaption = L10n.text("不计入确认总数")
            primaryTint = .orange
        } else {
            primaryTitle = L10n.text("已确认调用")
            primaryValue = exactCalls.formatted()
            if state.confidence == "all" && derivedCalls > 0 {
                primaryCaption = L10n.text("来自 \(snapshot.exactRows.count) 个 Agent · 另含 \(derivedCalls) 次推断")
            } else {
                primaryCaption = L10n.text("来自 \(snapshot.exactRows.count) 个 Agent")
            }
            primaryTint = .primary
        }

        let skillUnknown = selectedSkillCapability == .unknown || selectedSkillCapability == .unavailable
        let skillValue: String
        let skillCaption: String
        if skillUnknown {
            skillValue = L10n.text("不可判定")
            skillCaption = L10n.text("该 Agent 没有明确 Skill 事件")
        } else if state.confidence == "exact" {
            skillValue = exactSkillCalls.formatted()
            if derivedSkillCalls > 0 {
                skillCaption = L10n.text("另有 \(derivedSkillCalls) 次路径观测")
            } else {
                skillCaption = L10n.text("共 \(snapshot.exactSkillRows.count) 个 Skill")
            }
        } else {
            skillValue = observedSkillCalls.formatted()
            skillCaption = L10n.text("确认 \(exactSkillCalls) · 推断 \(max(0, observedSkillCalls - exactSkillCalls))")
        }

        let rateTint: Color = failureCount > 0 ? .orange : (successCount > 0 ? .green : .secondary)
        let values: [(String, String, String, Color)] = [
            (primaryTitle, primaryValue, primaryCaption, primaryTint),
            (L10n.text("执行成功率"), successRateText, successCaption, rateTint),
            (L10n.text("Skill 调用"), skillValue, skillCaption, skillUnknown ? .orange : .primary),
            (L10n.text("子 Agent 调用"), agentCalls.formatted(),
             L10n.text("活跃会话 \(activeSessions) 个"), .primary),
        ]
        return HStack(alignment: .top, spacing: Metrics.gridSpacing) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, item in
                StatTile(title: item.0, value: item.1, caption: item.2, tint: item.3)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func rankingCard(title: String, rows: [UsageStore.ActivitySummaryRow], skill: Bool) -> some View {
        let top = rows.prefix(10)
        let maxCalls = top.map(\.calls).max() ?? 1
        let skillUnknown = skill && (selectedSkillCapability == .unknown || selectedSkillCapability == .unavailable)
        return VStack(alignment: .leading, spacing: 8) {
            CardHeader(title: title) {
                HStack(spacing: 8) {
                    if skillUnknown {
                        Text(L10n.text("不可判定")).font(.caption2).foregroundStyle(.orange)
                    } else if !rows.isEmpty {
                        Text(L10n.text("前 \(min(10, rows.count)) / 共 \(rows.count)"))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Button(L10n.text("查看全部")) { openDetail(skill ? .skill : .tool, nil) }
                        .buttonStyle(.link).font(.caption)
                }
            }
            if skillUnknown {
                ContentUnavailableView(L10n.text("Skill 不可判定"), systemImage: "questionmark.circle",
                                       description: Text(L10n.text("该 Agent 没有明确 Skill 事件，不能显示为 0 次。")))
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else if rows.isEmpty {
                VStack(spacing: 8) {
                    ContentUnavailableView(L10n.text("暂无活动"), systemImage: "waveform.path.ecg")
                        .frame(maxWidth: .infinity, minHeight: 120)
                    if skill && state.confidence == "exact" && derivedSkillCalls > 0 {
                        derivedSkillsNotice
                    }
                }
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(top, id: \.name) { row in
                        Button {
                            openDetail(skill ? .skill : .tool, row.name)
                        } label: {
                            ActivityRankingRow(
                                row: row,
                                fraction: maxCalls > 0 ? Double(row.calls) / Double(maxCalls) : 0,
                                tint: skill ? .indigo : .accentColor,
                                skill: skill
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                if skill && state.confidence == "exact" && derivedSkillCalls > 0 {
                    Divider().padding(.top, 4)
                    derivedSkillsNotice
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var derivedSkillsNotice: some View {
        HStack(spacing: 8) {
            Text(L10n.text("另有 \(derivedSkillCalls) 次从 SKILL.md 路径观测的记录（推断）"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button(L10n.text("包含推断查看")) { state.confidence = "all" }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(.top, 2)
    }

    private var matrixCard: some View {
        let matrix = canonicalMatrix
        let activeAgents = ScannerRegistry.all.filter { agent in
            if let filterAgent = state.agent { return agent == filterAgent }
            return !(matrix[agent]?.isEmpty ?? true)
        }
        let allTools = matrixTools(matrix, agents: activeAgents)
        let tools = Array(allTools.prefix(8))
        let maximum = max(1, activeAgents.flatMap { agent in tools.map { matrix[agent]?[$0] ?? 0 } }.max() ?? 1)
        return VStack(alignment: .leading, spacing: 10) {
            CardHeader(title: L10n.text("Agent × 工具矩阵")) {
                HStack(spacing: 8) {
                    if !tools.isEmpty {
                        Text(L10n.text("前 \(tools.count) / 共 \(allTools.count) 项"))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Button(L10n.text("查看全部")) { openDetail(.tool, nil) }
                        .buttonStyle(.link).font(.caption)
                }
            }
            if tools.isEmpty || activeAgents.isEmpty {
                ContentUnavailableView(L10n.text("暂无矩阵数据"), systemImage: "square.grid.3x3")
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                        GridRow {
                            Color.clear.frame(width: 112, height: 20)
                            ForEach(tools, id: \.self) { tool in
                                Text(tool).font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1).frame(width: 82)
                            }
                        }
                        ForEach(activeAgents, id: \.self) { agent in
                            GridRow {
                                HStack(spacing: 6) {
                                    Circle().fill(toolColor(agent)).frame(width: 7, height: 7)
                                    Text(toolDisplayName(agent)).font(.caption).lineLimit(1)
                                    Spacer()
                                }.frame(width: 112)
                                ForEach(tools, id: \.self) { tool in
                                    let count = matrix[agent]?[tool] ?? 0
                                    Text(count == 0 ? "—" : count.formatted())
                                        .font(.caption.monospacedDigit().weight(count == maximum ? .semibold : .regular))
                                        .foregroundStyle(count == 0 ? .tertiary : .primary)
                                        .frame(width: 82, height: 30)
                                        .background(heatColor(count: count, maximum: maximum),
                                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(title: L10n.text("最近活动")) {
                HStack(spacing: 8) {
                    Text(L10n.text("最近 \(visibleTimelineRows.count) 条 · 已载入 \(snapshot.timelineRows.count) 条"))
                        .font(.caption2).foregroundStyle(.tertiary)
                    Button(L10n.text("打开完整详情")) { openDetail(nil, nil) }
                        .buttonStyle(.link).font(.caption)
                }
            }
            if snapshot.timelineRows.isEmpty {
                ContentUnavailableView(L10n.text("暂无活动"), systemImage: "clock")
                    .frame(maxWidth: .infinity, minHeight: 110)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(visibleTimelineRows.enumerated()), id: \.element.srcKey) { index, event in
                        if index > 0 { Divider() }
                        ActivityTimelineRow(event: event)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var coverageDisclosure: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { showCoverage.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(L10n.text("采集能力与覆盖说明")).font(.subheadline.weight(.medium))
                    if unknownSkillAgentCount > 0 {
                        Text(L10n.text("\(unknownSkillAgentCount) 个 Agent 无法判定 Skill"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showCoverage ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showCoverage {
                VStack(alignment: .leading, spacing: 10) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 195), spacing: 8)], spacing: 8) {
                        ForEach(ScannerRegistry.all, id: \.self) { agent in
                            let item = snapshot.skillCoverage[agent]
                            let capability = item?.capability ?? activityCapability(agent: agent, category: "skills")
                            HStack(spacing: 7) {
                                Circle().fill(toolColor(agent)).frame(width: 7, height: 7)
                                Text(toolDisplayName(agent)).font(.callout.weight(.medium)).lineLimit(1)
                                Spacer(minLength: 4)
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
                            .padding(.horizontal, 9).padding(.vertical, 7)
                            .background(Color.sunkSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                    HStack(spacing: 12) {
                        Text(L10n.text("仅记录工具与 Skill 名称、时间、状态等元数据，不保存提示词、参数或输出正文。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        if let last = snapshot.lastScan, last.done {
                            Text(L10n.text("最近扫描：Token +\(last.added) · 活动 +\(last.activityAdded) / 补全 \(last.activityUpdated)"))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var canonicalMatrix: [String: [String: Int64]] {
        Dictionary(uniqueKeysWithValues: ScannerRegistry.all.map { agent in
            let rows = snapshot.matrixRows[agent] ?? []
            return (agent, Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0.calls) }))
        })
    }

    private func matrixTools(_ matrix: [String: [String: Int64]], agents: [String]) -> [String] {
        var totals: [String: Int64] = [:]
        for agent in agents {
            for (tool, count) in matrix[agent] ?? [:] { totals[tool, default: 0] += count }
        }
        return totals.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map(\.key)
    }

    private func heatColor(count: Int64, maximum: Int64) -> Color {
        guard count > 0 else { return Color.secondary.opacity(0.06) }
        return Color.brand.opacity(0.12 + 0.52 * Double(count) / Double(maximum))
    }
}

private struct ActivityRankingRow: View {
    @ObservedObject private var language = LanguageManager.shared
    let row: UsageStore.ActivitySummaryRow
    let fraction: Double
    let tint: Color
    let skill: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(row.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if row.derived > 0 {
                    EvidencePill(exact: 0, derived: row.derived)
                }
                Spacer(minLength: 6)
                Text(row.calls.formatted())
                    .font(.callout.monospacedDigit().weight(.medium))
                Text(L10n.text("\(row.sessions) 会话"))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 52, alignment: .trailing)
            }
            HStack(spacing: 8) {
                MeterBar(fraction: fraction, tint: tint, height: 4)
                Text(skill ? L10n.text("最近 \(activityRelativeTime(row.lastUsed))") : compactStatusSummary(row))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .hoverHighlight()
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
    }

    private func compactStatusSummary(_ row: UsageStore.ActivitySummaryRow) -> String {
        let failed = row.errors + row.denied
        if failed > 0 {
            return L10n.text("成功 \(row.success) · 失败 \(failed)")
        }
        if row.success > 0 {
            return L10n.text("成功 \(row.success)")
        }
        return L10n.text("未知 \(row.unknown)")
    }
}

private struct ActivityTimelineRow: View {
    @ObservedObject private var language = LanguageManager.shared
    let event: ActivityEvent

    var body: some View {
        HStack(spacing: 10) {
            Text(activityRelativeTime(event.startedAt ?? event.endedAt ?? 0))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .leading)
            Circle().fill(toolColor(event.agent)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(event.skillName.isEmpty ? event.rawName : "Skill · \(event.skillName)")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if event.eventKind == .agent {
                        Text("Agent")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 5) {
                    Text(toolDisplayName(event.agent))
                    Text("·")
                    HStack(spacing: 3) {
                        Circle().fill(activityStatusColor(event.status)).frame(width: 5, height: 5)
                        Text(activityStatusLabel(event.status))
                    }
                    if let duration = event.durationMs {
                        Text("·")
                        Text(activityDurationText(duration))
                    }
                    if event.eventLayer == .requestFallback {
                        Text("·")
                        Text(L10n.text("未确认执行")).foregroundStyle(.orange)
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if event.confidence == "derived" {
                EvidencePill(exact: 0, derived: 1)
            }
        }
        .padding(.vertical, 7)
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

func activityStatusLabel(_ status: String) -> String {
    ["success": L10n.text("成功"), "error": L10n.text("错误"), "denied": L10n.text("拒绝"), "unknown": L10n.text("未知")][status] ?? status
}

func activityStatusColor(_ status: String) -> Color {
    switch status {
    case "success": return .green
    case "error": return .red
    case "denied": return .orange
    default: return .secondary
    }
}

func activityDurationText(_ ms: Int64) -> String {
    if ms < 1000 { return "\(ms)ms" }
    if ms < 60_000 { return String(format: "%.1fs", Double(ms) / 1000) }
    return String(format: "%.1fm", Double(ms) / 60_000)
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
