//
//  SettingsComponents.swift
//  TokenTrackerApp
//
//  设置页的统一积木：分组卡片（标题 + 白色卡片 + 脚注）、行（左标题与说明，右控件）、
//  行间分隔线。和其他页面用同一套卡片表面，不再用系统 grouped Form 的灰色分组。
//

import AppKit
import SwiftUI

/// 一组设置：小标题、白色卡片里的若干行、卡片下的脚注。
struct SettingsSection<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(padding: 0)
            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// 一行设置：左边标题与可选说明，右边控件。
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: () -> Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }
}

extension SettingsRow where Control == EmptyView {
    init(_ title: String, detail: String? = nil) {
        self.init(title, detail: detail) { EmptyView() }
    }
}

/// 开关行。
struct SettingsToggle: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        SettingsRow(title, detail: detail) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(SettingsSwitchStyle())
                .accessibilityLabel(title)
        }
    }
}

/// 设置页开关样式：系统绿开启态 + 柔和中性关闭态，按压微拉伸 + 弹簧滑动，避免继承窗口品牌紫。
struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        SwitchBody(configuration: configuration)
    }

    private struct SwitchBody: View {
        let configuration: Configuration
        @State private var hovering = false
        @State private var pressing = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private static let trackWidth: CGFloat = 34
        private static let trackHeight: CGFloat = 20
        private static let inset: CGFloat = 2
        private static let knobHeight: CGFloat = trackHeight - inset * 2

        private static let offTrack = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.18)
                : NSColor(white: 0, alpha: 0.14)
        })

        private static let offTrackHover = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.24)
                : NSColor(white: 0, alpha: 0.20)
        })

        var body: some View {
            let on = configuration.isOn
            let knobWidth: CGFloat = (pressing && enabled) ? Self.knobHeight + 3 : Self.knobHeight
            Button {
                configuration.isOn.toggle()
            } label: {
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule()
                        .fill(on ? Color(nsColor: .systemGreen)
                              : (hovering && enabled ? Self.offTrackHover : Self.offTrack))
                        .frame(width: Self.trackWidth, height: Self.trackHeight)
                    Capsule()
                        .fill(Color.white)
                        .shadow(color: Color.black.opacity(0.18), radius: 1.5, x: 0, y: 0.5)
                        .frame(width: knobWidth, height: Self.knobHeight)
                        .padding(Self.inset)
                }
                .contentShape(Capsule())
                .opacity(enabled ? 1 : 0.45)
                .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.78), value: on)
                .animation(reduceMotion ? nil : .spring(response: 0.16, dampingFraction: 0.82), value: pressing)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
            }
            .buttonStyle(PressTrackingButtonStyle(isPressed: $pressing))
            .onHover { hovering = $0 }
            .accessibilityValue(on ? "On" : "Off")
        }
    }
}

/// 设置页复选框样式：中性深灰勾选框 + 弹簧按压，替代整排刺眼的亮紫色复选框。
struct SettingsCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        CheckboxBody(configuration: configuration)
    }

    private struct CheckboxBody: View {
        let configuration: Configuration
        @State private var hovering = false
        @State private var pressing = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private static let checkedFill = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.88, alpha: 1)
                : NSColor(white: 0.18, alpha: 1)
        })

        private static let checkColor = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.10, alpha: 1)
                : .white
        })

        var body: some View {
            let checked = configuration.isOn
            Button {
                configuration.isOn.toggle()
            } label: {
                HStack(spacing: 9) {
                    ZStack {
                        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
                        shape
                            .fill(checked ? Self.checkedFill
                                  : Color.primary.opacity(hovering && enabled ? 0.06 : 0.025))
                            .overlay {
                                if !checked {
                                    shape.strokeBorder(
                                        Color.primary.opacity(hovering && enabled ? 0.36 : 0.22),
                                        lineWidth: 1
                                    )
                                }
                            }
                        if checked {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(Self.checkColor)
                                .transition(.scale(scale: 0.5).combined(with: .opacity))
                        }
                    }
                    .frame(width: 17, height: 17)
                    .scaleEffect(pressing && enabled ? 0.88 : 1.0)
                    configuration.label
                }
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.45)
                .animation(reduceMotion ? nil : .spring(response: 0.20, dampingFraction: 0.78), value: checked)
                .animation(reduceMotion ? nil : .spring(response: 0.16, dampingFraction: 0.82), value: pressing)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
            }
            .buttonStyle(PressTrackingButtonStyle(isPressed: $pressing))
            .onHover { hovering = $0 }
        }
    }
}

/// 设置卡片内的胶囊下拉菜单：原生 NSMenu 交互 + 卡片内中性胶囊表面，消除系统紫色箭头方块。
struct SettingsMenuPicker<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: PageControl.fontSize))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 11)
            .padding(.trailing, 9)
            .frame(height: 28)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(SettingsCardPillButtonStyle())
        .fixedSize()
    }
}

private struct SettingsCardPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BodyView(configuration: configuration)
    }

    private struct BodyView: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private static let surface = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.08)
                : NSColor(white: 0, alpha: 0.045)
        })

        private static let surfaceHover = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.12)
                : NSColor(white: 0, alpha: 0.075)
        })

        private static let surfacePressed = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.16)
                : NSColor(white: 0, alpha: 0.11)
        })

        var body: some View {
            let pressed = configuration.isPressed && enabled
            configuration.label
                .background {
                    Capsule().fill(pressed ? Self.surfacePressed
                                   : (hovering && enabled ? Self.surfaceHover : Self.surface))
                }
                .overlay {
                    Capsule().strokeBorder(
                        hovering && enabled ? PageControl.pillBorderHover : PageControl.pillBorder,
                        lineWidth: 0.5
                    )
                }
                .scaleEffect(pressed ? 0.97 : 1.0)
                .opacity(enabled ? 1 : 0.45)
                .animation(reduceMotion ? nil : .spring(response: 0.20, dampingFraction: 0.82), value: pressed)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

/// 设置页主操作按钮：高对比中性胶囊（浅色深炭黑 / 深色浅白），取代刺眼的紫色 prominent 按钮。
struct SettingsPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BodyView(configuration: configuration)
    }

    private struct BodyView: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private static let fill = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.90, alpha: 1)
                : NSColor(white: 0.15, alpha: 1)
        })

        private static let fillHover = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.97, alpha: 1)
                : NSColor(white: 0.24, alpha: 1)
        })

        private static let foreground = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.10, alpha: 1)
                : .white
        })

        var body: some View {
            let pressed = configuration.isPressed && enabled
            configuration.label
                .font(.system(size: PageControl.fontSize, weight: .medium))
                .foregroundStyle(Self.foreground)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(hovering && enabled ? Self.fillHover : Self.fill, in: Capsule())
                .scaleEffect(pressed ? 0.96 : 1.0)
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Capsule())
                .animation(reduceMotion ? nil : .spring(response: 0.20, dampingFraction: 0.82), value: pressed)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

/// 透传按压状态的轻量 ButtonStyle，供自定义开关与复选框复用。
private struct PressTrackingButtonStyle: ButtonStyle {
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

/// 卡片内行与行之间的分隔线，左侧与文字对齐。
struct SettingsDivider: View {
    var body: some View { Divider().padding(.leading, 16) }
}

/// 状态小标签：已配置 / 未配置 等。
struct SettingsBadge: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

/// 卡片内可折叠标题行：左对齐与其他 SettingsRow 完全一致，右侧带旋转箭头。
struct SettingsDisclosureRow<LabelContent: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder var label: () -> LabelContent

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 12) {
                label()
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
