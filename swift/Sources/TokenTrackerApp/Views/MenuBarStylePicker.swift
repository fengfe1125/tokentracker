//
//  MenuBarStylePicker.swift
//  TokenTrackerApp
//
//  设置 › 外观与状态栏 › 状态栏样式：三张带预览图的选择卡片。
//  预览由 MenuBarStyleRenderer 现场绘制（浅色 / 深色壁纸各一条），与状态栏实际效果一致。
//

import AppKit
import SwiftUI
import TokenTrackerCore

extension MenuBarStyle {
    var letter: String {
        switch self {
        case .native: return "A"
        case .stacked: return "B"
        case .capsule: return "C"
        }
    }

    var title: String {
        switch self {
        case .native: return L10n.text("原生单色")
        case .stacked: return L10n.text("双行仪表")
        case .capsule: return L10n.text("配额胶囊")
        }
    }

    var summary: String {
        switch self {
        case .native: return L10n.text("进度环内嵌平台字母，与系统图标同为单色，仅预警时上色。")
        case .stacked: return L10n.text("上行今日 Token，下行平台与百分比，竖条表示配额用量。")
        case .capsule: return L10n.text("品牌色头像加按用量填充的胶囊，告警最醒目，占位最宽。")
        }
    }
}

/// 样式预览用的示例数据：今日 4412 万 Token，当前平台配额已用 38%。
enum MenuBarStylePreview {
    static func sample(provider: String, entries: [MenuBarQuotaEntry], yi: Bool) -> MenuBarDisplay {
        let pid = (provider == "off" || provider == "tokens") ? (entries.first?.id ?? "claude") : provider
        let name = entries.first { $0.id == pid }?.name ?? MenuBarFmt.providerName[pid] ?? pid
        let entry = MenuBarQuotaEntry(id: pid, name: name, windows: [
            MenuBarQuotaWindow(pct: 38, source: "official", stale: false, label: "5h"),
        ])
        return MenuBarFmt.display(today: MenuBarToday(tokens: 44_120_000, cost: 0),
                                  entries: [entry], provider: pid, yi: yi)
    }
}

struct MenuBarStylePicker: View {
    @ObservedObject var state: AppState
    @ObservedObject private var language = LanguageManager.shared

    private var selection: MenuBarStyle { state.prefs.menubarStyle }
    private var sample: MenuBarDisplay {
        MenuBarStylePreview.sample(provider: state.prefs.menubarProvider, entries: state.quotaEntries,
                                   yi: state.prefs.unitYi && !L10n.isEnglish)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("状态栏样式"))
                Text(L10n.text("预览为示例数据；右键状态栏图标也可切换。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 10) {
                ForEach(MenuBarStyle.allCases) { style in
                    card(style)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func card(_ style: MenuBarStyle) -> some View {
        let selected = style == selection
        return Button {
            guard !selected else { return }
            state.updateSetting(key: "menubar_style", value: style.rawValue)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                VStack(spacing: 4) {
                    preview(style, dark: false)
                    preview(style, dark: true)
                }
                HStack(spacing: 6) {
                    Text(verbatim: style.letter)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(selected ? Color.accentColor : Color.secondary.opacity(0.6),
                                    in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
                    Text(style.title)
                        .font(.callout.weight(.semibold))
                    if style == .default {
                        Text(L10n.text("默认"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                }
                Text(style.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Color.sunkSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08),
                                  lineWidth: selected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(style.letter) \(style.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private static let scale: CGFloat = 1.3

    private func preview(_ style: MenuBarStyle, dark: Bool) -> some View {
        let image = MenuBarStyleRenderer.image(
            display: sample, style: style, compact: false, anim: MenuBarAnimation(),
            labels: StatusItemController.labels,
            appearance: NSAppearance(named: dark ? .darkAqua : .aqua), scale: Self.scale)
        return ZStack {
            LinearGradient(
                colors: dark
                    ? [Color(red: 0.11, green: 0.13, blue: 0.21), Color(red: 0.20, green: 0.16, blue: 0.29),
                       Color(red: 0.24, green: 0.17, blue: 0.20)]
                    : [Color(red: 0.78, green: 0.85, blue: 0.95), Color(red: 0.93, green: 0.84, blue: 0.89),
                       Color(red: 0.96, green: 0.90, blue: 0.81)],
                startPoint: .leading, endPoint: .trailing)
            Image(nsImage: image)
                .frame(width: image.size.width, height: image.size.height)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityHidden(true)
    }
}
