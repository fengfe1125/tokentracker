import SwiftUI

/// 设置 › 导航：顶栏导航项与 Agent 的显隐和顺序。
struct SidebarSettingsSection: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject private var sidebar = SidebarPreferences.shared

    var body: some View {
        SettingsSection(L10n.text("导航项"),
                        footer: L10n.text("勾选要显示的项目，拖动右侧手柄调整顺序。Agent 的顺序用于筛选菜单和菜单栏面板；隐藏 Agent 不影响用量扫描。")) {
            rows(.navigation)
        }
        SettingsSection("Agent") {
            rows(.agents)
        }
        HStack {
            Spacer()
            Button(L10n.text("恢复默认导航")) { sidebar.reset() }
        }
    }

    private func rows(_ group: SidebarGroup) -> some View {
        let ids = sidebar.order(group)
        return List {
            ForEach(ids, id: \.self) { id in
                HStack {
                    Toggle(title(id, group), isOn: Binding(
                        get: { sidebar.isVisible(id, in: group) },
                        set: { sidebar.setVisible(id, in: group, visible: $0) }))
                        .toggleStyle(SettingsCheckboxStyle())
                    Spacer()
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.tertiary)
                        .help(L10n.text("拖动排序"))
                        .accessibilityLabel(L10n.text("拖动排序") + " " + title(id, group))
                }
                .frame(height: 30)
                .contentShape(Rectangle())
                .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
                .listRowBackground(Color.clear)
                .accessibilityAction(named: L10n.text("上移")) { sidebar.move(id, in: group, by: -1) }
                .accessibilityAction(named: L10n.text("下移")) { sidebar.move(id, in: group, by: 1) }
            }
            .onMove { offsets, destination in
                sidebar.move(in: group, from: offsets, to: destination)
            }
        }
        .listStyle(.plain)
        .scrollDisabled(true)
        .scrollContentBackground(.hidden)
        .frame(height: CGFloat(ids.count) * 35 + 10)
        .padding(.vertical, 2)
    }

    private func title(_ id: String, _ group: SidebarGroup) -> String {
        group == .navigation ? SidebarNavigationItem(rawValue: id)?.title ?? id : toolDisplayName(id)
    }
}
