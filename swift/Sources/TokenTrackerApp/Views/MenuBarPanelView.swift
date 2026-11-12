//
//  MenuBarPanelView.swift
//  TokenTrackerApp
//
//  菜单栏速览面板：左键点状态栏图标弹出，不开主窗口就能看完
//  今日用量、各账号配额、各 Agent 今日量、风险和最近会话。
//  需要细看时从这里进主面板；状态栏显示方式等低频项在「⋯」里（右键菜单同样可用）。
//

import SwiftUI
import TokenTrackerCore

/// 面板发出的动作，由 StatusItemController 接到 AppDelegate。
struct MenuBarPanelActions {
    var openMain: () -> Void = {}
    var openSession: (_ tool: String, _ sessionID: String) -> Void = { _, _ in }
    var openAccounts: () -> Void = {}
    var openSettings: () -> Void = {}
    var openTasks: () -> Void = {}
    var quit: () -> Void = {}
}

struct MenuBarPanelView: View {
    static let width: CGFloat = 340

    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject private var notch = NotchHUDPreferences.shared
    @ObservedObject private var sidebar = SidebarPreferences.shared
    @ObservedObject var state: AppState
    let actions: MenuBarPanelActions

    private var yi: Bool { state.prefs.unitYi }

    /// 有官方数据（新鲜或过期）的账号；读不到额度的只计数。
    private var quotaCards: [SubscriptionCard] {
        state.subscriptionCards.filter {
            ($0.snapshot.status == .current || $0.snapshot.status == .stale)
                && !($0.snapshot.windows.isEmpty && $0.snapshot.balances.isEmpty)
        }
    }

    private var unreadableCount: Int {
        state.subscriptionCards.filter {
            switch $0.snapshot.status {
            case .signedOut, .expired, .forbidden, .failed: return true
            case .loading, .current, .stale, .unsupported: return false
            }
        }.count
    }

    /// 今日有用量的 Agent，按侧栏设置里的隐藏项过滤，用量从高到低。
    private var agentRows: [(tool: String, tokens: Int64)] {
        state.todayByTool
            .filter { $0.value > 0 && sidebar.isVisible($0.key, in: .agents) }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { ($0.key, $0.value) }
    }

    private var risks: [RiskNotice] { state.insights.risks.filter { $0.level > 0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            today
            if !risks.isEmpty {
                section { riskList }
            }
            if !quotaCards.isEmpty || unreadableCount > 0 {
                section(L10n.text("配额")) { quotas }
            }
            section(L10n.text("今日各 Agent")) { agents }
            if !state.recentSessions.isEmpty {
                section(L10n.text("最近会话")) { sessions }
            }
            Divider()
            footer
        }
        .frame(width: Self.width)
    }

    private func section<Content: View>(_ title: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.bottom, 4)
            if let title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    // ------------------------------------------------------------ 今日 ----

    private var today: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("今日 Token"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(state.today.map { UIFormat.compact($0.tokens, yi: yi) } ?? "—")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(costLine)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HourBars(hours: state.todayHours)
                .frame(width: 132, height: 40)
                .help(L10n.text("今日按小时"))
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var costLine: String {
        guard let today = state.today else { return L10n.text("今日暂无数据") }
        if today.unpriced { return L10n.text("未计价") }
        return UIFormat.cost(today.cost) + " · " + L10n.text("含估算，非订阅账单")
    }

    // ------------------------------------------------------------ 风险 ----

    private var riskList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(risks.prefix(3)) { risk in
                Label(L10n.label(risk.title) + " · " + UIFormat.riskDetail(risk),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
    }

    // ------------------------------------------------------------ 配额 ----

    private var quotas: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(quotaCards.prefix(3)) { card in
                QuotaSummaryRow(card: card)
            }
            if quotaCards.count > 3 || unreadableCount > 0 {
                Button(action: actions.openAccounts) {
                    HStack(spacing: 4) {
                        if quotaCards.count > 3 {
                            Text(L10n.text("还有 \(quotaCards.count - 3) 个账号"))
                        }
                        if unreadableCount > 0 {
                            Text(L10n.text("\(unreadableCount) 个账号未能读取额度"))
                                .foregroundStyle(.orange)
                        }
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    // ----------------------------------------------------------- Agent ----

    @ViewBuilder
    private var agents: some View {
        let rows = agentRows
        let top = rows.first?.tokens ?? 0
        if rows.isEmpty {
            Text(L10n.text("今日暂无数据"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(rows.prefix(6), id: \.tool) { row in
                    ShareRow(fraction: top > 0 ? Double(row.tokens) / Double(top) : 0,
                             tint: toolColor(row.tool),
                             primary: UIFormat.compact(row.tokens, yi: yi)) {
                        Circle().fill(toolColor(row.tool)).frame(width: 7, height: 7)
                        Text(toolDisplayName(row.tool)).font(.callout).lineLimit(1)
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------ 会话 ----

    private var sessions: some View {
        VStack(spacing: 0) {
            ForEach(state.recentSessions.prefix(3), id: \.sessionID) { session in
                Button { actions.openSession(session.tool, session.sessionID) } label: {
                    HStack(spacing: 7) {
                        Circle().fill(toolColor(session.tool)).frame(width: 7, height: 7)
                        Text(SessionRowModel(row: session).title)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(UIFormat.compact(session.stats.tokens, yi: yi))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .hoverHighlight()
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, -6)
    }

    // ------------------------------------------------------------ 底栏 ----

    private var provider: Binding<String> {
        Binding(get: { state.prefs.menubarProvider },
                set: { state.updateSetting(key: "menubar_provider", value: $0) })
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: actions.openMain) {
                Label(L10n.text("打开主面板"), systemImage: "macwindow")
            }
            Spacer(minLength: 4)
            if let updated = state.updatedAt {
                Text(updated.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .help(L10n.text("更新于 ") + UIFormat.dateTime(ms: Int64(updated.timeIntervalSince1970 * 1000)))
            }
            Button { state.requestScan() } label: {
                if state.scanning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(state.scanning)
            .help(L10n.text("立即扫描"))
            Button(action: actions.openSettings) { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help(L10n.text("设置"))
            Menu {
                Picker(L10n.text("状态栏显示"), selection: provider) {
                    ForEach(state.quotaEntries, id: \.id) { entry in
                        Text(L10n.text("今日用量 + \(entry.name)")).tag(entry.id)
                    }
                    Text(L10n.text("仅今日用量")).tag("off")
                    Text(L10n.text("仅显示 Token 数字")).tag("tokens")
                }
                Toggle(L10n.text("显示刘海圆环"), isOn: $notch.enabled)
                Button(L10n.text("任务提醒"), action: actions.openTasks)
                Divider()
                Button(L10n.text("退出 TokenTracker"), action: actions.quit)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L10n.text("更多"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// 一个账号的配额摘要：名称 + 最紧的两个窗口（或余额）。
private struct QuotaSummaryRow: View {
    let card: SubscriptionCard

    private var windows: [SubscriptionWindow] {
        card.snapshot.windows
            .filter { $0.usedPercent != nil }
            .sorted { ($0.usedPercent ?? 0) > ($1.usedPercent ?? 0) }
    }

    private func color(_ percent: Double?) -> Color {
        switch MenuBarFmt.quotaUrgency(percent) {
        case "quota_crit": return .red
        case "quota_warn": return .orange
        default: return .green
        }
    }

    var body: some View {
        let stale = card.snapshot.status == .stale
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(card.account.provider.displayName)
                    .font(.callout.weight(.medium))
                Text(SubscriptionText.account(card.account))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if stale {
                    Text(SubscriptionText.status(.stale))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            if let balance = card.snapshot.balances.first {
                Text(L10n.text("总余额 · \(L10n.Template(verbatim: balance.currency))") + "  "
                     + SubscriptionText.money(balance.total, currency: balance.currency))
                    .font(.caption.monospacedDigit())
            }
            ForEach(windows.prefix(2)) { window in
                HStack(spacing: 8) {
                    Text(SubscriptionText.window(window))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 74, alignment: .leading)
                    MeterBar(fraction: (window.usedPercent ?? 0) / 100,
                             tint: color(window.usedPercent).opacity(stale ? 0.5 : 1), height: 4)
                    Text(window.usedPercent.map(SubscriptionText.percent) ?? "—")
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(color(window.usedPercent))
                        .frame(width: 36, alignment: .trailing)
                }
                .help(SubscriptionText.windowDetail(window))
            }
            if let reset = windows.first?.resetsAt {
                Text(L10n.text("\(L10n.Template(verbatim: SubscriptionText.time(reset, relative: true))) 重置"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 今日 24 小时迷你柱：当前小时高亮，未到的小时只画底线。
private struct HourBars: View {
    let hours: [Double]

    var body: some View {
        let top = max(hours.max() ?? 0, 1)
        let current = Calendar.current.component(.hour, from: Date())
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(Array(hours.enumerated()), id: \.offset) { hour, value in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(hour == current ? Color.accentColor
                              : hour > current ? Color.primary.opacity(0.08)
                              : Color.accentColor.opacity(0.45))
                        .frame(height: max(2, geo.size.height * value / top))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}
