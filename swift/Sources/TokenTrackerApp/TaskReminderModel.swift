import AppKit
import Combine
import UserNotifications
import TokenTrackerCore

@MainActor
final class TaskReminderPreferences: ObservableObject {
    static let shared = TaskReminderPreferences(defaults: ProcessInfo.processInfo.environment["TT_UI_PREVIEW"] == "1"
        ? UserDefaults(suiteName: "com.tokentracker.task-preview")! : .standard)
    private let defaults: UserDefaults
    @Published var enabled: Bool { didSet { save("enabled", enabled) } }
    @Published var completion: Bool { didSet { save("completion", completion) } }
    @Published var approval: Bool { didSet { save("approval", approval) } }
    @Published var codex: Bool { didSet { save("codex", codex) } }
    @Published var claude: Bool { didSet { save("claude", claude) } }
    @Published var system: Bool { didSet { save("system", system) } }
    @Published var sound: Bool { didSet { save("sound", sound) } }
    @Published private(set) var notificationDenied = false
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func value(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: "tt.tasks." + key) as? Bool ?? fallback }
        enabled = value("enabled", false); completion = value("completion", true); approval = value("approval", true)
        codex = value("codex", false); claude = value("claude", false)
        system = value("system", false); sound = value("sound", false)
    }
    private func save(_ key: String, _ value: Bool) { defaults.set(value, forKey: "tt.tasks." + key) }
    func selectedRoot(_ client: TaskClient) -> String? { defaults.string(forKey: "tt.tasks.root." + client.rawValue) }
    func selectRoot(_ path: String, client: TaskClient) {
        objectWillChange.send()
        defaults.set(path, forKey: "tt.tasks.root." + client.rawValue)
    }
    func accepts(_ provider: TaskProvider) -> Bool { enabled && (provider == .codex ? codex : claude) }
    func authorizeSystem() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.system = granted; self?.notificationDenied = !granted }
        }
    }
}

enum TaskReminderState: String, Codable { case waiting, ended, sent, rejected, resumed, failed, expired, advisory }

struct TaskReminder: Identifiable, Codable {
    let id: String
    let provider: TaskProvider
    let session: String
    let turn: String
    let tool: String
    let project: String
    let at: Date
    let deadline: Date?
    let sourceApp: String?
    var client: TaskClient? = nil
    var engineVersion: String? = nil
    var call: String? = nil
    var agent: String? = nil
    var state: TaskReminderState
    // Explicitly omitted from Codable. Restarted reminders can never be approved.
    var arguments: String? = nil
    enum CodingKeys: String, CodingKey { case id, provider, session, turn, tool, project, at, deadline, sourceApp, state, call, agent, client, engineVersion }
    var clientName: String { (client ?? .unknown).name }
    var pending: Bool { state == .waiting && deadline.map { $0 > Date() } == true }
    var statusKey: String {
        switch state {
        case .waiting: "等待审批"
        case .ended: "本轮回复结束"
        case .sent: "决定已发送"
        case .rejected: "拒绝决定已发送"
        case .resumed: "已继续执行"
        case .failed: "执行失败"
        case .expired: "请回原任务处理"
        case .advisory: "需要你在原任务处理"
        }
    }
}

@MainActor
final class TaskReminderModel: ObservableObject {
    static let shared = TaskReminderModel()
    static var channel: String { Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true ? "development" : "production" }
    @Published private(set) var reminders: [TaskReminder] = []
    @Published var notice: String?
    @Published var presentation: String?
    @Published private(set) var observedProviders = Set<TaskProvider>()
    @Published private(set) var observedClients: [TaskClient: TaskClientSource] = [:]
    let preferences: TaskReminderPreferences
    let server: TaskHookServer
    private let history: URL
    private var received = Set<String>()
    private var completed = Set<String>()
    private var generations: [String: Int] = [:]
    private var subscriptions = Set<AnyCancellable>()
    var onPresent: ((String, Bool) -> Void)?
    var onShowList: (() -> Void)?
    init(preferences: TaskReminderPreferences = .shared, history: URL? = nil, channel: String? = nil,
         server: TaskHookServer? = nil) {
        self.preferences = preferences
        let channel = channel ?? Self.channel
        self.server = server ?? TaskHookServer(channel: channel)
        self.history = history ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(channel == "development" ? "TokenTracker Dev" : "TokenTracker")
            .appendingPathComponent(ProcessInfo.processInfo.environment["TT_UI_PREVIEW"] == "1" ? "task-reminders-preview.json" : "task-reminders.json")
        if let data = try? Data(contentsOf: self.history), let rows = try? JSONDecoder().decode([TaskReminder].self, from: data) {
            reminders = rows.filter { $0.at > Date().addingTimeInterval(-7 * 86_400) }.prefix(50).map {
                var row = $0
                if row.state == .waiting || row.state == .sent { row.state = .expired }
                return row
            }
            received = Set(reminders.map(\.id))
            completed = Set(reminders.filter { $0.state == .ended && !$0.turn.isEmpty }
                .map { $0.provider.rawValue + ":" + $0.session + ":" + $0.turn })
        }
    }
    func start() {
        prune(); persist()
        server.onEvent = { [weak self] event in Task { @MainActor in
            guard let self else { return }
            self.receive(event)
            // EOF can arrive before the main queue receives the event.
            if event.requiresReply && !self.server.isPending(event.id) { self.expire(event.id) }
        } }
        server.onExpire = { [weak self] id in Task { @MainActor in self?.expire(id) } }
        do { try server.start() } catch { notice = L10n.text("任务提醒服务未启动，已有实例可能正在运行") }
        NotificationRouter.shared.onTask = { [weak self] id in self?.show(id, explicit: true) }
        preferences.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.releaseDisabledRequests() }
        }.store(in: &subscriptions)
    }
    func stop() { server.stop() }
    func maintainHistory() {
        guard reminders.contains(where: { $0.at < Date().addingTimeInterval(-7 * 86_400) }) else { return }
        prune(); persist()
    }
    func receive(_ event: TaskHookEvent) {
        guard preferences.accepts(event.provider), received.insert(event.id).inserted else {
            _ = server.resolve(event.id, decision: .pass); return
        }
        let sessionKey = event.provider.rawValue + ":" + event.session
        observedProviders.insert(event.provider)
        if let source = event.source, source.client.provider == event.provider,
           source.confidence == .launchContext, source.location == .local {
            observedClients[source.client] = source
        }
        if ["UserPromptSubmit", "SessionEnd", "Interrupt"].contains(event.event) {
            server.cancel(session: event.session, provider: event.provider, agent: event.agent)
            let invalidated = reminders.filter { $0.provider == event.provider && $0.session == event.session
                && ($0.agent ?? "") == event.agent && $0.state == .waiting }.map(\.id)
            for id in invalidated { expire(id) }
            if event.event == "UserPromptSubmit" { generations[sessionKey, default: 0] += 1 }
            persist(); return
        }
        if ["PostToolUse", "PostToolUseFailure", "PermissionDenied"].contains(event.event) {
            // Without a tool-call id PermissionRequest cannot be safely paired
            // with a concurrent completion. Require one unambiguous candidate.
            let matches = reminders.indices.filter {
                let r = reminders[$0]
                return r.provider == event.provider && r.session == event.session && r.tool == event.tool
                    && r.turn == event.turn && !event.call.isEmpty && r.call == event.call && [.sent, .rejected].contains(r.state)
                    && (r.agent ?? "") == event.agent
            }
            if matches.count == 1, let i = matches.first, reminders[i].state == .sent {
                reminders[i].state = event.failed ? .failed : .resumed; persist()
            }
            return
        }
        let state: TaskReminderState
        if event.requiresReply, preferences.approval { state = .waiting }
        else if event.event == "Notification", preferences.approval {
            if reminders.contains(where: { $0.provider == event.provider && $0.session == event.session && $0.pending }) { return }
            state = .advisory
        } else if event.event == "Stop", event.isMain, preferences.completion {
            let key = sessionKey + ":" + (event.turn.isEmpty ? String(generations[sessionKey, default: 0]) : event.turn)
            guard completed.insert(key).inserted else { return }
            state = .ended
        } else { _ = server.resolve(event.id, decision: .pass); return }
        // One live card per identical pending request, even if two config layers emit it.
        if state == .waiting, reminders.contains(where: { $0.pending && $0.provider == event.provider && $0.session == event.session
            && ($0.agent ?? "") == event.agent && $0.tool == event.tool && $0.arguments == event.arguments }) {
            _ = server.resolve(event.id, decision: .pass); return
        }
        var reminder = TaskReminder(id: event.id, provider: event.provider, session: event.session, turn: event.turn,
            tool: event.tool, project: URL(fileURLWithPath: event.cwd).lastPathComponent, at: event.at,
            deadline: state == .waiting ? event.at.addingTimeInterval(120) : nil, sourceApp: event.sourceApp,
            call: event.call.isEmpty ? nil : event.call,
            agent: event.agent.isEmpty ? nil : event.agent,
            state: state, arguments: state == .waiting ? event.arguments : nil)
        if event.client.provider == event.provider {
            reminder.client = event.client
            reminder.engineVersion = event.source?.engineVersion
        }
        reminders.insert(reminder, at: 0)
        prune(); persist()
        if preferences.system {
            NotificationRouter.shared.task(id: reminder.id, title: reminder.provider.name,
                body: L10n.label(reminder.statusKey), sound: preferences.sound)
        }
        if state == .waiting || !reminders.contains(where: { $0.pending && $0.id != reminder.id }) {
            show(reminder.id, explicit: false)
        }
    }
    func show(_ id: String, explicit: Bool) {
        guard reminders.contains(where: { $0.id == id }) else { return }
        presentation = id; onPresent?(id, explicit)
    }
    func decide(_ id: String, _ decision: TaskHookDecision) {
        guard let i = reminders.firstIndex(where: { $0.id == id }), reminders[i].pending else { expire(id); return }
        let sent = server.resolve(id, decision: decision)
        reminders[i].state = sent ? (decision == .allow ? .sent : decision == .deny ? .rejected : .expired) : .expired
        reminders[i].arguments = nil
        NotificationRouter.shared.removeTask(id); persist()
    }
    func expire(_ id: String) {
        guard let i = reminders.firstIndex(where: { $0.id == id }), reminders[i].state == .waiting else { return }
        reminders[i].state = .expired; reminders[i].arguments = nil
        NotificationRouter.shared.removeTask(id); persist()
    }
    private func releaseDisabledRequests() {
        for row in reminders where row.state == .waiting && (!preferences.accepts(row.provider) || !preferences.approval) {
            _ = server.resolve(row.id, decision: .pass); expire(row.id)
        }
    }
    private func prune() {
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        let removed = reminders.filter { $0.at < cutoff } + Array(reminders.dropFirst(50))
        for row in removed where row.state == .waiting { _ = server.resolve(row.id, decision: .pass) }
        reminders = Array(reminders.filter { $0.at >= cutoff }.prefix(50))
        if received.count > 4096 { received = Set(reminders.map(\.id)) }
    }
    private func persist() {
        guard let data = try? JSONEncoder().encode(reminders) else { return }
        do {
            try FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try data.write(to: history, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: history.path)
        } catch { notice = L10n.text("任务提醒历史保存失败") }
    }
    func navigate(_ row: TaskReminder) {
        let allowed = ["com.apple.Terminal", "com.googlecode.iterm2", "com.github.wez.wezterm", "com.mitchellh.ghostty",
                       "com.openai.codex", "com.anthropic.claudefordesktop"]
        let bundle = row.sourceApp.flatMap { allowed.contains($0) ? $0 : nil }
            ?? (row.provider == .codex ? "com.openai.codex" : "com.anthropic.claudefordesktop")
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
            notice = L10n.text("未找到原应用，请自行返回原任务"); return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        notice = L10n.text("已打开原应用；无法精确定位会话，请在应用内选择原任务")
    }
}
