//
//  DesignSystem.swift
//  TokenTrackerApp
//
//  主面板共用的视觉基础：间距、卡片表面、Token 四类配色、指标块、占比条，
//  以及把页面标题与操作挂到窗口工具栏的 pageChrome。
//  各页面不再各自定义卡片背景和阴影。
//

import AppKit
import SwiftUI

enum Metrics {
    static let pagePadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 16
    static let gridSpacing: CGFloat = 12
    static let cardRadius: CGFloat = 12
    static let cardPadding: CGFloat = 16
}

extension Color {
    /// 卡片表面：浅色为白，深色为叠在窗口背景上的一层微亮。
    static let cardSurface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.06) : .white
    })
    static let cardBorder = Color.primary.opacity(0.07)
    static let costSeries = Color.pink
}

private struct CardSurface: ViewModifier {
    let padding: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
        content
            .padding(padding)
            .background(Color.cardSurface, in: shape)
            .overlay(shape.strokeBorder(Color.cardBorder))
    }
}

extension View {
    /// 统一卡片：内边距 + 表面 + 细描边（不用阴影，深色模式下同样可辨）。
    func card(padding: CGFloat = Metrics.cardPadding) -> some View {
        modifier(CardSurface(padding: padding))
    }

    /// 页面标题、副标题与操作统一进窗口工具栏。
    func pageChrome<Actions: View>(title: String, subtitle: String? = nil,
                                   @ViewBuilder actions: @escaping () -> Actions) -> some View {
        navigationTitle(title)
            .navigationSubtitle(subtitle ?? "")
            .toolbar { ToolbarItemGroup(placement: .primaryAction) { actions() } }
    }

    func pageChrome(title: String, subtitle: String? = nil) -> some View {
        navigationTitle(title).navigationSubtitle(subtitle ?? "")
    }
}

/// Token 的四个组成部分；构成条、趋势图和图例共用同一套名称与颜色。
enum TokenKind: String, CaseIterable, Identifiable {
    case cacheRead, input, cacheWrite, output

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cacheRead: L10n.text("缓存命中")
        case .input: L10n.text("非缓存输入")
        case .cacheWrite: L10n.text("缓存创建")
        case .output: L10n.text("输出")
        }
    }

    var color: Color {
        switch self {
        case .cacheRead: .indigo
        case .input: .blue
        case .cacheWrite: .orange
        case .output: .green
        }
    }
}

/// 卡片标题行：左标题，右侧放次要说明或操作。
struct CardHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension CardHeader where Trailing == EmptyView {
    init(title: String) { self.init(title: title) { EmptyView() } }
}

/// 指标块：小标题 + 大数字 + 一行说明，可在底部附加内容（如进度条）。
struct StatTile<Footer: View>: View {
    let title: String
    let value: String
    var caption: String?
    var tint: Color = .primary
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let caption {
                Text(caption)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .help(caption)
            }
            footer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
        .accessibilityElement(children: .combine)
    }
}

extension StatTile where Footer == EmptyView {
    init(title: String, value: String, caption: String? = nil, tint: Color = .primary) {
        self.init(title: title, value: value, caption: caption, tint: tint) { EmptyView() }
    }
}

/// 细进度条（0...1）。
struct MeterBar: View {
    let fraction: Double
    var tint: Color = .green
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.15))
                Capsule().fill(tint)
                    .frame(width: geo.size.width * max(0, min(1, fraction)))
            }
        }
        .frame(height: height)
    }
}

/// 排行行：名称在左、数值在右，底部一条按占比填充的细条。
struct ShareRow<Leading: View>: View {
    let fraction: Double
    let tint: Color
    let primary: String
    var secondary: String?
    @ViewBuilder let leading: () -> Leading

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                leading()
                Spacer(minLength: 8)
                Text(primary)
                    .font(.callout.monospacedDigit())
                    .lineLimit(1)
                if let secondary {
                    Text(secondary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 64, alignment: .trailing)
                }
            }
            MeterBar(fraction: fraction, tint: tint, height: 3)
        }
        .padding(.vertical, 5)
    }
}

private struct UnitYiKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// 设置项「大数以亿显示」；由 RootView 注入，页面不再各自读 settings 字典。
    var unitYi: Bool {
        get { self[UnitYiKey.self] }
        set { self[UnitYiKey.self] = newValue }
    }
}

private struct HoverHighlight: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.05) : .clear)
            .onHover { hovering = $0 }
    }
}

extension View {
    /// 可点按行的悬停反馈。
    func hoverHighlight() -> some View { modifier(HoverHighlight()) }
}
