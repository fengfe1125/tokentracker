//
//  DesignSystem.swift
//  TokenTrackerApp
//
//  主面板共用的视觉基础：间距、卡片表面、Token 四类配色、指标块、占比条，
//  以及把页面标题与操作交给固定页面栏的 pageChrome。
//  各页面不再各自定义卡片背景和阴影。
//

import AppKit
import SwiftUI
import TokenTrackerCore

enum Metrics {
    static let pagePadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 16
    static let gridSpacing: CGFloat = 12
    static let cardRadius: CGFloat = 16
    static let cardPadding: CGFloat = 16
}

extension Color {
    /// 卡片表面：浅色为白，深色为叠在窗口背景上的一层微亮。
    static let cardSurface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.06) : .white
    })
    static let cardBorder = Color.primary.opacity(0.07)
    /// 卡片内的下沉面板、输入底色
    static let sunkSurface = Color.primary.opacity(0.05)
    /// 强调色：导航选中、主按钮、图表主色
    static let brand = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.66, green: 0.55, blue: 1.0, alpha: 1)
            : NSColor(red: 0.48, green: 0.31, blue: 0.88, alpha: 1)
    })
    static let costSeries = Color.pink
}

private struct CardSurface: ViewModifier {
    let padding: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
        content
            .padding(padding)
            .background(Color.cardSurface, in: shape)
    }
}

extension View {
    /// 统一卡片：内边距 + 表面，不描边也不用阴影。
    func card(padding: CGFloat = Metrics.cardPadding) -> some View {
        modifier(CardSurface(padding: padding))
    }

    /// 页面标题、副标题与操作交给 RootView 的固定页面栏显示，不进窗口工具栏：
    /// 工具栏只放导航和扫描，切页时不增删项目，导航标签就不会跟着挪。
    func pageChrome<Actions: View>(title: String, subtitle: String? = nil,
                                   @ViewBuilder leading: () -> some View = { EmptyView() },
                                   @ViewBuilder actions: () -> Actions) -> some View {
        preference(key: PageChromeKey.self,
                   value: PageChrome(title: title, subtitle: subtitle ?? "",
                                     leading: AnyView(leading()), actions: AnyView(actions())))
    }

    /// 卡片里的下沉面板。
    func sunkPanel(padding: CGFloat = 12, radius: CGFloat = 12) -> some View {
        self.padding(padding)
            .background(Color.sunkSurface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    func pageChrome(title: String, subtitle: String? = nil) -> some View {
        pageChrome(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// 当前页面交给页面栏的标题与操作。
struct PageChrome {
    var title: String
    var subtitle: String
    var leading: AnyView
    var actions: AnyView
}

struct PageChromeKey: PreferenceKey {
    static var defaultValue: PageChrome? { nil }
    static func reduce(value: inout PageChrome?, nextValue: () -> PageChrome?) {
        if let next = nextValue() { value = next }
    }
}

/// 页面栏控件共用尺寸与表面：分段胶囊、下拉筛选胶囊、搜索框与图标按钮保持同一高度和质感。
enum PageControl {
    static let height: CGFloat = 30
    static let thumbInset: CGFloat = 3
    static let thumbHeight: CGFloat = height - thumbInset * 2
    static let fontSize: CGFloat = 12.5

    /// 分段底轨：浅色略深于窗口底色，深色为微亮凹槽，让浮起滑块清晰立住。
    static let trackFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.07)
            : NSColor(white: 0, alpha: 0.055)
    })

    static let trackBorder = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.06)
            : NSColor(white: 0, alpha: 0.04)
    })

    /// 浮起表面：分段当前滑块、筛选胶囊与搜索框共用。
    static let pillSurface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.12)
            : .white
    })

    static let pillBorder = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.11)
            : NSColor(white: 0, alpha: 0.08)
    })

    static let pillBorderHover = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.18)
            : NSColor(white: 0, alpha: 0.15)
    })

    static let pillShadow = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0, alpha: 0.22)
            : NSColor(white: 0, alpha: 0.06)
    })
}

struct SegmentedOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }
}

private struct SegmentBoundsKey<Value: Hashable>: PreferenceKey {
    static var defaultValue: [Value: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [Value: Anchor<CGRect>],
                       nextValue: () -> [Value: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct SegmentPressStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        BodyView(configuration: configuration, isPressed: $isPressed)
    }

    private struct BodyView: View {
        let configuration: Configuration
        @Binding var isPressed: Bool

        var body: some View {
            configuration.label
                .onChange(of: configuration.isPressed) { _, value in
                    isPressed = value
                }
                .onDisappear {
                    if isPressed { isPressed = false }
                }
        }
    }
}

/// 胶囊分段控件：浅灰凹槽底轨 + 单一持久白色物理滑块，按压微缩反馈 + 弹簧连续滑动，无淡入淡出残影。
struct SegmentedPillPicker<Value: Hashable>: View {
    let accessibilityTitle: String
    @Binding var selection: Value
    let options: [SegmentedOption<Value>]

    @State private var hovered: Value?
    @State private var pressed: Value?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let selected = selection == option.value
                let isHovered = hovered == option.value && !selected
                let isPressed = pressed == option.value
                Button {
                    guard selection != option.value else { return }
                    selection = option.value
                } label: {
                    // 按 medium 字重预留宽度，选中加粗不挤压相邻项
                    Text(option.title)
                        .font(.system(size: PageControl.fontSize, weight: .medium))
                        .lineLimit(1)
                        .hidden()
                        .overlay {
                            Text(option.title)
                                .font(.system(size: PageControl.fontSize,
                                              weight: selected ? .medium : .regular))
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .foregroundStyle(selected ? Color.primary
                                         : (isHovered || isPressed ? Color.primary.opacity(0.88) : Color.secondary))
                        .scaleEffect(isPressed ? 0.96 : 1.0)
                        .padding(.horizontal, 11)
                        .frame(height: PageControl.thumbHeight)
                        .contentShape(Capsule())
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: selected)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
                        .animation(reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.82), value: isPressed)
                }
                .buttonStyle(SegmentPressStyle(isPressed: Binding(
                    get: { pressed == option.value },
                    set: { active in
                        if active {
                            pressed = option.value
                        } else if pressed == option.value {
                            pressed = nil
                        }
                    }
                )))
                .anchorPreference(key: SegmentBoundsKey<Value>.self, value: .bounds) { [option.value: $0] }
                .onHover { hovering in
                    if hovering {
                        hovered = option.value
                    } else if hovered == option.value {
                        hovered = nil
                    }
                }
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .backgroundPreferenceValue(SegmentBoundsKey<Value>.self) { anchors in
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    // 悬停 / 按下底色严格位于滑块下方，各自独立淡入淡出，不干扰滑块轨迹
                    ZStack(alignment: .topLeading) {
                        if let highlight = (pressed != selection ? pressed : nil)
                            ?? (hovered != selection ? hovered : nil),
                           let anchor = anchors[highlight] {
                            let rect = proxy[anchor]
                            Capsule()
                                .fill(Color.primary.opacity(pressed == highlight ? 0.085 : 0.045))
                                .frame(width: rect.width, height: rect.height)
                                .offset(x: rect.minX, y: rect.minY)
                                .id(highlight)
                                .transition(.opacity)
                        }
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: pressed)

                    // 单一持久物理滑块：绝不销毁重建，切换时按弹簧轨迹平滑滑动并自适应宽度
                    if let anchor = anchors[selection] {
                        let rect = proxy[anchor]
                        let thumbPressed = pressed == selection
                        Capsule()
                            .fill(PageControl.pillSurface)
                            .overlay(Capsule().strokeBorder(PageControl.pillBorder, lineWidth: 0.5))
                            .shadow(color: PageControl.pillShadow,
                                    radius: thumbPressed ? 1 : 2, x: 0, y: thumbPressed ? 0.5 : 1)
                            .frame(width: rect.width, height: rect.height)
                            .scaleEffect(thumbPressed ? 0.96 : 1.0)
                            .offset(x: rect.minX, y: rect.minY)
                            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.84),
                                       value: selection)
                            .animation(reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.82),
                                       value: thumbPressed)
                    }
                }
            }
            .allowsHitTesting(false)
        }
        .padding(PageControl.thumbInset)
        .frame(height: PageControl.height)
        .background(PageControl.trackFill, in: Capsule())
        .overlay(Capsule().strokeBorder(PageControl.trackBorder, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityTitle)
        .fixedSize()
    }
}

/// 页面栏下拉胶囊：保留原生 NSMenu 弹出交互，外框统一为 30pt 白色胶囊；激活筛选时叠加柔和语义底色。
struct PageMenuPill<Label: View, Content: View>: View {
    var activeTint: Color? = nil
    @ViewBuilder let label: () -> Label
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 6) {
                label()
                    .font(.system(size: PageControl.fontSize,
                                  weight: activeTint == nil ? .regular : .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(activeTint.map { $0.opacity(0.8) } ?? Color.secondary.opacity(0.75))
            }
            .foregroundStyle(Color.primary)
            .padding(.leading, 11)
            .padding(.trailing, 10)
            .frame(height: PageControl.height)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(PagePillButtonStyle(activeTint: activeTint))
        .fixedSize()
    }
}

private struct PagePillButtonStyle: ButtonStyle {
    let activeTint: Color?

    func makeBody(configuration: Configuration) -> some View {
        BodyView(configuration: configuration, activeTint: activeTint)
    }

    private struct BodyView: View {
        let configuration: Configuration
        let activeTint: Color?
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .background {
                    ZStack {
                        Capsule().fill(PageControl.pillSurface)
                        if let activeTint {
                            Capsule().fill(activeTint.opacity(pressed ? 0.18 : (hovering ? 0.13 : 0.09)))
                        } else if pressed {
                            Capsule().fill(Color.primary.opacity(0.055))
                        } else if hovering {
                            Capsule().fill(Color.primary.opacity(0.025))
                        }
                    }
                    .shadow(color: PageControl.pillShadow,
                            radius: pressed ? 0.5 : 1.5, x: 0, y: pressed ? 0 : 0.5)
                }
                .overlay {
                    Capsule().strokeBorder(borderColor(pressed: pressed),
                                           lineWidth: activeTint == nil ? 0.5 : 0.75)
                }
                .scaleEffect(pressed ? 0.97 : 1.0)
                .animation(reduceMotion ? nil : .spring(response: 0.20, dampingFraction: 0.82), value: pressed)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: activeTint != nil)
                .onHover { hovering = $0 }
        }

        private func borderColor(pressed: Bool) -> Color {
            if let activeTint {
                return activeTint.opacity(pressed ? 0.52 : (hovering ? 0.42 : 0.28))
            }
            return (hovering || pressed) ? PageControl.pillBorderHover : PageControl.pillBorder
        }
    }
}

/// 页面栏右侧操作组之间的细分隔线。
struct PageActionDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.09))
            .frame(width: 1, height: 14)
    }
}

/// 页面栏里的搜索框：与筛选胶囊同高（30pt）同圆角，聚焦时显示柔和的品牌色描边。
struct PageSearchField: View {
    @Binding var text: String
    let prompt: String

    @FocusState private var focused: Bool
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(focused ? Color.brand : Color.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: PageControl.fontSize))
                .focused($focused)
                .onExitCommand {
                    if !text.isEmpty { text = "" }
                    focused = false
                }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(L10n.text("清除搜索"))
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, text.isEmpty ? 10 : 8)
        .frame(height: PageControl.height)
        .background {
            Capsule()
                .fill(PageControl.pillSurface)
                .shadow(color: PageControl.pillShadow, radius: 1.5, x: 0, y: 0.5)
        }
        .overlay {
            Capsule()
                .strokeBorder(borderColor, lineWidth: focused ? 1.2 : 0.5)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: focused)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: text.isEmpty)
        .contentShape(Capsule())
        .onTapGesture { focused = true }
        .onHover { hovering = $0 }
    }

    private var borderColor: Color {
        if focused { return Color.brand.opacity(0.55) }
        return hovering ? PageControl.pillBorderHover : PageControl.pillBorder
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
        .animation(.easeOut(duration: 0.2), value: fraction)
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

/// 状态胶囊：文字 + 同色浅底。
struct Pill: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// 可选中的筛选胶囊。
struct FilterChip<Label: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { label() }
                .font(.callout)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .foregroundStyle(selected ? Color.brand : Color.secondary)
                .fontWeight(selected ? .semibold : .regular)
                .background(selected ? Color.brand.opacity(0.14) : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? .clear : Color.primary.opacity(0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 配额占用的颜色：充足绿、偏紧橙、告急红；没有数据时为灰。
func quotaColor(_ percent: Double?) -> Color {
    guard percent != nil else { return .secondary }
    switch MenuBarFmt.quotaUrgency(percent) {
    case "quota_crit": return .red
    case "quota_warn": return .orange
    default: return .green
    }
}

/// 订阅账号的代表色：有对应 Agent 的沿用 Agent 颜色。
func providerColor(_ provider: SubscriptionProvider) -> Color {
    MenuBarFmt.toolHex[provider.rawValue] == nil ? Color.brand : toolColor(provider.rawValue)
}
