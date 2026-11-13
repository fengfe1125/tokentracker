//
//  PortsModel.swift
//  TokenTrackerApp
//
//  端口页与状态栏面板共用的状态：本机监听端口、匹配到的开发项目、启动 / 停止。
//  扫描在后台线程做；只有端口页或面板可见时才定时刷新。结果只在内存里。
//

import AppKit
import Foundation
import SwiftUI
import TokenTrackerCore

@MainActor
final class PortsModel: ObservableObject {
    struct Project: Identifiable, Equatable {
        var id: String
        var name: String
        /// 项目根目录；目录已不存在时为 nil（不能启动）
        var root: String?
        var detected: StartCommand?
        /// 用户手填的命令，优先于自动识别
        var manual: String?
        /// 开发进程占用的端口；「运行中」和「停止」只看这些
        var ports: [ListeningPort]
        /// Agent 自己占用的端口：归在项目下显示，停止项目时不动
        var agentPorts: [ListeningPort] = []

        var command: String? { manual ?? detected?.command }
        var running: Bool { !ports.isEmpty }
    }

    enum Filter: Hashable { case all, matched, unmatched }

    /// 等用户确认的动作；确认前什么都不做
    enum Pending: Equatable {
        case closePort(Int)
        case forceClosePort(Int)
        case stopProject(String)
    }

    @Published private(set) var ports: [ListeningPort] = []
    @Published private(set) var projects: [Project] = []
    @Published private(set) var scanning = false
    @Published private(set) var loaded = false
    @Published var filter = Filter.all
    @Published var selectedPort: Int?
    @Published var pending: Pending?
    @Published var editingProject: String?
    /// 刚点了启动、还没看到端口的项目
    @Published private(set) var starting: Set<String> = []
    /// 发过结束信号后仍在监听的端口：界面提供「强制结束」
    @Published private(set) var stubborn: Set<Int> = []
    @Published private var noticeTemplate: L10n.Template?
    var notice: String? { noticeTemplate.map(L10n.text) }

    private let path: String
    private let settings: SettingsStore
    private let control = PortControl()
    private var watchers = 0
    private var timer: Timer?
    private var generation = 0
    /// 项目颜色按首次出现的顺序分配，刷新后不变
    private var colorIndex: [String: Int] = [:]

    init(path: String, settings: SettingsStore) {
        self.path = path
        self.settings = settings
    }

    // ------------------------------------------------------------ 读取 ----

    var matchedCount: Int { ports.filter { $0.projectID != nil }.count }
    var unmatchedCount: Int { ports.count - matchedCount }
    var runningProjects: Int { projects.filter(\.running).count }

    var visiblePorts: [ListeningPort] {
        switch filter {
        case .all: ports
        case .matched: ports.filter { $0.projectID != nil }
        case .unmatched: ports.filter { $0.projectID == nil }
        }
    }

    var selected: ListeningPort? { ports.first { $0.port == selectedPort } }

    func canClose(_ port: ListeningPort) -> Bool { control.canTerminate(port) }
    func isSystem(_ port: ListeningPort) -> Bool { PortControl.isSystem(port) }
    func isAgent(_ port: ListeningPort) -> Bool { PortControl.isAgent(port) }

    static let palette: [Color] = [.blue, .green, .orange, .pink, .teal, .indigo, .mint, .brown]

    func color(_ projectID: String?) -> Color {
        guard let projectID, let index = colorIndex[projectID] else { return .secondary }
        return Self.palette[index % Self.palette.count]
    }

    // ------------------------------------------------------------ 扫描 ----

    private struct Snapshot: Sendable {
        var ports: [ListeningPort]
        var projects: [Project]
    }

    /// 页面或面板出现时调用；成对调用 endWatching。
    func beginWatching() {
        watchers += 1
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(quiet: true) }
        }
    }

    func endWatching() {
        watchers = max(0, watchers - 1)
        if watchers == 0 {
            timer?.invalidate()
            timer = nil
        }
    }

    func refresh(quiet: Bool = false) {
        if !quiet { scanning = true }
        generation += 1
        let token = generation
        let path = path
        let commands = AppPreferences(values: settings.effective()).projectCommands
        Task {
            let snapshot = await Task.detached(priority: .utility) {
                Self.load(path: path, commands: commands)
            }.value
            guard token == generation else { return }
            apply(snapshot)
            scanning = false
            loaded = true
        }
    }

    private func apply(_ snapshot: Snapshot) {
        for project in snapshot.projects where colorIndex[project.id] == nil {
            colorIndex[project.id] = colorIndex.count
        }
        let animate = loaded && snapshot.ports.map(\.port) != ports.map(\.port)
        if animate {
            withAnimation(.snappy(duration: 0.3)) { ports = snapshot.ports }
        } else {
            ports = snapshot.ports
        }
        projects = snapshot.projects
        let listening = Set(snapshot.ports.map(\.port))
        stubborn.formIntersection(listening)
        starting = starting.filter { id in !(snapshot.projects.first { $0.id == id }?.running ?? false) }
        if let selectedPort, !listening.contains(selectedPort) {
            self.selectedPort = nil
            pending = nil
        }
        if case .stopProject(let id) = pending, !(projects.first { $0.id == id }?.running ?? false) {
            pending = nil
        }
    }

    private nonisolated static func load(path: String, commands: [String: String]) -> Snapshot {
        let store = try? UsageStore(path: path)
        let directories = (try? store?.projectDirectories()) ?? []
        let ports = PortMatcher.apply(PortScanner().scan(), directories: directories)

        // 「正在开发的项目」：本月有用量的项目，加上此刻占着端口的项目
        var summaries: [ProjectSummary] = (try? store?.projectSummaries(.period("month"), limit: 12)) ?? []
        summaries.removeAll { $0.id == "unassigned" }
        summaries.sort { ($0.lastActivity ?? 0) > ($1.lastActivity ?? 0) }
        var order = summaries.map { (id: $0.id, name: $0.name) }
        for port in ports {
            if let id = port.projectID, !order.contains(where: { $0.id == id }) {
                order.append((id, port.projectName ?? id))
            }
        }
        let projects = order.map { entry -> Project in
            var root = PortMatcher.root(projectID: entry.id, directories: directories)
            var isDirectory: ObjCBool = false
            if let candidate = root,
               !FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory) || !isDirectory.boolValue {
                root = nil
            }
            return Project(id: entry.id, name: entry.name, root: root,
                           detected: root.flatMap { StartCommandDetector.detect(directory: $0) },
                           manual: root.flatMap { commands[$0] },
                           ports: ports.filter { $0.projectID == entry.id && !PortControl.isAgent($0) },
                           agentPorts: ports.filter { $0.projectID == entry.id && PortControl.isAgent($0) })
        }
        // 运行中的排前面，其余保持最近活动顺序
        let sorted = projects.enumerated().sorted { a, b in
            a.element.running == b.element.running ? a.offset < b.offset : a.element.running
        }.map(\.element)
        return Snapshot(ports: ports, projects: sorted)
    }

    // ------------------------------------------------------------ 动作 ----

    func select(_ port: Int) {
        selectedPort = selectedPort == port ? nil : port
        pending = nil
    }

    func openInBrowser(_ port: Int) {
        if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
    }

    /// 用户已确认：结束占用这个端口的进程。
    func closePort(_ port: Int, force: Bool = false) {
        pending = nil
        guard let target = ports.first(where: { $0.port == port }) else { return }
        let failed = control.terminate([target], force: force)
        noticeTemplate = failed.isEmpty ? L10n.message("已请求结束进程，正在确认端口是否释放…")
            : L10n.message("没能结束进程，可能没有权限")
        recheck(after: 2, ports: failed.isEmpty ? [port] : [])
    }

    /// 用户已确认：结束这个项目的开发进程。Agent 自己的端口不在 project.ports 里，不会被结束。
    func stopProject(_ id: String) {
        pending = nil
        guard let project = projects.first(where: { $0.id == id }) else { return }
        let failed = control.terminate(project.ports)
        noticeTemplate = failed.isEmpty ? L10n.message("已请求停止，正在确认端口是否释放…")
            : L10n.message("部分进程没能结束，可能没有权限")
        recheck(after: 2, ports: project.ports.map(\.port))
    }

    /// 等一会儿重扫；仍在监听的端口记为「需要强制结束」。
    private func recheck(after seconds: Double, ports watched: [Int]) {
        let path = path
        let commands = AppPreferences(values: settings.effective()).projectCommands
        generation += 1
        let token = generation
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            let snapshot = await Task.detached(priority: .utility) {
                Self.load(path: path, commands: commands)
            }.value
            guard token == generation else { return }
            apply(snapshot)
            let alive = Set(snapshot.ports.map(\.port)).intersection(watched)
            stubborn.formUnion(alive)
            if !watched.isEmpty {
                noticeTemplate = alive.isEmpty ? L10n.message("端口已释放")
                    : L10n.message("进程还没退出，可以再等一下或强制结束")
            }
        }
    }

    /// 在终端里启动项目。命令原样交给用户的 shell。
    func start(_ id: String) {
        guard let project = projects.first(where: { $0.id == id }), let root = project.root,
              let command = project.command,
              let line = PortControl.startLine(directory: root, command: command) else {
            noticeTemplate = L10n.message("先填写启动命令")
            return
        }
        starting.insert(id)
        let pref = AppPreferences(values: settings.effective()).terminalApp
        Task {
            noticeTemplate = await Task.detached(priority: .userInitiated) { () -> L10n.Template in
                let resume = Resume()
                if resume.openTerminal(line, pref: pref) { return L10n.message("已在终端打开") }
                if resume.copyToClipboard(line) { return L10n.message("终端打开失败，命令已复制到剪贴板") }
                return L10n.message("终端打开失败")
            }.value
            // 开发服务器起来需要几秒：隔一会儿看一次，15 秒后不再等
            for delay in [2.0, 3.0, 5.0, 5.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard starting.contains(id) else { return }
                refresh(quiet: true)
            }
            try? await Task.sleep(for: .seconds(1))
            starting.remove(id)
        }
    }

    /// 保存手填的启动命令；留空则恢复自动识别。写设置由 AppState 负责。
    func saveCommand(_ text: String, for id: String, state: AppState) {
        guard let project = projects.first(where: { $0.id == id }), let root = project.root else { return }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var commands = state.prefs.projectCommands
        if trimmed.isEmpty {
            commands[root] = nil
        } else {
            guard PortControl.isValidCommand(trimmed) else {
                noticeTemplate = L10n.message("启动命令不能换行，且不超过 500 个字符")
                return
            }
            commands[root] = trimmed
        }
        state.updateSetting(key: "project_commands", value: commands)
        editingProject = nil
        noticeTemplate = L10n.message("已保存启动命令")
        refresh(quiet: true)
    }

    func clearNotice() { noticeTemplate = nil }
}
