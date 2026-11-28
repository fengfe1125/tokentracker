//
//  AccountsView.swift
//  TokenTrackerApp
//
//  账号：左栏选账号，右栏看这个账号的官方配额或余额并管理它（用于菜单栏、重新登录、
//  移除）；顶部是登录、添加 / 导入 API Key、刷新。Codex 多账号切换在 Codex 账号下方。
//  凭据快照仅存本机 ~/.tokentracker（0600）。
//

import SwiftUI
import TokenTrackerCore

struct AccountsView: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var state: AppState
    @State private var addingKey = false
    @State private var removing: SubscriptionCard?

    private var cards: [SubscriptionCard] { state.subscriptionCards }
    /// 同一账号的多把 API Key（余额完全相同）合并为一行。
    private var groups: [SubscriptionCardGroup] { state.subscriptionGroups }
    private var selected: SubscriptionCardGroup? {
        let groups = groups
        return state.accountFocus.flatMap { focus in groups.first { $0.contains(focus) } } ?? groups.first
    }
    private var needAttention: Int {
        groups.filter { AccountStatus.needsAttention($0.primary.snapshot.status) }.count
    }
    private var showsCodex: Bool { state.detectInfo["codex"]?.installed == true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gridSpacing) {
                actionBar
                if cards.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.text("未发现本机订阅账号"), systemImage: "creditcard")
                    } description: {
                        Text(L10n.text("登录或添加 API Key 后，这里会显示官方配额与余额。"))
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                    .card()
                } else {
                    AdaptiveLeadingFixedLayout(
                        leadingWidth: 280,
                        minTrailingWidth: 420,
                        spacing: Metrics.gridSpacing
                    ) {
                        accountList
                        detailColumn
                    }
                }
                if cards.isEmpty && showsCodex { CodexAccountsCard(model: state.codex) }
                Text(L10n.text("账号由 TokenTracker 自己登录并续期，与其他软件的登录互不影响；凭据保存在 ~/.tokentracker/subscription_accounts.json（仅本人可读）。导入只复制一次 API Key；Antigravity 以只读方式自动读取本机登录态，不修改原工具凭据。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Metrics.pagePadding)
        }
        .pageChrome(title: L10n.text("账号"))
        .sheet(isPresented: $addingKey) { AddAPIKeySheet(state: state) }
        .sheet(item: Binding(get: { state.subscriptionLogin },
                             set: { if $0 == nil { state.cancelSubscriptionLogin() } })) { login in
            SubscriptionLoginSheet(state: state, login: login)
        }
        .confirmationDialog(L10n.text("移除这个订阅账号？"), isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(L10n.text("移除"), role: .destructive) {
                if let card = removing { state.removeSubscriptionAccount(card.id) }
                removing = nil
            }
            Button(L10n.text("取消"), role: .cancel) { removing = nil }
        } message: {
            Text(L10n.text("只删除 TokenTracker 保存的凭据，不影响其他软件或官方账号。"))
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Text(needAttention > 0
                 ? L10n.text("\(groups.count) 个账号 · \(needAttention) 个需要留意")
                 : L10n.text("\(groups.count) 个账号"))
                .font(.callout).foregroundStyle(.secondary)
            if let notice = state.subscriptionNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if state.subscriptionRefreshing { ProgressView().controlSize(.small) }
            Button {
                state.refreshQuotas(force: true)
            } label: {
                Label(L10n.text("刷新"), systemImage: "arrow.clockwise")
            }
            .disabled(state.subscriptionRefreshing)
            Button(L10n.text("从本机导入 API Key")) { state.importSubscriptionKeys() }
            Button(L10n.text("添加 API Key…")) { addingKey = true }
            SubscriptionLoginMenu(state: state)
        }
    }

    // ------------------------------------------------------------ 左栏 ----

    private var accountList: some View {
        VStack(spacing: 2) {
            ForEach(groups) { group in
                Button {
                    state.accountFocus = group.id
                } label: {
                    AccountListRow(group: group, selected: group.id == selected?.id)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .card(padding: 8)
    }

    // ------------------------------------------------------------ 右栏 ----

    @ViewBuilder
    private var detailColumn: some View {
        VStack(spacing: Metrics.gridSpacing) {
            if let group = selected {
                AccountDetail(state: state, group: group) { removing = $0 }
                    .id(group.id)
            }
            if showsCodex && (selected?.primary.account.provider == .codex || selected == nil) {
                CodexAccountsCard(model: state.codex)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

enum AccountStatus {
    /// 读不到额度的状态（未登录 / 凭据失效 / 无权限 / 失败 / 不支持）
    static func needsAttention(_ status: SubscriptionStatus) -> Bool {
        switch status {
        case .signedOut, .expired, .forbidden, .failed, .unsupported: return true
        case .loading, .current, .stale: return false
        }
    }

    static func tightest(_ card: SubscriptionCard) -> SubscriptionWindow? {
        card.snapshot.windows.filter { $0.usedPercent != nil }
            .max { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) }
    }

    static func hasData(_ card: SubscriptionCard) -> Bool {
        card.snapshot.status == .current || card.snapshot.status == .stale
    }
}

/// 账号的方形字母标。
private struct ProviderMark: View {
    let provider: SubscriptionProvider
    var size: CGFloat = 30

    var body: some View {
        Text(String(provider.displayName.prefix(1)))
            .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
            .foregroundStyle(providerColor(provider))
            .frame(width: size, height: size)
            .background(providerColor(provider).opacity(0.16),
                        in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct AccountListRow: View {
    let group: SubscriptionCardGroup
    let selected: Bool
    private var card: SubscriptionCard { group.primary }

    var body: some View {
        HStack(spacing: 10) {
            ProviderMark(provider: card.account.provider)
            VStack(alignment: .leading, spacing: 1) {
                Text(card.account.provider.displayName).fontWeight(.semibold).lineLimit(1)
                Text(SubscriptionText.account(group))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(selected ? Color.brand.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var trailing: some View {
        if AccountStatus.hasData(card), let window = AccountStatus.tightest(card) {
            Text(SubscriptionText.percent(window.usedPercent ?? 0))
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(quotaColor(window.usedPercent))
        } else if AccountStatus.hasData(card), let balance = card.snapshot.balances.first {
            Text(SubscriptionText.money(balance.total, currency: balance.currency))
                .font(.callout.monospacedDigit())
        } else {
            StatusBadge(status: card.snapshot.status)
        }
    }
}

/// 右栏：选中账号的额度、信息与操作。
private struct AccountDetail: View {
    @ObservedObject var state: AppState
    let group: SubscriptionCardGroup
    let remove: (SubscriptionCard) -> Void

    private var card: SubscriptionCard { group.primary }

    private var supportsMenuBar: Bool { card.account.provider.menuBarID != nil }
    private var snapshot: SubscriptionSnapshot { card.snapshot }
    private var hasData: Bool { AccountStatus.hasData(card) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let message = SubscriptionText.problem(snapshot, autoDiscovered: card.account.isAutoDiscovered) {
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .sunkPanel(padding: 10, radius: 10)
            }
            AccountQuotaView(card: card)
            if group.isMerged { keyList }
            info
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var header: some View {
        let plan = snapshot.plan.isEmpty ? card.account.planHint : snapshot.plan
        return HStack(spacing: 12) {
            ProviderMark(provider: card.account.provider, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(card.account.provider.displayName).font(.title3.weight(.semibold))
                    if !plan.isEmpty { Text(plan).font(.callout).foregroundStyle(.secondary) }
                }
                Text(SubscriptionText.account(group))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            StatusBadge(status: snapshot.status)
        }
    }

    /// 合并展示的多把 Key：逐把显示来源并可单独移除。
    private var keyList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("\(group.cards.count) 把 API Key 查询到的余额完全相同，视为同一账号合并显示"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(group.cards.enumerated()), id: \.element.id) { index, member in
                if index > 0 { Divider() }
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(SubscriptionText.account(member.account))
                            .font(.callout.monospaced()).lineLimit(1)
                        Text(SubscriptionText.sources(member.account.sources))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if member.snapshot.status == .stale {
                        StatusBadge(status: member.snapshot.status)
                    }
                    if !member.account.isAutoDiscovered {
                        Button(L10n.text("移除"), role: .destructive) { remove(member) }
                            .controlSize(.small)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sunkPanel()
    }

    private var info: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            let sources = group.isMerged ? "" : SubscriptionText.sources(card.account.sources)
            if !sources.isEmpty {
                GridRow {
                    Text(sources).fixedSize(horizontal: false, vertical: true).gridCellColumns(2)
                }
            }
            if let sampled = snapshot.sampledAt, hasData {
                GridRow {
                    Text(L10n.text("上次刷新")).foregroundStyle(.secondary)
                    Text(SubscriptionText.time(sampled) + (snapshot.privateAPI ? " · " + L10n.text("非公开接口") : ""))
                }
            }
            if let login = card.account.savedLogin {
                GridRow {
                    Text(L10n.text("登录凭证")).foregroundStyle(.secondary)
                    Text(SubscriptionText.savedLogin(login))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if supportsMenuBar {
                GridRow {
                    Text(L10n.text("菜单栏")).foregroundStyle(.secondary)
                    Text(card.account.isActive ? L10n.text("显示中") : L10n.text("未显示"))
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sunkPanel()
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if snapshot.status == .expired || snapshot.status == .signedOut,
               SubscriptionAuth.loginProviders.contains(card.account.provider),
               SubscriptionAuth.regions(for: card.account.provider).isEmpty {
                Button(L10n.text("重新登录")) { state.startSubscriptionLogin(card.account.provider) }
                    .buttonStyle(.borderedProminent)
            }
            if supportsMenuBar {
                if card.account.isActive {
                    Pill(text: L10n.text("显示在菜单栏"), tint: .brand)
                } else {
                    Button(L10n.text("用于菜单栏")) { state.setSubscriptionMenuBarAccount(card.id) }
                }
            }
            Spacer(minLength: 8)
            if card.account.isAutoDiscovered {
                Pill(text: L10n.text("自动读取本机登录"), tint: .secondary)
            } else if !group.isMerged {
                Button(L10n.text("移除"), role: .destructive) { remove(card) }
            }
        }
    }
}

/// 一个账号的额度区：每个窗口一个圆环块（同名多周期按组归类），余额账号显示金额。
struct AccountQuotaView: View {
    let card: SubscriptionCard
    private var snapshot: SubscriptionSnapshot { card.snapshot }
    private var hasData: Bool { AccountStatus.hasData(card) }

    /// 读不到额度时显示「—」，不显示为 0。
    var body: some View {
        if hasData && !snapshot.balances.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
                ForEach(snapshot.balances) { balance in
                    BalanceView(balance: balance)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .sunkPanel(padding: 14)
                }
            }
        } else if hasData && !snapshot.windows.isEmpty {
            if let groups = SubscriptionWindowGroup.groups(from: snapshot.windows) {
                AdaptiveTileGridLayout(maxColumns: 2, fallbackColumns: 1, minColumnWidth: 270, spacing: 10) {
                    ForEach(groups) { group in
                        QuotaGroupBlock(group: group, dimmed: snapshot.status == .stale)
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(snapshot.windows) { window in
                        QuotaRingBlock(percent: window.usedPercent,
                                       title: SubscriptionText.window(window),
                                       detail: SubscriptionText.windowDetail(window),
                                       dimmed: snapshot.status == .stale)
                    }
                }
            }
        } else {
            QuotaRingBlock(percent: nil, title: L10n.text("额度不可读"),
                           detail: L10n.text("缺失的额度不显示为 0"), dimmed: false)
                .frame(maxWidth: 220)
        }
    }

}

/// 同组多周期额度块：组名标题 + 并排圆环（如 Gemini / Claude 的 5 小时与周额度）。
private struct QuotaGroupBlock: View {
    let group: SubscriptionWindowGroup
    let dimmed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(group.title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            AdaptiveTileGridLayout(maxColumns: 2, fallbackColumns: 1, minColumnWidth: 112, spacing: 10) {
                ForEach(group.windows) { window in
                    QuotaRingContent(percent: window.usedPercent,
                                     title: SubscriptionText.windowInGroup(window),
                                     detail: SubscriptionText.windowDetail(window),
                                     dimmed: dimmed,
                                     ringSize: 72,
                                     titleFont: .subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sunkPanel(padding: 14)
    }
}

/// 一个额度窗口：大圆环 + 名称 + 重置时间。
private struct QuotaRingBlock: View {
    let percent: Double?
    let title: String
    let detail: String
    let dimmed: Bool

    var body: some View {
        QuotaRingContent(percent: percent, title: title, detail: detail, dimmed: dimmed)
            .frame(maxWidth: .infinity)
            .sunkPanel(padding: 14)
    }
}

private struct QuotaRingContent: View {
    let percent: Double?
    let title: String
    let detail: String
    let dimmed: Bool
    var ringSize: CGFloat = 76
    var titleFont: Font = .callout.weight(.semibold)
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let color = quotaColor(percent)
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(color.opacity(0.18), lineWidth: 7)
                if let percent {
                    Circle()
                        .trim(from: 0, to: shown ? max(0, min(1, percent / 100)) : 0)
                        .stroke(color.opacity(dimmed ? 0.5 : 1), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text(percent.map(SubscriptionText.percent) ?? "—")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(percent == nil ? .secondary : .primary)
            }
            .frame(width: ringSize, height: ringSize)
            .padding(.bottom, 4)
            Text(title).font(titleFont).lineLimit(1).minimumScaleFactor(0.8)
            Text(detail.isEmpty ? " " : detail)
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .onAppear {
            if reduceMotion { shown = true } else { withAnimation(.easeOut(duration: 0.7)) { shown = true } }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Codex 多账号：保存当前登录、一键切换、重命名 / 删除。
struct CodexAccountsCard: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var model: CodexAccountsModel
    @State private var showCaptureSheet = false
    @State private var captureName = ""
    @State private var renameTarget: CodexAccount?
    @State private var renameName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(title: L10n.text("Codex 账号")) {
                Button(L10n.text("保存当前登录账号…")) {
                    captureName = ""
                    showCaptureSheet = true
                }
            }
            if model.accounts.isEmpty {
                Text(L10n.text("还没有保存的账号。先在 Codex 登录，再点上面的按钮把当前登录存进来。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.accounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 { Divider() }
                        codexAccountRow(account).padding(.vertical, 7)
                    }
                }
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Text(L10n.text("切换后请重启 Codex 生效；账号之间切换不会丢会话。凭据快照仅存本机，不上传。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    .alert(L10n.text("保存当前登录账号"), isPresented: $showCaptureSheet) {
        TextField(L10n.text("备注名（留空则用邮箱）"), text: $captureName)
        Button(L10n.text("保存")) {
            model.captureCurrent(name: captureName)
            captureName = ""
        }
        Button(L10n.text("取消"), role: .cancel) { captureName = "" }
    } message: {
        Text(L10n.text("把当前 Codex 登录的凭据快照存到本机，之后可一键切回。"))
    }
    .alert(L10n.text("重命名账号"), isPresented: renamePresented, presenting: renameTarget) { account in
        TextField(L10n.text("备注名"), text: $renameName)
        Button(L10n.text("确定")) {
            model.rename(id: account.id, name: renameName)
            renameTarget = nil
        }
        Button(L10n.text("取消"), role: .cancel) { renameTarget = nil }
    }
    }

    @ViewBuilder
    private func codexAccountRow(_ account: CodexAccount) -> some View {
        let isActive = model.activeID == account.id
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(account.name)
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .help(L10n.text("当前生效"))
                    }
                }
                if let subtitle = codexAccountSubtitle(account) {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !isActive {
                Button(L10n.text("切换")) { model.switchTo(id: account.id) }
            }
            Menu {
                Button(L10n.text("重命名…")) {
                    renameName = account.name
                    renameTarget = account
                }
                Button(L10n.text("删除"), role: .destructive) {
                    model.remove(id: account.id)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func codexAccountSubtitle(_ account: CodexAccount) -> String? {
        var parts: [String] = []
        if let email = account.email, !email.isEmpty { parts.append(email) }
        if let plan = account.plan, !plan.isEmpty { parts.append(plan) }
        parts.append("id …\(account.id.suffix(6))")
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } })
    }
}
