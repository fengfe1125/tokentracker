//
//  MenuBarStyle.swift
//  TokenTrackerCore
//
//  状态栏标题的三种样式（设置键 menubar_style）与渲染所需的纯数据模型。
//  绘制在 App 层（MenuBarStyleRenderer），这里只决定「显示什么」。
//

import Foundation

/// 状态栏标题样式。
public enum MenuBarStyle: String, CaseIterable, Sendable, Identifiable {
    /// A 原生单色：进度环内嵌平台字母 + 今日 Token，只在预警/临界时上色。
    case native
    /// B 双行仪表：上行今日 Token，下行平台名 + 百分比，右侧竖条表示用量。
    case stacked
    /// C 配额胶囊：今日 Token + 品牌色头像与按用量填充底色的胶囊。
    case capsule

    public static let `default` = MenuBarStyle.native
    public var id: String { rawValue }

    /// 未知或缺失的设置值回退到默认样式。
    public init(setting: String?) {
        self = setting.flatMap(MenuBarStyle.init(rawValue:)) ?? .default
    }
}

/// 状态栏要显示的内容（与样式无关）。
public struct MenuBarDisplay: Equatable, Sendable {
    public enum Urgency: String, Sendable {
        case none, ok, warn, crit
    }

    public struct Quota: Equatable, Sendable {
        public var providerID: String
        /// 平台单字母（Claude → C，Codex → X）
        public var glyph: String
        public var name: String
        /// 工具标识色（#rrggbb），未知平台为 nil
        public var brandHex: String?
        /// 最紧窗口的已用百分比（0…100）；nil = 暂无配额数据
        public var pct: Double?
        /// 本地估算（≈），非官方实时数据
        public var approximate: Bool
        public var urgency: Urgency

        public init(providerID: String, glyph: String, name: String, brandHex: String?,
                    pct: Double?, approximate: Bool, urgency: Urgency) {
            self.providerID = providerID
            self.glyph = glyph
            self.name = name
            self.brandHex = brandHex
            self.pct = pct
            self.approximate = approximate
            self.urgency = urgency
        }
    }

    /// 今日 Token 紧凑数；今日无数据为 "—"
    public var tokensText: String
    public var hasTokens: Bool
    /// 追加显示的平台配额；nil = 仅今日用量 / 仅数字
    public var quota: Quota?
    /// provider == "tokens"：只显示数字，不画任何配额图形
    public var tokensOnly: Bool

    public init(tokensText: String, hasTokens: Bool, quota: Quota?, tokensOnly: Bool) {
        self.tokensText = tokensText
        self.hasTokens = hasTokens
        self.quota = quota
        self.tokensOnly = tokensOnly
    }
}

extension MenuBarFmt {
    /// 平台全名回退（尚未登录账号、配额列表里没有该平台时）。
    public static let providerName = [
        "claude": "Claude", "codex": "Codex", "antigravity": "Antigravity",
        "kimi": "Kimi", "go": "OpenCode Go",
    ]

    /// 状态栏显示模型。provider："off" = 仅今日用量，"tokens" = 仅数字，其余为平台 id。
    public static func display(today: MenuBarToday?, entries: [MenuBarQuotaEntry]?,
                               provider: String?, yi: Bool = false) -> MenuBarDisplay {
        let tokensText = today.map { fmtTokens(Double($0.tokens), yi: yi) } ?? "—"
        let tokensOnly = provider == "tokens"
        guard let provider, provider != "off", !tokensOnly else {
            return MenuBarDisplay(tokensText: tokensText, hasTokens: today != nil,
                                  quota: nil, tokensOnly: tokensOnly)
        }
        let entry = (entries ?? []).first { $0.id == provider }
        let name = (entry?.name.isEmpty == false ? entry?.name : nil)
            ?? providerName[provider] ?? provider
        let glyph = providerGlyph[provider] ?? String(name.prefix(1)).uppercased()
        let best = bestWindow(entry)
        let pct = best?.pct.map { max(0, min(100, $0)) }
        let urgency: MenuBarDisplay.Urgency
        switch pct.map({ quotaUrgency($0) }) {
        case "quota_crit": urgency = .crit
        case "quota_warn": urgency = .warn
        case "quota_ok": urgency = .ok
        default: urgency = .none
        }
        let quota = MenuBarDisplay.Quota(
            providerID: provider, glyph: glyph, name: name, brandHex: toolHex[provider],
            pct: pct, approximate: best.map { quotaMarker($0) == "≈" } ?? false, urgency: urgency)
        return MenuBarDisplay(tokensText: tokensText, hasTokens: today != nil,
                              quota: quota, tokensOnly: false)
    }
}
