import SwiftUI
import TokenTrackerCore

/// 概览「订阅配额与余额」：宽窗口两列、窄窗口一列；同一行卡片等高、顶部对齐，
/// 高度随内容增长，文字不裁剪。
struct SubscriptionSection: View {
    @ObservedObject private var language = LanguageManager.shared
    let cards: [SubscriptionCard]
    let refreshing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L10n.text("订阅配额与余额")).font(.headline)
                if refreshing { ProgressView().controlSize(.small) }
            }
            if cards.isEmpty {
                Text(L10n.text("未发现本机订阅账号"))
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                EqualHeightRows(minColumnWidth: 300, maxColumns: 2, spacing: 12) {
                    ForEach(cards) { card in
                        SubscriptionCardView(card: card)
                    }
                }
            }
        }
    }
}

/// 行内等高网格：每行高度取该行最高卡片，所有卡片顶部对齐。
struct EqualHeightRows: Layout {
    var minColumnWidth: CGFloat
    var maxColumns: Int
    var spacing: CGFloat

    private func metrics(_ width: CGFloat, _ subviews: Subviews) -> (columns: Int, columnWidth: CGFloat, rows: [CGFloat]) {
        let fit = Int((width + spacing) / (minColumnWidth + spacing))
        let columns = max(1, min(maxColumns, fit))
        let columnWidth = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        var rows: [CGFloat] = []
        for start in stride(from: 0, to: subviews.count, by: columns) {
            let height = subviews[start..<min(start + columns, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }
                .max() ?? 0
            rows.append(ceil(height))
        }
        return (columns, columnWidth, rows)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (minColumnWidth * CGFloat(maxColumns) + spacing * CGFloat(maxColumns - 1))
        let rows = metrics(width, subviews).rows
        return CGSize(width: width, height: rows.reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (columns, columnWidth, rows) = metrics(bounds.width, subviews)
        var y = bounds.minY
        for (row, height) in rows.enumerated() {
            for column in 0..<columns {
                let index = row * columns + column
                guard index < subviews.count else { break }
                subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(column) * (columnWidth + spacing), y: y),
                                      anchor: .topLeading,
                                      proposal: ProposedViewSize(width: columnWidth, height: height))
            }
            y += height + spacing
        }
    }
}

struct SubscriptionCardView: View {
    @ObservedObject private var language = LanguageManager.shared
    let card: SubscriptionCard

    private var snapshot: SubscriptionSnapshot { card.snapshot }
    private var hasData: Bool { snapshot.status == .current || snapshot.status == .stale }
    private var tightest: SubscriptionWindow? {
        snapshot.windows.filter { $0.usedPercent != nil }.max { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if hasData && !snapshot.balances.isEmpty {
                ForEach(snapshot.balances) { BalanceView(balance: $0) }
            } else if hasData && !snapshot.windows.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(snapshot.windows) { WindowRow(window: $0, stale: snapshot.status == .stale) }
                }
            }
            if let message = SubscriptionText.problem(snapshot) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(hasData ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            if hasData && snapshot.balances.isEmpty && tightest != nil {
                RingView(pct: tightest?.usedPercent, role: MenuBarFmt.quotaUrgency(tightest?.usedPercent),
                         hasData: true)
                    .frame(width: 40, height: 40)
                    .opacity(snapshot.status == .stale ? 0.6 : 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(card.account.provider.displayName)
                    .font(.callout.weight(.semibold))
                Text(SubscriptionText.account(card.account))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                let plan = snapshot.plan.isEmpty ? card.account.planHint : snapshot.plan
                if !plan.isEmpty || card.account.isActive {
                    HStack(spacing: 6) {
                        if !plan.isEmpty { Text(plan) }
                        if card.account.isActive { Text(L10n.text("当前登录")).foregroundStyle(.blue) }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            StatusBadge(status: snapshot.status)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(SubscriptionText.sources(card.account.sources))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if let sampled = snapshot.sampledAt, hasData {
                    Text(L10n.text("更新于 \(L10n.Template(verbatim: SubscriptionText.time(sampled)))"))
                }
                if snapshot.privateAPI { Text(L10n.text("非公开接口")) }
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}

private struct StatusBadge: View {
    let status: SubscriptionStatus

    var body: some View {
        HStack(spacing: 4) {
            if status == .loading { ProgressView().controlSize(.mini) }
            Text(SubscriptionText.status(status))
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(color.opacity(0.14), in: Capsule())
        .foregroundStyle(color)
        .fixedSize()
    }

    private var color: Color {
        switch status {
        case .current: return .green
        case .stale: return .orange
        case .expired, .forbidden, .failed: return .red
        case .loading, .signedOut, .unsupported: return .secondary
        }
    }
}

private struct WindowRow: View {
    let window: SubscriptionWindow
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(SubscriptionText.window(window))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(window.usedPercent.map { L10n.text("已用 \(L10n.Template(verbatim: SubscriptionText.percent($0)))") } ?? "—")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(color)
            }
            if let pct = window.usedPercent {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule().fill(color.opacity(stale ? 0.5 : 1))
                            .frame(width: proxy.size.width * max(0, min(1, pct / 100)))
                    }
                }
                .frame(height: 4)
            }
            let detail = SubscriptionText.windowDetail(window)
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var color: Color {
        switch MenuBarFmt.quotaUrgency(window.usedPercent) {
        case "quota_crit": return .red
        case "quota_warn": return .orange
        default: return window.usedPercent == nil ? .secondary : .green
        }
    }
}

private struct BalanceView: View {
    let balance: SubscriptionBalance

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text("总余额 · \(L10n.Template(verbatim: balance.currency))"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(SubscriptionText.money(balance.total, currency: balance.currency))
                .font(.title2.monospacedDigit().weight(.semibold))
            Text(L10n.text("赠送 \(L10n.Template(verbatim: SubscriptionText.money(balance.granted, currency: balance.currency))) · 充值 \(L10n.Template(verbatim: SubscriptionText.money(balance.toppedUp, currency: balance.currency)))"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 订阅卡片文案（本地化 + 数值格式）。缺失值一律 “—”，真实零值才显示 0。
enum SubscriptionText {
    static func status(_ status: SubscriptionStatus) -> String {
        switch status {
        case .loading: return L10n.text("加载中")
        case .current: return L10n.text("官方最新")
        case .stale: return L10n.text("官方过期")
        case .signedOut: return L10n.text("未登录")
        case .expired: return L10n.text("凭据失效")
        case .forbidden: return L10n.text("权限不足")
        case .failed: return L10n.text("请求失败")
        case .unsupported: return L10n.text("暂不支持")
        }
    }

    static func problem(_ snapshot: SubscriptionSnapshot) -> String? {
        guard let problem = snapshot.problem else {
            return snapshot.status == .signedOut ? L10n.text("未找到可用凭据，请在设置中重新登录") : nil
        }
        let text: String
        switch problem {
        case .noCredential: text = L10n.text("未找到可用凭据，请在设置中重新登录")
        case .credentialExpired: text = L10n.text("登录已过期且无法自动续期，请在设置中重新登录")
        case .unauthorized: text = L10n.text("凭据失效，请在设置中重新登录")
        case .forbidden: text = L10n.text("账号没有读取额度的权限")
        case .rateLimited: text = L10n.text("接口限流，稍后自动重试")
        case .timeout: text = L10n.text("请求超时，稍后自动重试")
        case .network: text = L10n.text("网络连接失败，稍后自动重试")
        case .httpStatus: text = L10n.text("额度接口返回 HTTP \(snapshot.httpStatus ?? 0)")
        case .malformed: text = L10n.text("接口返回格式无法识别")
        case .noWindows: text = L10n.text("接口没有返回额度窗口")
        case .untrustedEndpoint: text = L10n.text("接口域名未获信任，已拦截")
        case .apiKeyOnly: text = L10n.text("只发现 API Key，无法读取订阅额度")
        case .freeModel: text = L10n.text("免费模型，没有账号额度")
        case .relayEndpoint: text = L10n.text("Key 配置给第三方中转，不发往官方接口")
        case .enterpriseUnsupported: text = L10n.text("团队账号额度暂不支持")
        case .noSubscription: text = L10n.text("官方返回：该账号没有有效订阅")
        case .balanceUnavailable: text = L10n.text("余额不足以调用 API")
        }
        return snapshot.status == .stale ? L10n.text("显示上次官方结果：\(L10n.Template(verbatim: text))") : text
    }

    static func account(_ account: SubscriptionAccount) -> String {
        if !account.shortLabel.isEmpty { return account.shortLabel }
        if !account.keyHint.isEmpty { return "API Key " + account.keyHint }
        return L10n.text("账号 \(L10n.Template(verbatim: String(account.id.suffix(6))))")
    }

    static func sources(_ sources: [SubscriptionSource]) -> String {
        guard let first = sources.first else { return "" }
        let builtins: Set<String> = ["自有登录", "手动添加"]
        func text(_ value: String) -> String {
            if builtins.contains(value) { return L10n.label(value) }
            if value.hasPrefix("导入自 ") {
                let from = String(value.dropFirst(4))
                return L10n.text("导入自 \(from == "本机配置" ? L10n.label(from) : from)")
            }
            return value
        }
        let main = text(first.tool) + " · " + text(first.location)
        return sources.count > 1 ? L10n.text("来源：\(L10n.Template(verbatim: main)) 等 \(sources.count) 处")
            : L10n.text("来源：\(L10n.Template(verbatim: main))")
    }

    static func window(_ window: SubscriptionWindow) -> String {
        let names = ["premium_interactions": "高级请求", "chat": "对话", "completions": "代码补全",
                     "credits": "积分", "on-demand": "按需额度"]
        let span: String? = window.duration.map { seconds in
            switch seconds {
            case 18_000: return L10n.text("5 小时")
            case 86_400: return L10n.text("每日")
            case 604_800: return L10n.text("周 (7天)")
            case 2_592_000, 2_678_400: return L10n.text("月度")
            default:
                return seconds % 86_400 == 0 ? L10n.text("\(seconds / 86_400) 天")
                    : L10n.text("\(max(1, seconds / 3600)) 小时")
            }
        }
        if let name = window.name {
            let label = names[name].map(L10n.label) ?? name
            return span.map { label + " · " + $0 } ?? label
        }
        return span ?? L10n.text("额度")
    }

    static func windowDetail(_ window: SubscriptionWindow) -> String {
        var parts: [String] = []
        if let limit = window.limit {
            let unit = window.unit.map { ["requests": "次", "credits": "积分"][$0].map(L10n.label) ?? $0 } ?? ""
            let used = window.used.map(decimal) ?? "—"
            parts.append("\(used) / \(decimal(limit)) \(unit)".trimmingCharacters(in: .whitespaces))
        }
        if let reset = window.resetsAt { parts.append(L10n.text("\(L10n.Template(verbatim: time(reset, relative: true))) 重置")) }
        return parts.joined(separator: " · ")
    }

    static func percent(_ value: Double) -> String {
        value > 0 && value < 1 ? "<1%" : String(format: "%.0f%%", value.rounded())
    }

    static func decimal(_ value: Decimal) -> String {
        let f = NumberFormatter()
        f.locale = L10n.locale
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        return f.string(from: NSDecimalNumber(decimal: value)) ?? "\(value)"
    }

    /// 金额保留两位小数，不经过 Double。
    static func money(_ value: Decimal?, currency: String) -> String {
        guard let value else { return "—" }
        let f = NumberFormatter()
        f.locale = L10n.locale
        f.numberStyle = .currency
        f.currencyCode = currency
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f.string(from: NSDecimalNumber(decimal: value)) ?? "\(value) \(currency)"
    }

    static func time(_ date: Date, relative: Bool = false, now: Date = Date()) -> String {
        if relative && date > now && date.timeIntervalSince(now) < 36 * 3600 {
            let f = RelativeDateTimeFormatter()
            f.locale = L10n.locale
            f.unitsStyle = .short
            return f.localizedString(for: date, relativeTo: now)
        }
        let f = DateFormatter()
        f.locale = L10n.locale
        f.setLocalizedDateFormatFromTemplate(Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "MMMdHH:mm")
        return f.string(from: date)
    }
}
