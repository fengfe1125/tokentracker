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
                Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                if !compact { Text(title).font(.callout).lineLimit(1) }
            }
            .fixedSize()
            .fontWeight(selected ? .semibold : .regular)
            .foregroundStyle(selected ? Color.brand : Color.secondary)
            .padding(.horizontal, compact ? 9 : 11)
            .padding(.vertical, 5)
            .background {
                if selected {
                    Capsule().fill(Color.brand.opacity(0.14))
                        .matchedGeometryEffect(id: "pill", in: pill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
