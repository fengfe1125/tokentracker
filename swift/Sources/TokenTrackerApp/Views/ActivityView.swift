import SwiftUI
import TokenTrackerCore

struct ActivityView: View {
    @ObservedObject var state: AppState

    private var exactCalls: Int64 { state.activityExactRows.reduce(0) { $0 + $1.calls } }
    private var derivedCalls: Int64 { state.activityDerivedRows.reduce(0) { $0 + $1.calls } }
    private var exactSkillCalls: Int64 { state.activityExactSkillRows.reduce(0) { $0 + $1.calls } }
    private var failures: Int64 {
        state.activityExactRows.reduce(0) { $0 + $1.errors + $1.denied }
    }
    private var unknownResults: Int64 { state.activityExactRows.reduce(0) { $0 + $1.unknown } }
    private var piSkillUnknown: Bool { state.activityAgent == "pi" }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Agent 活动", subtitle: "工具与 Skill 使用 · 仅保存活动元数据") {
                filters
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    evidenceNotice
                    metrics
                    HStack(alignment: .top, spacing: 12) {
                        rankingCard(title: "工具榜", rows: state.activityToolRows, skill: false)
                        rankingCard(title: "Skill 榜", rows: state.activitySkillRows, skill: true)
                    }
                    matrixCard
                    timelineCard
                }
                .padding(20)
            }
        }
        .navigationTitle("Agent 活动")
        .onChange(of: state.activityRange) { _, _ in state.refreshActivity() }
        .onChange(of: state.activityAgent) { _, _ in state.refreshActivity() }
        .onChange(of: state.activityConfidence) { _, _ in state.refreshActivity() }
    }

    private var filters: some View {
        HStack(spacing: 8) {
            Picker("范围", selection: $state.activityRange) {
                Text("今天").tag("day")
                Text("最近 7 天").tag("week")
                Text("本月").tag("month")
                Text("全部").tag("all")
            }
            .labelsHidden()
            .frame(width: 96)
            Picker("Agent", selection: $state.activityAgent) {
                Text("全部 Agent").tag(String?.none)
                ForEach(ScannerRegistry.all, id: \.self) { agent in
                    Text(toolDisplayName(agent)).tag(Optional(agent))
                }
            }
            .labelsHidden()
            .frame(width: 118)
            Picker("证据", selection: $state.activityConfidence) {
                Text("只看已确认").tag("exact")
                Text("包含推断").tag("all")
                Text("只看推断").tag("derived")
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
                    Text("有 \(derivedCalls) 次保守推断，始终与 \(exactCalls) 次确认调用分开。")
                } else {
                    Text("当前范围没有推断调用；确认数据不会混入推断结果。")
                }
            }
            Spacer()
            if let last = state.lastScan, last.done {
                Text("最近扫描：Token +\(last.added) · 活动 +\(last.activityAdded) / 补全 \(last.activityUpdated)")
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
            ("已确认工具调用", "\(exactCalls)", "来自 \(state.activityExactRows.count) 个 Agent", .green),
            ("推断调用", "\(derivedCalls)", "不计入确认总数", .orange),
            ("Skill 使用", piSkillUnknown ? "不可判定" : "\(exactSkillCalls)",
             piSkillUnknown ? "Pi 没有明确 Skill 事件" : "\(state.activityExactSkillRows.count) 个不同 Skill", .primary),
            ("错误 / 拒绝", "\(failures)", "\(unknownResults) 次结果未知", .red),
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
                .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
            }
        }
    }

    private func rankingCard(title: String, rows: [UsageStore.ActivitySummaryRow], skill: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(skill && piSkillUnknown ? "不可判定" : "\(rows.count) 项")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if skill && piSkillUnknown {
                ContentUnavailableView("Skill 不可判定", systemImage: "questionmark.circle",
                                       description: Text("Pi 日志没有明确 Skill 事件，不能显示为 0 次。"))
                    .frame(minHeight: 190)
            } else if rows.isEmpty {
                ContentUnavailableView("暂无活动", systemImage: "waveform.path.ecg")
                    .frame(minHeight: 190)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.prefix(10).enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name).font(.callout.weight(.medium)).lineLimit(1)
                                Text(skill ? "最近 \(relativeTime(row.lastUsed))" : statusText(row))
                                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            Spacer()
                            Text("\(row.calls)").font(.callout.monospacedDigit())
                            Text("\(row.sessions) 会话").font(.caption2).foregroundStyle(.secondary)
                            EvidencePill(exact: row.exact, derived: row.derived)
                        }
                        .padding(.vertical, 7)
                        Divider()
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
    }

    private var matrixCard: some View {
        let agents = ScannerRegistry.all
        let matrix = canonicalMatrix
        let tools = matrixTools(matrix)
        let maximum = max(1, agents.flatMap { agent in tools.map { matrix[agent]?[$0] ?? 0 } }.max() ?? 1)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Agent × 工具矩阵").font(.headline)
                Spacer()
                Text("颜色越深，调用越多").font(.caption2).foregroundStyle(.tertiary)
            }
            if tools.isEmpty {
                ContentUnavailableView("暂无矩阵数据", systemImage: "square.grid.3x3")
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
                                        .background(heatColor(count: count, maximum: maximum), in: RoundedRectangle(cornerRadius: 7))
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
    }

    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("最近活动").font(.headline)
                Spacer()
                Text("按会话关联 Tool / Skill").font(.caption2).foregroundStyle(.tertiary)
            }
            if state.activityTimelineRows.isEmpty {
                ContentUnavailableView("暂无活动", systemImage: "clock")
                    .frame(height: 130)
            } else {
                ForEach(Array(state.activityTimelineRows.prefix(30).enumerated()), id: \.offset) { _, event in
                    HStack(spacing: 9) {
                        Text(relativeTime(event.startedAt ?? event.endedAt ?? 0))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 66, alignment: .leading)
                        Circle().fill(toolColor(event.agent)).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.skillName.isEmpty ? event.rawName : "Skill · \(event.skillName)")
                                .font(.callout.weight(.medium))
                            Text("\(toolDisplayName(event.agent)) · \(statusLabel(event.status))")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        EvidencePill(exact: event.confidence == "exact" ? 1 : 0,
                                     derived: event.confidence == "derived" ? 1 : 0)
                    }
                    .padding(.vertical, 5)
                    Divider()
                }
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
    }

    private var canonicalMatrix: [String: [String: Int64]] {
        Dictionary(uniqueKeysWithValues: ScannerRegistry.all.map { agent in
            var merged: [String: Int64] = [:]
            for row in state.activityMatrixRows[agent] ?? [] {
                merged[ActivityNormalizer.canonicalToolName(row.name), default: 0] += row.calls
            }
            return (agent, merged)
        })
    }

    private func matrixTools(_ matrix: [String: [String: Int64]]) -> [String] {
        var totals: [String: Int64] = [:]
        for values in matrix.values { for (tool, count) in values { totals[tool, default: 0] += count } }
        return totals.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(7).map(\.key)
    }

    private func heatColor(count: Int64, maximum: Int64) -> Color {
        guard count > 0 else { return Color.secondary.opacity(0.06) }
        return Color.green.opacity(0.10 + 0.58 * Double(count) / Double(maximum))
    }

    private func statusText(_ row: UsageStore.ActivitySummaryRow) -> String {
        "成功 \(row.success) · 错误 \(row.errors) · 拒绝 \(row.denied) · 未知 \(row.unknown)"
    }

    private func statusLabel(_ status: String) -> String {
        ["success": "成功", "error": "错误", "denied": "拒绝", "unknown": "未知"][status] ?? status
    }

    private func relativeTime(_ ms: Int64) -> String {
        guard ms > 0 else { return "—" }
        let seconds = max(0, Int(Date().timeIntervalSince1970 - Double(ms) / 1000))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86_400 { return "\(seconds / 3600) 小时前" }
        return "\(seconds / 86_400) 天前"
    }
}

private struct EvidencePill: View {
    let exact: Int64
    let derived: Int64

    var body: some View {
        HStack(spacing: 3) {
            if exact > 0 { pill("已确认", color: .green) }
            if derived > 0 { pill("推断", color: .orange) }
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
