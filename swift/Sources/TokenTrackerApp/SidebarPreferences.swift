import SwiftUI
import Foundation
import TokenTrackerCore

enum SidebarNavigationItem: String, CaseIterable, Identifiable {
    case overview, projects, reports, subscriptions, sessions, activity
    var id: String { rawValue }
    var selection: NavSelection {
        switch self {
        case .overview: .overview
        case .projects: .projects
        case .reports: .reports
        case .subscriptions: .subscriptions
        case .sessions: .sessions
        case .activity: .activity
        }
    }
    var title: String {
        switch self {
        case .overview: L10n.text("概览")
        case .projects: L10n.text("项目")
        case .reports: L10n.text("报告")
        case .subscriptions: L10n.text("订阅配额与余额")
        case .sessions: L10n.text("会话记录")
        case .activity: L10n.text("Agent 活动")
        }
    }
    var symbol: String {
        switch self {
        case .overview: "chart.bar.fill"
        case .projects: "folder"
        case .reports: "doc.text"
        case .subscriptions: "creditcard"
        case .sessions: "list.bullet.rectangle"
        case .activity: "point.3.connected.trianglepath.dotted"
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
        result.navigation = complete(navigation, defaults: Self().navigation)
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
