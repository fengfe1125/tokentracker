import SwiftUI
import TokenTrackerCore

private func notchColor(_ role: String) -> Color {
    switch role {
    case "quota_ok": return .green
    case "quota_warn": return .orange
    case "quota_crit": return .red
    default: return .secondary
    }
}

struct NotchHUDStripView: View {
    @ObservedObject var state: AppState
    @ObservedObject var preferences: NotchHUDPreferences
    @ObservedObject private var tasks = TaskReminderModel.shared
    let onHover: (String, Bool) -> Void
    let onClick: (String) -> Void

    var body: some View {
        HStack(spacing: NotchHUDLayout.spacing) {
            ForEach(preferences.providers, id: \.self) { provider in
                let quota = NotchHUDQuota(provider: provider, entry: state.quotaEntries.first { $0.id == provider },
                                          display: preferences.quotaDisplay)
                Button { onClick(provider) } label: {
                    NotchHUDRing(quota: quota)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(quota.name + " · " + quota.summary + " · " + quota.windowSummary)
                .onHover { onHover(provider, $0) }
                .overlay(alignment: .topTrailing) {
                    if let pending = tasks.reminders.first(where: { $0.provider.rawValue == provider && $0.pending }) {
                        Button { tasks.show(pending.id, explicit: true) } label: {
                            Circle().fill(.orange).frame(width: 7, height: 7)
                        }.buttonStyle(.plain).accessibilityLabel(L10n.text("等待审批"))
                    }
                }
            }
        }
        .padding(NotchHUDLayout.padding)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

private struct NotchHUDRing: View {
    let quota: NotchHUDQuota
    var body: some View {
        ZStack {
            Circle().stroke(.secondary.opacity(0.22), lineWidth: 2)
            if quota.pct != nil {
                Circle().trim(from: 0, to: quota.fraction)
                    .stroke(notchColor(quota.role), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text(quota.glyph)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(quota.pct == nil ? Color.secondary : Color.primary)
        }
        .padding(1)
        .frame(width: NotchHUDLayout.diameter, height: NotchHUDLayout.diameter)
        .contentShape(Circle())
    }
}

struct NotchHUDTooltipView: View {
    @ObservedObject var state: AppState
    @ObservedObject var preferences: NotchHUDPreferences
    let provider: String
    var body: some View {
        let quota = NotchHUDQuota(provider: provider, entry: state.quotaEntries.first { $0.id == provider },
                                  display: preferences.quotaDisplay)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(quota.name).fontWeight(.semibold)
                Spacer()
                Text(quota.summary).monospacedDigit().foregroundStyle(notchColor(quota.role))
            }
            Text(quota.windowSummary)
                .font(.caption).foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(12)
        .frame(width: 240, height: 62)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct NotchHUDDetailView: View {
    @ObservedObject var state: AppState
    @ObservedObject var model: NotchHUDDetailModel
    @ObservedObject var preferences: NotchHUDPreferences
    let provider: String
    let onClose: () -> Void
    let onOpenMain: () -> Void

    private var quota: NotchHUDQuota {
        NotchHUDQuota(provider: provider, entry: state.quotaEntries.first { $0.id == provider },
                       display: preferences.quotaDisplay)
    }
    private var yi: Bool { (state.settings["unit_yi"] as? NSNumber)?.boolValue ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                NotchHUDRing(quota: quota)
                Text(quota.name).font(.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                    .buttonStyle(.plain).accessibilityLabel(L10n.text("关闭"))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    quotaRows
                    Divider()
                    usage
                }
            }
            Button(action: onOpenMain) {
                HStack { Text(L10n.text("打开主面板")); Spacer(); Image(systemName: "arrow.up.right") }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
        .font(.callout)
        .padding(16)
        .frame(width: 320, height: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private var quotaRows: some View {
        Text(preferences.quotaDisplay.label).font(.caption).foregroundStyle(.secondary)
        if let entry = quota.entry, !entry.windows.isEmpty {
            ForEach(Array(quota.windows.enumerated()), id: \.offset) { _, window in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(UIFormat.quotaLabel(window.label))
                        Spacer()
                        Text(window.pct.flatMap { $0.isFinite ? $0 : nil }.map {
                            MenuBarFmt.quotaMarker(window) + String(format: "%.0f%%", preferences.quotaDisplay.percentage(used: $0))
                        } ?? L10n.text("暂无数据"))
                        .monospacedDigit().foregroundStyle(notchColor(MenuBarFmt.quotaUrgency(window.pct)))
                    }
                    HStack(spacing: 6) {
                        Text(L10n.text(window.pct == nil ? "暂无官方额度" : "官方"))
                        if window.stale { Text(L10n.text("数据已过期")) }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let sampledAt = entry.sampledAt, quota.pct != nil {
                Text(L10n.text("更新于 ") + Date(timeIntervalSince1970: sampledAt)
                    .formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(L10n.locale)))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !entry.note.isEmpty {
                Text(entry.note).font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            Text(L10n.text("暂无数据")).foregroundStyle(.secondary)
        }
        if quota.pct == nil {
            Text(L10n.text("本地 Token 不代表订阅额度"))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var usage: some View {
        HStack {
            Text(L10n.text("今日 Token")).fontWeight(.medium)
            Spacer()
            if let usage = model.usage, let tokens = usage.tokens {
                Text((usage.estimatedTokens > 0 ? "≈ " : "") + UIFormat.tokens(tokens, yi: yi)).monospacedDigit()
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
        if model.failed {
            Text(L10n.text("读取失败，请重新打开重试")).font(.caption).foregroundStyle(.secondary)
        } else if let usage = model.usage {
            if usage.tool != provider, !usage.tool.isEmpty {
                Text(L10n.text("工具汇总：\(usage.tool)"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if usage.hours.isEmpty {
                Text(L10n.text("暂无可分配到小时的用量")).font(.caption).foregroundStyle(.secondary)
                    .frame(height: 72)
            } else {
                hourlyBars(usage)
                Text(L10n.text("今日按小时 · 仅显示可分配用量")).font(.caption2).foregroundStyle(.secondary)
            }
            if usage.estimatedTokens > 0 {
                Text(L10n.text("含观察区间估算")).font(.caption2).foregroundStyle(.secondary)
            }
            if usage.excludedFromHours > 0 {
                Text(L10n.text("另有 \(UIFormat.tokens(usage.excludedFromHours, yi: yi)) Token 无法分配到小时"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if usage.unallocatedTokens > 0 {
                Text(L10n.text("存在无法确定日期的历史用量"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).frame(height: 60)
        }
    }

    private func hourlyBars(_ usage: NotchHUDUsage) -> some View {
        let maximum = max(1, usage.hours.map(\.tokens).max() ?? 1)
        return VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<24, id: \.self) { hour in
                    if let value = usage.hours.first(where: { Int($0.label.prefix(2)) == hour }) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(notchColor(quota.role).opacity(0.8))
                            .frame(height: max(1, CGFloat(Double(value.tokens) / Double(maximum)) * 56))
                            .accessibilityLabel(value.label)
                            .accessibilityValue(UIFormat.tokens(value.tokens, yi: yi))
                    } else {
                        // A gap is unknown/unallocated, not a measured zero.
                        Color.clear.accessibilityHidden(true)
                    }
                }
            }
            .frame(height: 56, alignment: .bottom)
            HStack {
                ForEach(["00", "06", "12", "18", "23"], id: \.self) { label in
                    Text(label)
                    if label != "23" { Spacer() }
                }
            }
            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(height: 80)
    }
}
