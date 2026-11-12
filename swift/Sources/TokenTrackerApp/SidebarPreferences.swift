import SwiftUI
import Foundation
import TokenTrackerCore

enum SidebarNavigationItem: String, CaseIterable, Identifiable {
    case overview, usage, activity, reports, accounts
    var id: String { rawValue }
    var selection: NavSelection {
        switch self {
        case .overview: .overview
        case .usage: .usage
        case .activity: .activity
        case .reports: .reports
        case .accounts: .accounts
        }
    }
    var title: String {
        switch self {
        case .overview: L10n.text("概览")
        case .usage: L10n.text("用量")
        case .activity: L10n.text("活动")
        case .reports: L10n.text("报告")
        case .accounts: L10n.text("账号")
        }
    }
    var symbol: String {
        switch self {
        case .overview: "chart.bar.fill"
        case .usage: "list.bullet.rectangle"
        case .activity: "point.3.connected.trianglepath.dotted"
        case .reports: "doc.text"
        case .accounts: "creditcard"
        }
    }
}

enum SidebarGroup { case navigation, agents }

struct SidebarLayout: Codable, Equatable {
    var navigation = SidebarNavigationItem.allCases.map(\.rawValue)
    var agents = ScannerRegistry.all
    var hiddenNavigation: Set<String> = []
    var hiddenAgents: Set<String> = []

    func normalized() -> Self {
        var result = self
        func complete(_ saved: [String], defaults: [String]) -> [String] {
            var seen: Set<String> = []
            return (saved + defaults).filter { defaults.contains($0) && seen.insert($0).inserted }
        }
        // v0.5.9 及更早保存的入口：项目 / 会话并入「用量」，订阅并入「账号」，位置沿用原来的
        let merged = ["projects": "usage", "sessions": "usage", "subscriptions": "accounts"]
        result.navigation = complete(navigation.map { merged[$0] ?? $0 }, defaults: Self().navigation)
        result.agents = complete(agents, defaults: Self().agents)
        result.hiddenNavigation.formIntersection(result.navigation)
        result.hiddenAgents.formIntersection(result.agents)
        return result
    }
}

/// App-only presentation preferences; never changes scanning or the shared usage schema.
@MainActor
final class SidebarPreferences: ObservableObject {
    static let shared = SidebarPreferences(defaults:
        ProcessInfo.processInfo.environment["TT_UI_PREVIEW"] == "1"
            ? UserDefaults(suiteName: "com.tokentracker.sidebar.preview")! : .standard)
    private static let key = "sidebarLayoutV1"
    private let defaults: UserDefaults
    @Published private(set) var layout: SidebarLayout

    init(defaults: UserDefaults) {
        self.defaults = defaults
        layout = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(SidebarLayout.self, from: $0) }?
            .normalized() ?? SidebarLayout()
    }

    func order(_ group: SidebarGroup) -> [String] {
        group == .navigation ? layout.navigation : layout.agents
    }

    func isVisible(_ id: String, in group: SidebarGroup) -> Bool {
        !(group == .navigation ? layout.hiddenNavigation : layout.hiddenAgents).contains(id)
    }

    func setVisible(_ id: String, in group: SidebarGroup, visible: Bool) {
        guard order(group).contains(id) else { return }
        var next = layout
        if group == .navigation {
            if visible { next.hiddenNavigation.remove(id) } else { next.hiddenNavigation.insert(id) }
        } else {
            if visible { next.hiddenAgents.remove(id) } else { next.hiddenAgents.insert(id) }
        }
        save(next)
    }

    func move(_ id: String, in group: SidebarGroup, by offset: Int) {
        var ids = order(group)
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        var next = layout
        if group == .navigation { next.navigation = ids } else { next.agents = ids }
        save(next)
    }

    func move(in group: SidebarGroup, from offsets: IndexSet, to destination: Int) {
        var ids = order(group)
        guard !offsets.isEmpty, offsets.allSatisfy(ids.indices.contains),
              (0...ids.count).contains(destination) else { return }
        ids.move(fromOffsets: offsets, toOffset: destination)
        var next = layout
        if group == .navigation { next.navigation = ids } else { next.agents = ids }
        save(next)
    }

    func reset() { save(SidebarLayout()) }

    private func save(_ next: SidebarLayout) {
        let next = next.normalized()
        guard let data = try? JSONEncoder().encode(next) else { return }
        defaults.set(data, forKey: Self.key)
        layout = next
    }
}
