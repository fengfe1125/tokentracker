//
//  SettingsView.swift
//  TokenTrackerApp
//
//  设置：与 ~/.tokentracker/settings.json 双向同步（SettingsStore 白名单
//  校验写入），状态栏 5s 内热生效。开机启动走 SMAppService。
//  另含 Codex 多账号管理区（仅 Codex 已检测时显示）：保存当前登录、一键切换、
//  重命名 / 删除。凭据快照仅存本机 ~/.tokentracker/codex_accounts.json（0600）。
//

import AppKit
import ServiceManagement
import SwiftUI
import TokenTrackerCore

struct SettingsPanelView: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var state: AppState
    @StateObject private var updater = UpdaterModel()
    @State private var showCaptureSheet = false
    @State private var captureName = ""
    @State private var renameTarget: CodexAccount?
    @State private var renameName = ""
    @State private var publishEndpoint = ""
    @State private var publishHandle = ""
    @State private var publishDays = 365
    @State private var publishToken = ""
    @State private var showForceConfirmation = false

    private var provider: String {
        state.settings["menubar_provider"] as? String ?? MenuBarFmt.defaultProvider
    }

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { (state.settings[key] as? NSNumber)?.boolValue ?? false },
            set: { state.updateSetting(key: key, value: $0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: L10n.text("设置"))
            form
        }
        .navigationTitle(L10n.text("设置"))
    }

    private var form: some View {
        Form {
            Section(L10n.text("状态栏")) {
                Picker(L10n.text("标题显示"), selection: Binding(
                    get: { provider },
                    set: { state.updateSetting(key: "menubar_provider", value: $0) }
                )) {
                    ForEach(state.quotaEntries, id: \.id) { entry in
                        LocalizedText("今日用量 + \(entry.name)").tag(entry.id)
                    }
                    Text(L10n.text("仅今日用量")).tag("off")
                }
                Toggle(L10n.text("圆环显示配额"), isOn: binding("menubar_ring"))
                Toggle(L10n.text("紧凑标题"), isOn: binding("menubar_compact"))
                Toggle(L10n.text("大数以「亿」显示"), isOn: binding("unit_yi"))
                    .disabled(L10n.isEnglish)
                Text(L10n.text("中文使用万／亿；英文使用 K/M/B。")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.text("通用")) {
                Picker(L10n.text("语言 / Language"), selection: $language.selection) {
                    Text(L10n.text("跟随系统")).tag(AppLanguage.system)
                    Text("简体中文").tag(AppLanguage.simplifiedChinese)
                    Text("English").tag(AppLanguage.english)
                }

                Toggle(L10n.text("开机自动启动"), isOn: Binding(
                    get: { (state.settings["launch_at_login"] as? NSNumber)?.boolValue ?? false },
                    set: { on in
                        state.updateSetting(key: "launch_at_login", value: on)
                        applyLoginItem(on)
                    }
                ))
                Picker(L10n.text("终端 App（继续会话用）"), selection: Binding(
                    get: { state.settings["terminal_app"] as? String ?? "auto" },
                    set: { state.updateSetting(key: "terminal_app", value: $0) }
                )) {
                    Text(L10n.text("自动检测")).tag("auto")
                    Text("Terminal").tag("terminal")
                    Text("iTerm2").tag("iterm")
                    Text("WezTerm").tag("wezterm")
                    Text("Ghostty").tag("ghostty")
                }
            }
            if state.detectInfo["codex"]?.installed == true {
                codexAccountSection
            }
            Section(L10n.text("数据")) {
                Button(L10n.text("在 Finder 中打开本地数据目录")) {
                    let path = NSHomeDirectory() + "/.tokentracker"
                    try? FileManager.default.createDirectory(atPath: path,
                                                             withIntermediateDirectories: true)
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
                Text(L10n.text("原始用量日志始终只在本机读取和保存。设置保存在 ~/.tokentracker/settings.json。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(L10n.text("价格估算")) {
                Toggle(L10n.text("自动同步官方价格"), isOn: binding("price_sync_enabled"))
                Text(L10n.text("每天从模型供应商的公开页面更新 API 费率。关闭后仍用本机已保存的费率估算；Token 统计和来源费用不受影响。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(priceSyncStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.text("立即同步")) { state.syncPricesNow() }
                        .disabled(state.priceSyncRunning)
                    if state.priceSyncRunning { ProgressView().controlSize(.small) }
                }
                if state.priceSyncLastSuccessAtMs > 0 {
                    let date = Date(timeIntervalSince1970: Double(state.priceSyncLastSuccessAtMs) / 1000)
                    Text(L10n.text("上次成功同步：\(date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)))"))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text(L10n.text("上次成功同步：从未"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !state.priceSyncMessage.isEmpty {
                    Text(state.priceSyncMessage)
                        .font(.caption)
                        .foregroundStyle(state.priceSyncState == "failed" ? .red : .secondary)
                        .lineLimit(3)
                }
            }
            publishSection
            Section(L10n.text("关于")) {
                HStack {
                    Text("TokenTracker")
                    Spacer()
                    Text("v\(TokenTrackerCore.version)")
                        .foregroundStyle(.secondary)
                }
                Link(L10n.text("作者主页"), destination: URL(string: "https://sakuramu.edu.kg/")!)
                updateRow
            }
        }
        // .grouped 自带内边距，外面不再叠 .padding()（此前是双份）
        .formStyle(.grouped)
        .onAppear {
            loadPublishDrafts()
            state.refreshPublishInfo()
        }
        .alert(L10n.text("保存当前登录账号"), isPresented: $showCaptureSheet) {
            TextField(L10n.text("备注名（留空则用邮箱）"), text: $captureName)
            Button(L10n.text("保存")) {
                state.captureCurrentCodexAccount(name: captureName)
                captureName = ""
            }
            Button(L10n.text("取消"), role: .cancel) { captureName = "" }
        } message: {
            Text(L10n.text("把当前 Codex 登录的凭据快照存到本机，之后可一键切回。"))
        }
        .alert(L10n.text("重命名账号"), isPresented: renamePresented, presenting: renameTarget) { account in
            TextField(L10n.text("备注名"), text: $renameName)
            Button(L10n.text("确定")) {
                state.renameCodexAccount(id: account.id, name: renameName)
                renameTarget = nil
            }
            Button(L10n.text("取消"), role: .cancel) { renameTarget = nil }
        }
        .alert(L10n.text("确认强制上传？"), isPresented: $showForceConfirmation) {
            Button(L10n.text("强制上传"), role: .destructive) {
                state.performPublish(trigger: .forced)
            }
            Button(L10n.text("取消"), role: .cancel) {}
        } message: {
            Text(L10n.text("这会绕过内容去重、15 分钟间隔和失败退避，但仍会校验服务地址、用户名与 Token。"))
        }
    }

    private var priceSyncStatusText: String {
        if state.priceSyncRunning { return L10n.text("正在同步价格…") }
        switch state.priceSyncState {
        case "success": return L10n.text("价格同步成功")
        case "partial": return L10n.text("部分价格来源同步失败")
        case "failed": return L10n.text("价格同步失败，继续使用上次有效价格")
        default: return L10n.text("尚未同步价格")
        }
    }

    // -------------------------------------------------------- 公开统计 ----

    @ViewBuilder
    private var publishSection: some View {
        Section(L10n.text("公开统计")) {
            Toggle(L10n.text("扫描后自动上传"), isOn: Binding(
                get: { (state.settings["publish_enabled"] as? NSNumber)?.boolValue ?? false },
                set: { state.setPublishEnabled($0) }
            ))
            TextField(L10n.text("HTTPS 服务地址"), text: $publishEndpoint,
                      prompt: Text("https://tt.example.com"))
                .textFieldStyle(.roundedBorder)
            TextField(L10n.text("用户名"), text: $publishHandle, prompt: Text("your-handle"))
                .textFieldStyle(.roundedBorder)
            Picker(L10n.text("公开时间范围"), selection: $publishDays) {
                Text(L10n.text("90 天")).tag(90)
                Text(L10n.text("365 天")).tag(365)
                Text(L10n.text("730 天")).tag(730)
            }
            HStack(spacing: 8) {
                SecureField(L10n.text("发布 Token（留空保持现有）"), text: $publishToken)
                    .textFieldStyle(.roundedBorder)
                Label(state.publishTokenConfigured ? L10n.text("已配置") : L10n.text("未配置"),
                      systemImage: state.publishTokenConfigured
                        ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(state.publishTokenConfigured ? .green : .secondary)
            }
            HStack {
                Button(L10n.text("保存配置")) {
                    state.savePublishConfiguration(endpoint: publishEndpoint,
                                                   handle: publishHandle,
                                                   days: publishDays,
                                                   token: publishToken)
                    publishToken = ""
                    loadPublishDrafts()
                }
                Spacer()
                if let url = state.publicStatsURL {
                    Link(L10n.text("打开公开数据 →"), destination: url).font(.caption)
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button(L10n.text("按规则上传")) { state.performPublish(trigger: .manual) }
                    .disabled(!state.publishConfigurationReady || state.publishBusy)
                Button(L10n.text("强制上传…")) { showForceConfirmation = true }
                    .disabled(!state.publishConfigurationReady || state.publishBusy)
                Spacer()
                Button(L10n.text("查看上传记录…")) { state.showPublishHistory() }
            }
            if state.publishBusy {
                ProgressView().controlSize(.small)
            }
            if let message = state.publishMessage, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(state.publishFailed ? .red : .secondary)
            }
            publishStatus
            Text(publishPrivacyText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var publishStatus: some View {
        let snapshot = state.publishState
        VStack(alignment: .leading, spacing: 3) {
            if snapshot.lastSuccessAt > 0 {
                Text(L10n.text("上次成功：\(Date(timeIntervalSince1970: snapshot.lastSuccessAt).formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)))"))
            } else {
                Text(L10n.text("上次成功：从未"))
            }
            if !snapshot.lastError.isEmpty {
                Text(L10n.text("上次错误：\(snapshot.lastError)")).foregroundStyle(.red)
                    .lineLimit(2).help(snapshot.lastError)
            }
            Text(L10n.text("本机上传记录：\(state.publishHistory.count) 条"))
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private var publishPrivacyText: String {
        let enabled = (state.settings["publish_enabled"] as? NSNumber)?.boolValue ?? false
        return enabled
            ? L10n.text("自动上传已开启。只发送聚合数字；项目路径、会话、提示词、模型名和账号信息不会上传。")
            : L10n.text("自动上传已关闭。手动上传仍可使用；原始日志和敏感信息不会离开本机。")
    }

    private func loadPublishDrafts() {
        publishEndpoint = state.settings["publish_endpoint"] as? String ?? ""
        publishHandle = state.settings["publish_handle"] as? String ?? ""
        publishDays = (state.settings["publish_days"] as? NSNumber)?.intValue ?? 365
    }

    // ---------------------------------------------------- Codex 账号 ----

    @ViewBuilder
    private var codexAccountSection: some View {
        Section(L10n.text("Codex 账号")) {
            Button(L10n.text("保存当前登录账号…")) {
                captureName = ""
                showCaptureSheet = true
            }
            if state.codexAccounts.isEmpty {
                Text(L10n.text("还没有保存的账号。先在 Codex 登录，再点上面的按钮把当前登录存进来。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(state.codexAccounts) { account in
                    codexAccountRow(account)
                }
            }
            if let message = state.accountOpMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Text(L10n.text("切换后请重启 Codex 生效；账号之间切换不会丢会话。凭据快照仅存本机，不上传。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func codexAccountRow(_ account: CodexAccount) -> some View {
        let isActive = state.activeCodexAccountID == account.id
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(account.name)
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .help(L10n.text("当前生效"))
                    }
                }
                if let subtitle = codexAccountSubtitle(account) {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !isActive {
                Button(L10n.text("切换")) { state.switchCodexAccount(id: account.id) }
            }
            Menu {
                Button(L10n.text("重命名…")) {
                    renameName = account.name
                    renameTarget = account
                }
                Button(L10n.text("删除"), role: .destructive) {
                    state.removeCodexAccount(id: account.id)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func codexAccountSubtitle(_ account: CodexAccount) -> String? {
        var parts: [String] = []
        if let email = account.email, !email.isEmpty { parts.append(email) }
        if let plan = account.plan, !plan.isEmpty { parts.append(plan) }
        parts.append("id …\(account.id.suffix(6))")
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } })
    }

    // ------------------------------------------------------------ 更新 ----

    @ViewBuilder
    private var updateRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(updater.stage == .checking ? L10n.text("检查中…") : L10n.text("检查更新")) {
                    updater.check(applyTo: state)
                }
                .disabled(updater.busy)
                Spacer()
                statusText
            }
            switch updater.stage {
            case .available(let release):
                availableRow(release)
            case .downloading(let fraction):
                ProgressView(value: fraction) {
                    Text(L10n.text("正在下载 \(Int(fraction * 100))%"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .installing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("正在替换应用…")).font(.caption).foregroundStyle(.secondary)
                }
            case .installed:
                HStack {
                    Text(L10n.text("新版本已装好")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.text("重启以完成更新")) { updater.relaunch() }
                }
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch updater.stage {
        case .upToDate:
            Text(L10n.text("已是最新版本")).font(.caption).foregroundStyle(.secondary)
        case .available(let release):
            Text(L10n.text("发现 \(release.tag)")).font(.caption).foregroundStyle(.orange)
        case .failed(let message):
            Text(L10n.text(message)).font(.caption).foregroundStyle(.red)
                .lineLimit(2).help(L10n.text(message))
        default:
            // 没手动查过就用启动时那次后台检查的结果
            if let update = state.updateInfo,
               UpdateChecker.updateAvailable(update, current: TokenTrackerCore.version) {
                Link(L10n.text("发现新版本 \(update.latest) →"), destination: URL(string: update.url)!)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func availableRow(_ release: ReleaseInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if release.dmg != nil, updater.appPath != nil {
                    Button(L10n.text("下载并安装")) { updater.downloadAndInstall(release) }
                        .disabled(updater.busy)
                }
                if let url = URL(string: release.htmlURL), !release.htmlURL.isEmpty {
                    Link(L10n.text("查看发布说明 →"), destination: url).font(.caption)
                }
            }
            if let dmg = release.dmg, updater.appPath != nil {
                Text(L10n.text("会下载 \(dmg.name)（\(ByteCountFormatter.string(fromByteCount: dmg.size, countStyle: .file))），")
                     + L10n.text("校验后替换当前应用，然后需要重启。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if updater.appPath == nil {
                Text(L10n.text("当前不是以 .app 方式运行，只能手动下载。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(L10n.text("这个版本没有提供 .dmg 安装包，请到发布页手动下载。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 开机自启（SMAppService，仅打包后的 .app 有效）
    private func applyLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // 开发模式（swift run / 未打包）注册会失败，静默忽略
        }
    }
}

/// 供 Settings 场景使用（⌘,）：与主面板设置页同一份实现。
struct SettingsSceneView: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var state: AppState

    var body: some View {
        SettingsPanelView(state: state)
            .frame(width: 520, height: 560)
    }
}
