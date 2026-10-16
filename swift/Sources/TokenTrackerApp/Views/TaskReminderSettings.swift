import AppKit
import SwiftUI
import TokenTrackerCore

struct TaskReminderSettings: View {
    @ObservedObject private var preferences = TaskReminderPreferences.shared
    @ObservedObject private var model = TaskReminderModel.shared
    @State private var preview: TaskHookConfiguration?
    @State private var selected: TaskProvider = .codex
    @State private var installing = true
    @State private var notice: String?
    private var helperURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(TaskReminderModel.channel == "development" ? "TokenTracker Dev" : "TokenTracker")
            .appendingPathComponent("Hooks/TokenTrackerHook")
    }
    var body: some View {
        Section(L10n.text("任务提醒与审批")) {
            Toggle(L10n.text("启用任务提醒"), isOn: $preferences.enabled)
            Toggle(L10n.text("本轮结束提醒"), isOn: $preferences.completion)
            Toggle(L10n.text("等待审批提醒"), isOn: $preferences.approval)
            Toggle(L10n.text("系统通知"), isOn: Binding(get: { preferences.system }, set: {
                if $0 { preferences.authorizeSystem() } else { preferences.system = false }
            }))
            Toggle(L10n.text("通知声音"), isOn: $preferences.sound).disabled(!preferences.system)
            Button(L10n.text("任务提醒")) { model.onShowList?() }
            if preferences.notificationDenied {
                Text(L10n.text("系统通知未获授权；应用内提醒仍可使用"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(TaskProvider.allCases, id: \.self) { provider in
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(provider.name, isOn: providerBinding(provider))
                    ForEach(TaskClient.allCases.filter { $0.provider == provider }, id: \.self) { client in
                        clientRow(client, provider: provider)
                    }
                }
            }
            Text(L10n.text("桌面仅接入本地任务；云端编排、Cloud、SSH、普通聊天和 Cowork 不支持。隔离环境无法访问本机 Helper 时，请回原任务审批。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("同一配置目录由桌面和 CLI 共用，只安装一份；移除接入会同时影响读取该目录的客户端。上游信任和受管理策略仍可能限制 Hooks。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("命令和参数仅在本机内存中展示；不支持的审批请回原任务处理。"))
                .font(.caption).foregroundStyle(.secondary)
            if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }
        .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            if let preview {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("检查 Hooks 配置变更")).font(.headline)
                    Text(preview.path).font(.caption).textSelection(.enabled)
                    Text(L10n.text("保留其他配置；备份原文件后仅合并 TokenTracker 的 Hooks。"))
                    HStack(alignment: .top) {
                        configView(L10n.text("修改前"), data: preview.original)
                        configView(L10n.text("修改后"), data: preview.proposed)
                    }
                    HStack {
                        Button(L10n.text("取消")) { self.preview = nil }
                        Spacer()
                        Button(L10n.text("应用变更")) { apply(preview) }
                    }
                }.padding(20).frame(width: 760, height: 540)
            }
        }
    }
    private func root(_ client: TaskClient) -> TaskHookConfigurationRoot? {
        TaskHookConfigurationRoot.resolve(client: client, home: NSHomeDirectory(),
            environment: ProcessInfo.processInfo.environment,
            selected: preferences.selectedRoot(client),
            observed: model.observedClients[client]?.configurationRoot,
            exists: { FileManager.default.fileExists(atPath: $0) })
    }
    private func clientRow(_ client: TaskClient, provider: TaskProvider) -> some View {
        let directory = root(client)
        let path = directory?.configurationPath(provider: provider)
        let configured = path.map { TaskHookConfiguration.isInstalled(path: $0, channel: TaskReminderModel.channel) } ?? false
        let issue = directory.flatMap { TaskHookConfiguration.blockingReason(provider: provider, root: $0.path) }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L10n.label(client.name)).fontWeight(.medium)
                Spacer()
                Text(L10n.text(configured ? "已配置" : "未配置")).foregroundStyle(.secondary)
            }
            Text(L10n.text(model.observedClients[client] == nil ? "尚未收到该客户端事件" : "已收到该客户端本地事件"))
            Text(L10n.label(client == .codexCLI ? "验收记录：Codex CLI 0.162.1"
                : client == .claudeCLI ? "验收记录：Claude Code CLI 2.1.300"
                : client == .codexDesktop ? "验收记录：Codex 桌面 26.1007.71326 / 引擎 0.162.0-alpha.17.2"
                : "验收记录：Claude 桌面 2.37337.1 / 引擎 2.1.295"))
            Text(L10n.text("验收记录仅对应列出的版本，不代表当前会话已连接或其他版本已验收。"))
            if let directory {
                Text(directory.path).textSelection(.enabled).lineLimit(2)
                if !directory.confirmed { Text(L10n.text("路径待确认；请选择实际配置目录后再应用")) }
            } else { Text(L10n.text("路径待确认；请选择实际配置目录后再应用")) }
            if let issue { Text(L10n.label(issue)).foregroundStyle(.orange) }
            HStack {
                Button(L10n.text("选择配置目录…")) { selectDirectory(client) }
                Button(L10n.text("配置接入…")) { prepare(client, installing: true) }
                    .disabled(directory?.confirmed != true || issue != nil)
                Button(L10n.text("移除接入…")) { prepare(client, installing: false) }
                    .disabled(directory?.confirmed != true || !configured)
            }
        }.font(.caption).padding(.vertical, 5)
    }
    private func selectDirectory(_ client: TaskClient) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: root(client)?.path ?? NSHomeDirectory())
        if panel.runModal() == .OK, let url = panel.url {
            preferences.selectRoot(url.resolvingSymlinksInPath().path, client: client)
        }
    }
    private func providerBinding(_ provider: TaskProvider) -> Binding<Bool> {
        Binding(get: { provider == .codex ? preferences.codex : preferences.claude }, set: {
            if provider == .codex { preferences.codex = $0 } else { preferences.claude = $0 }
        })
    }
    private func configView(_ title: String, data: Data?) -> some View {
        let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let hooks = object?["hooks"] as? [String: Any] ?? [:]
        let text = (try? JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return VStack(alignment: .leading) {
            Text(title).font(.headline)
            ScrollView([.vertical, .horizontal]) { Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func prepare(_ client: TaskClient, installing: Bool) {
        guard let provider = client.provider, let root = root(client), root.confirmed else {
            notice = L10n.text("路径待确认；请选择实际配置目录后再应用"); return
        }
        if installing, let issue = TaskHookConfiguration.blockingReason(provider: provider, root: root.path) {
            notice = L10n.label(issue); return
        }
        selected = provider; self.installing = installing
        let path = root.configurationPath(provider: provider)
        do { preview = try TaskHookConfiguration.preview(provider: provider, path: path, helper: helperURL.path,
                                                          channel: TaskReminderModel.channel, installing: installing) }
        catch { notice = L10n.text("无法读取 Hooks 配置；未修改原文件") }
    }
    private func apply(_ preview: TaskHookConfiguration) {
        do {
            if installing {
                guard let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("TokenTrackerHook"),
                      FileManager.default.isExecutableFile(atPath: executable.path) else { throw TaskBridgeError.unavailable }
                try FileManager.default.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700])
                let staging = helperURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
                try FileManager.default.copyItem(at: executable, to: staging)
                defer { try? FileManager.default.removeItem(at: staging) }
                if FileManager.default.fileExists(atPath: helperURL.path) {
                    _ = try FileManager.default.replaceItemAt(helperURL, withItemAt: staging)
                } else { try FileManager.default.moveItem(at: staging, to: helperURL) }
            }
            try preview.apply()
            providerBinding(selected).wrappedValue = installing
            notice = L10n.text(installing ? "配置已保存；请在原工具检查并信任 Hooks，重新开始会话后验证接入。" : "已移除 TokenTracker Hooks；其他配置已保留。")
            self.preview = nil
        } catch { notice = L10n.text("配置已变化或写入失败；未覆盖配置，请重新预览") }
    }
}
