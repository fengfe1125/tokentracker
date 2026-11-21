//
//  TopTabBar.swift
//  TokenTrackerApp
//
//  主窗口顶栏的导航标签：放在窗口工具栏中间，取代原来的侧栏。
//  顺序与显隐沿用设置里的导航项；设置固定在最后，用齿轮图标。
//

import SwiftUI

struct TopTabBar: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject private var sidebar = SidebarPreferences.shared
    @ObservedObject var state: AppState
    /// 窗口较窄时只显示图标
    var compact = false

    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 当前可见的导航项，按用户设置的顺序。
    static func items(_ sidebar: SidebarPreferences) -> [SidebarNavigationItem] {
        sidebar.layout.navigation.compactMap(SidebarNavigationItem.init(rawValue:))
            .filter { sidebar.isVisible($0.id, in: .navigation) }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.items(sidebar)) { item in
                tab(item.selection, title: item.title, symbol: item.symbol)
            }
            tab(.settings, title: L10n.text("设置"), symbol: "gearshape")
        }
        // 只让选中胶囊滑动，页面内容直接切换
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: state.selection)
    }

    private func tab(_ target: NavSelection, title: String, symbol: String) -> some View {
        let selected = state.selection == target
        return Button {
            state.selection = target
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: ToolbarChip.iconSize, weight: .medium))
                    .frame(width: ToolbarChip.iconSize + 4)
                if !compact {
                    // 按粗体预留宽度：选中变粗不会把整排标签撑宽、让它左右挪
                    Text(title).font(.callout).fontWeight(.semibold).lineLimit(1)
                        .hidden()
                        .overlay {
                            Text(title).font(.callout)
                                .fontWeight(selected ? .semibold : .regular)
                                .lineLimit(1)
                                .fixedSize()
                        }
                }
            }
            .fixedSize()
            .foregroundStyle(selected ? Color.brand : Color.secondary)
            .frame(minWidth: ToolbarChip.height)
            .padding(.horizontal, compact ? 4 : 10)
            .frame(height: ToolbarChip.height)
            .background {
                if selected {
                    Capsule().fill(Color.brand.opacity(0.14))
                        .matchedGeometryEffect(id: "pill", in: pill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(ToolbarChipStyle())
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 工具栏里导航标签与扫描按钮共用的尺寸：同样的图标大小、高度和胶囊，窄窗口只剩图标时比例也一致。
enum ToolbarChip {
    static let iconSize: CGFloat = 14
    static let height: CGFloat = 30
}

/// 工具栏小按钮：悬停浅色胶囊、按下变淡，不用系统工具栏按钮的边框。
/// `icon` 为真时按图标按钮排版（页面栏里的预算、导出、更多…）：灰色图标，至少 28pt 见方。
struct ToolbarChipStyle: ButtonStyle {
    var icon = false

    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration, icon: icon)
    }

    private struct ChipBody: View {
        let configuration: Configuration
        let icon: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let pressed = configuration.isPressed && enabled
            label
                .background {
                    Capsule().fill(Color.primary.opacity(pressed ? 0.10 : (hovering && enabled ? 0.06 : 0)))
                }
                .scaleEffect(pressed ? 0.94 : 1.0)
                .opacity(enabled ? 1 : 0.45)
                .animation(reduceMotion ? nil : .spring(response: 0.20, dampingFraction: 0.80), value: pressed)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
                .onHover { hovering = $0 }
        }

        @ViewBuilder
        private var label: some View {
            if icon {
                configuration.label
                    .labelStyle(.iconOnly)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: ToolbarChip.height, minHeight: ToolbarChip.height)
                    .contentShape(Capsule())
            } else {
                configuration.label
            }
        }
    }
}

extension ButtonStyle where Self == ToolbarChipStyle {
    /// 页面栏图标按钮
    static var pageIcon: ToolbarChipStyle { ToolbarChipStyle(icon: true) }
}
