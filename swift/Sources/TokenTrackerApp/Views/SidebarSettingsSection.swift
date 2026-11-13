import SwiftUI

struct SidebarSettingsSection: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject private var sidebar = SidebarPreferences.shared
    @State private var navigationExpanded = true
    @State private var agentsExpanded = true

    var body: some View {
        Section(L10n.text("导航")) {
            Text(L10n.text("勾选要显示的项目，拖动右侧手柄调整顺序。Agent 的顺序用于筛选菜单和菜单栏面板；隐藏 Agent 不影响用量扫描。"))
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup(L10n.text("导航项"), isExpanded: $navigationExpanded) { rows(.navigation) }
            DisclosureGroup("Agent", isExpanded: $agentsExpanded) { rows(.agents) }
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
                        .toggleStyle(.checkbox)
                    Spacer()
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.secondary)
                        .help(L10n.text("拖动排序"))
                        .accessibilityLabel(L10n.text("拖动排序") + " " + title(id, group))
                }
                .frame(height: 28)
                .contentShape(Rectangle())
                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 8))
                .listRowSeparator(.hidden)
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
        .frame(height: CGFloat(ids.count) * 36 + 12)
    }

    private func title(_ id: String, _ group: SidebarGroup) -> String {
        group == .navigation ? SidebarNavigationItem(rawValue: id)?.title ?? id : toolDisplayName(id)
    }
}
