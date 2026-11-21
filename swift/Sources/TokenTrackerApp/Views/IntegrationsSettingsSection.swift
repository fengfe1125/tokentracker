//
//  IntegrationsSettingsSection.swift
//  TokenTrackerApp
//
//  设置 › 提醒与集成：统一管理任务提醒（Codex / Claude Code Hooks）与
//  Antigravity 工作区映射 Hooks，共用变更预览弹窗，并将冗长兼容说明收入折叠区。
//

import AppKit
import SwiftUI
import TokenTrackerCore

struct IntegrationsSettingsSection: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject private var preferences = TaskReminderPreferences.shared
    @ObservedObject private var model = TaskReminderModel.shared
    @ObservedObject var state: AppState

    enum HookPreview: Identifiable {
        case task(provider: TaskProvider, config: TaskHookConfiguration, installing: Bool)
        case antigravity(config: AntigravityHookConfiguration, installing: Bool)

        var id: String {
            switch self {
            case .task(let provider, let config, let installing):
                return "task:\(provider.rawValue):\(config.path):\(installing)"
            case .antigravity(let config, let installing):
                return "ag:\(config.path):\(installing)"
            }
        }
        var path: String {
            switch self {
            case .task(_, let config, _): return config.path
            case .antigravity(let config, _): return config.path
            }
        }
        var originalText: String {
            switch self {
            case .task(_, let config, _): return Self.hooksOnlyJSON(config.original)
            case .antigravity(let config, _): return Self.rawJSON(config.original)
            }
        }
        var proposedText: String {
            switch self {
            case .task(_, let config, _): return Self.hooksOnlyJSON(config.proposed)
            case .antigravity(let config, _): return Self.rawJSON(config.proposed)
            }
        }
        private static func hooksOnlyJSON(_ data: Data?) -> String {
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let hooks = object?["hooks"] as? [String: Any] ?? [:]
            return (try? JSONSerialization.data(withJSONObject: ["hooks": hooks],
                                                options: [.prettyPrinted, .sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }
        private static func rawJSON(_ data: Data?) -> String {
            data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }
    }

    @State private var preview: HookPreview?
    @State private var notice: String?
    @State private var agInstalled = false
    @State private var agMappedCount = 0
    @State private var expandedProviders: Set<TaskProvider> = []
    @State private var showNotes = false

    private var agHookPath: String { AntigravityHookConfiguration.defaultPath }
    private var channel: String { TaskReminderModel.channel }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let notice {
                HStack(spacing: 8) {
                    Label(notice, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { self.notice = nil } label: {
                        Image(systemName: "xmark").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.sunkSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            reminderSection
            hooksSection
            notesDisclosure
        }
        .onAppear(perform: reloadAntigravity)
        .onChange(of: state.updatedAt) { _, _ in reloadAntigravity() }
        .sheet(item: $preview) { item in
            HookDiffPreviewSheet(preview: item, onCancel: { preview = nil }, onApply: { apply(item) })
                .appLanguage()
        }
    }

    // ---------------------------------------------------------- 任务提醒 ----

    private var reminderSection: some View {
        SettingsSection(
            L10n.text("任务提醒"),
            footer: preferences.notificationDenied
                ? L10n.text("系统通知未获授权；应用内提醒仍可使用") : nil
        ) {
            SettingsToggle(L10n.text("启用任务提醒"),
                           detail: L10n.text("在 Agent 本轮结束或等待审批时弹出提醒。"),
                           isOn: $preferences.enabled)
            if preferences.enabled {
                SettingsDivider()
                SettingsToggle(L10n.text("本轮结束提醒"), isOn: $preferences.completion)
                SettingsDivider()
                SettingsToggle(L10n.text("等待审批提醒"), isOn: $preferences.approval)
                SettingsDivider()
                SettingsToggle(L10n.text("系统通知"), isOn: Binding(get: { preferences.system }, set: {
                    if $0 { preferences.authorizeSystem() } else { preferences.system = false }
                }))
                if preferences.system {
                    SettingsDivider()
                    SettingsToggle(L10n.text("通知声音"), isOn: $preferences.sound)
                }
            }
            SettingsDivider()
            SettingsRow(L10n.text("提醒列表")) {
                Button(L10n.text("打开…")) { model.onShowList?() }
            }
        }
    }

    // ---------------------------------------------------------- Agent Hooks ----

    private func isProviderConfigured(_ provider: TaskProvider) -> Bool {
        TaskClient.allCases.filter { $0.provider == provider }.contains { client in
            guard let path = root(client)?.configurationPath(provider: provider) else { return false }
            return TaskHookConfiguration.isInstalled(path: path, channel: channel)
        }
    }

    private func providerExpandedBinding(_ provider: TaskProvider) -> Binding<Bool> {
        Binding(
            get: { expandedProviders.contains(provider) || providerBinding(provider).wrappedValue },
            set: { open in
                if open { expandedProviders.insert(provider) }
                else { expandedProviders.remove(provider) }
            }
        )
    }

    private var hooksSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection(L10n.text("任务提醒 Hooks")) {
                ForEach(Array(TaskProvider.allCases.enumerated()), id: \.element) { index, provider in
                    if index > 0 { SettingsDivider() }
                    let configured = isProviderConfigured(provider)
                    let expanded = providerExpandedBinding(provider)
                    SettingsDisclosureRow(isExpanded: expanded) {
                        HStack(spacing: 8) {
                            Text(provider.name).fontWeight(.medium)
                            SettingsBadge(text: L10n.text(configured ? "已配置" : "未配置"),
                                          tint: configured ? .green : .secondary)
                        }
                    }
                    if expanded.wrappedValue {
                        SettingsDivider()
                        SettingsToggle(L10n.text("接入 \(provider.name)"), isOn: providerBinding(provider))
                        ForEach(TaskClient.allCases.filter { $0.provider == provider }, id: \.self) { client in
                            SettingsDivider()
                            clientRow(client, provider: provider)
                        }
                    }
                }
            }

            SettingsSection(
                L10n.text("Antigravity Hooks（工作区映射）"),
                footer: L10n.text("可选。仅靠本地日志即可统计 Antigravity 用量；接入全局 hooks.json 后仅额外记录会话与工作区目录的对应关系，不保存提示词或内容。")
            ) {
                SettingsRow(L10n.text("全局 Hooks 配置"), detail: "~/.gemini/config/hooks.json") {
                    HStack(spacing: 8) {
                        SettingsBadge(text: L10n.text(agInstalled ? "已配置" : "未配置"),
                                      tint: agInstalled ? .green : .secondary)
                        Menu {
                            Button(L10n.text("移除接入…")) { prepareAntigravity(installing: false) }
                                .disabled(!agInstalled)
                        } label: {
                            Label(L10n.text("更多"), systemImage: "ellipsis.circle")
                        }
                        .menuStyle(.button)
                        .buttonStyle(.pageIcon)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        Button(L10n.text("配置接入…")) { prepareAntigravity(installing: true) }
                    }
                }
                SettingsDivider()
                SettingsRow(L10n.text("已记录会话目录")) {
                    Text(L10n.text("\(agMappedCount) 个会话"))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
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
        let configured = path.map { TaskHookConfiguration.isInstalled(path: $0, channel: channel) } ?? false
        let issue = directory.flatMap { TaskHookConfiguration.blockingReason(provider: provider, root: $0.path) }
        let received = model.observedClients[client] != nil
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(L10n.label(client.name)).fontWeight(.medium)
                SettingsBadge(text: L10n.text(configured ? "已配置" : "未配置"), tint: configured ? .green : .secondary)
                if received { SettingsBadge(text: L10n.text("已收到事件"), tint: .blue) }
                Spacer()
                Menu {
                    Button(L10n.text("选择配置目录…")) { selectDirectory(client) }
                    Button(L10n.text("移除接入…")) { prepareTask(client, installing: false) }
                        .disabled(directory?.confirmed != true || !configured)
                } label: {
                    Label(L10n.text("更多"), systemImage: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.pageIcon)
                .menuIndicator(.hidden)
                .fixedSize()
                if directory?.confirmed == true {
                    Button(L10n.text("配置接入…")) { prepareTask(client, installing: true) }
                        .disabled(issue != nil)
                } else {
                    Button(L10n.text("选择配置目录…")) { selectDirectory(client) }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "folder").foregroundStyle(.tertiary)
                Text(directory?.path ?? L10n.text("路径待确认；请选择实际配置目录后再应用"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let directory, !directory.confirmed {
                Text(L10n.text("路径待确认；请选择实际配置目录后再应用"))
                    .font(.caption).foregroundStyle(.orange)
            }
            if let issue {
                Text(L10n.label(issue)).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .help(L10n.text(received ? "已收到该客户端本地事件" : "尚未收到该客户端事件"))
    }

    // ---------------------------------------------------------- 折叠说明 ----

    private var notesDisclosure: some View {
        SettingsSection {
            SettingsDisclosureRow(isExpanded: $showNotes) {
                Text(L10n.text("接入说明与兼容版本"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if showNotes {
                SettingsDivider()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach([
                        L10n.text("桌面仅接入本地任务；云端编排、Cloud、SSH、普通聊天和 Cowork 不支持。隔离环境无法访问本机 Helper 时，请回原任务审批。"),
                        L10n.text("同一配置目录由桌面和 CLI 共用，只安装一份；移除接入会同时影响读取该目录的客户端。上游信任和受管理策略仍可能限制 Hooks。"),
                        L10n.text("命令和参数仅在本机内存中展示；不支持的审批请回原任务处理。"),
                        L10n.text("验收记录仅对应列出的版本，不代表当前会话已连接或其他版本已验收。"),
                    ], id: \.self) { line in
                        Label { Text(line) } icon: { Image(systemName: "circle.fill").font(.system(size: 4)) }
                            .labelStyle(.titleAndIcon)
                    }
                    Divider().padding(.vertical, 4)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.label("验收记录：Codex CLI 0.162.1"))
                        Text(L10n.label("验收记录：Codex 桌面 26.1007.71326 / 引擎 0.162.0-alpha.17.2"))
                        Text(L10n.label("验收记录：Claude Code CLI 2.1.300"))
                        Text(L10n.label("验收记录：Claude 桌面 2.37337.1 / 引擎 2.1.295"))
                    }
                    .foregroundStyle(.tertiary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    // ---------------------------------------------------------- 操作 ----

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

    private func reloadAntigravity() {
        agInstalled = AntigravityHookConfiguration.isInstalled(path: agHookPath, channel: channel)
        agMappedCount = AntigravityWorkspaceMap.load(path: state.scanRoots.antigravityWorkspaceMap).count
    }

    private func prepareTask(_ client: TaskClient, installing: Bool) {
        guard let provider = client.provider, let root = root(client), root.confirmed else {
            notice = L10n.text("路径待确认；请选择实际配置目录后再应用"); return
        }
        if installing, let issue = TaskHookConfiguration.blockingReason(provider: provider, root: root.path) {
            notice = L10n.label(issue); return
        }
        let path = root.configurationPath(provider: provider)
        do {
            let config = try TaskHookConfiguration.preview(
                provider: provider, path: path, helper: TaskReminderModel.helperURL.path,
                channel: channel, installing: installing)
            preview = .task(provider: provider, config: config, installing: installing)
        } catch {
            notice = L10n.text("无法读取 Hooks 配置；未修改原文件")
        }
    }

    private func prepareAntigravity(installing: Bool) {
        do {
            let config = try AntigravityHookConfiguration.preview(
                path: agHookPath, helper: TaskReminderModel.helperURL.path,
                channel: channel, installing: installing)
            preview = .antigravity(config: config, installing: installing)
        } catch {
            notice = L10n.text("无法读取 Hooks 配置；未修改原文件")
        }
    }

    private func apply(_ item: HookPreview) {
        do {
            switch item {
            case .task(let provider, let config, let installing):
                if installing { try TaskReminderModel.installHelper() }
                try config.apply()
                providerBinding(provider).wrappedValue = installing
                notice = L10n.text(installing
                    ? "配置已保存；请在原工具检查并信任 Hooks，重新开始会话后验证接入。"
                    : "已移除 TokenTracker Hooks；其他配置已保留。")
            case .antigravity(let config, let installing):
                if installing { try TaskReminderModel.installHelper() }
                try config.apply()
                reloadAntigravity()
                notice = L10n.text(installing
                    ? "已配置 Antigravity 工作区映射；新会话或下轮对话结束后生效。"
                    : "已移除 Antigravity 工作区映射；其他 Hooks 配置已保留。")
                state.requestScan()
            }
            preview = nil
        } catch TaskBridgeError.unavailable {
            notice = L10n.text("未找到内置 Helper；请以打包后的 .app 运行后再配置。")
        } catch {
            notice = L10n.text("配置已变化或写入失败；未覆盖配置，请重新预览")
        }
    }
}

private struct HookDiffPreviewSheet: View {
    let preview: IntegrationsSettingsSection.HookPreview
    let onCancel: () -> Void
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("检查 Hooks 配置变更")).font(.headline)
            Text(preview.path).font(.caption).textSelection(.enabled)
            Text(L10n.text("保留其他配置；备份原文件后仅合并 TokenTracker 的 Hooks。"))
            HStack(alignment: .top, spacing: 12) {
                pane(L10n.text("修改前"), text: preview.originalText)
                pane(L10n.text("修改后"), text: preview.proposedText)
            }
            HStack {
                Button(L10n.text("取消"), action: onCancel)
                Spacer()
                Button(L10n.text("应用变更"), action: onApply)
                    .buttonStyle(SettingsPrimaryButtonStyle())
            }
        }
        .padding(20)
        .frame(width: 760, height: 540)
    }

    private func pane(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            ScrollView([.vertical, .horizontal]) {
                Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.sunkSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
