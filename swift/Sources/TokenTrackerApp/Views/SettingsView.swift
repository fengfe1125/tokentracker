//
//  SettingsView.swift
//  TokenTrackerApp
//
//  设置：左侧分类，右侧白色卡片分组（SettingsComponents）。与 ~/.tokentracker/settings.json
//  双向同步（SettingsStore 白名单校验写入），状态栏 5s 内热生效。开机启动走 SMAppService。
//  账号管理在「账号」页（AccountsView）。
//

import AppKit
import ServiceManagement
import SwiftUI
import TokenTrackerCore

/// 设置分类；rawValue 同时是持久化键（其他页面可据此直接跳到某一类）。
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, menubar, notch, navigation, reminders, data, publish, about
    static let storageKey = "tt.settings.tab"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: L10n.text("通用")
        case .menubar: L10n.text("状态栏")
        case .notch: L10n.text("刘海圆环")
        case .navigation: L10n.text("导航")
        case .reminders: L10n.text("任务提醒")
        case .data: L10n.text("价格与数据")
        case .publish: L10n.text("公开统计")
        case .about: L10n.text("关于与更新")
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .menubar: "menubar.rectangle"
        case .notch: "circle.circle.fill"
        case .navigation: "square.grid.2x2.fill"
        case .reminders: "bell.badge.fill"
        case .data: "dollarsign.circle.fill"
        case .publish: "globe"
        case .about: "info.circle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .general: .gray
        case .menubar: .blue
        case .notch: .orange
        case .navigation: .teal
        case .reminders: .red
        case .data: .green
        case .publish: .cyan
        case .about: .gray
        }
    }
}

private struct SettingsCategoryBoundsKey: PreferenceKey {
    static var defaultValue: [SettingsTab: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [SettingsTab: Anchor<CGRect>],
                       nextValue: () -> [SettingsTab: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct SettingsCategoryPressStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        BodyView(configuration: configuration, isPressed: $isPressed)
    }

    private struct BodyView: View {
        let configuration: Configuration
        @Binding var isPressed: Bool

        var body: some View {
            configuration.label
                .onChange(of: configuration.isPressed) { _, value in
                    isPressed = value
                }
                .onDisappear {
                    if isPressed { isPressed = false }
                }
        }
    }
}

struct SettingsPanelView: View {
    @ObservedObject private var language = LanguageManager.shared
    @AppStorage(SettingsTab.storageKey) private var tab = SettingsTab.general
    @ObservedObject private var notch = NotchHUDPreferences.shared
    @ObservedObject var state: AppState
    @StateObject private var updater = UpdaterModel()
    @State private var publishEndpoint = ""
    @State private var publishHandle = ""
    @State private var publishDays = 365
    @State private var publishToken = ""
    @State private var showForceConfirmation = false
    @State private var hoveredTab: SettingsTab?
    @State private var pressedTab: SettingsTab?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var provider: String {
        state.prefs.menubarProvider
    }

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { (state.settings[key] as? NSNumber)?.boolValue ?? false },
            set: { state.updateSetting(key: key, value: $0) }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            categoryList
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    content
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .id(tab)   // 换分类时回到顶部
        }
        .pageChrome(title: L10n.text("设置"))
        .tint(.blue)
        .sheet(isPresented: $state.showingPublishHistory) {
            PublishHistoryView(state: state).appLanguage()
                .frame(width: 660, height: 460)
        }
        .onAppear {
            loadPublishDrafts()
            state.refreshPublishInfo()
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

    /// 左侧分类：图标方块 + 名称，选中为浮起中性卡片胶囊，弹簧滑动切换。
    private var categoryList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsTab.allCases) { item in
                    let selected = tab == item
                    let pressed = pressedTab == item
                    Button { tab = item } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(item.tint.gradient,
                                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            Text(item.title)
                                .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.82))
                                .fontWeight(selected ? .medium : .regular)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .scaleEffect(pressed ? 0.98 : 1.0)
                        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .animation(reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.82),
                                   value: pressed)
                    }
                    .buttonStyle(SettingsCategoryPressStyle(isPressed: Binding(
                        get: { pressedTab == item },
                        set: { active in
                            if active {
                                pressedTab = item
                            } else if pressedTab == item {
                                pressedTab = nil
                            }
                        }
                    )))
                    .anchorPreference(key: SettingsCategoryBoundsKey.self, value: .bounds) { [item: $0] }
                    .onHover { hovering in
                        if hovering {
                            hoveredTab = item
                        } else if hoveredTab == item {
                            hoveredTab = nil
                        }
                    }
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .backgroundPreferenceValue(SettingsCategoryBoundsKey.self) { anchors in
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        ZStack(alignment: .topLeading) {
                            if let hoveredTab, hoveredTab != tab, let anchor = anchors[hoveredTab] {
                                let rect = proxy[anchor]
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                                    .frame(width: rect.width, height: rect.height)
                                    .offset(x: rect.minX, y: rect.minY)
                                    .id(hoveredTab)
                                    .transition(.opacity)
                            }
                        }
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hoveredTab)

                        if let anchor = anchors[tab] {
                            let rect = proxy[anchor]
                            let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
                            shape
                                .fill(PageControl.pillSurface)
                                .overlay(shape.strokeBorder(PageControl.pillBorder, lineWidth: 0.5))
                                .shadow(color: PageControl.pillShadow, radius: 2, x: 0, y: 1)
                                .frame(width: rect.width, height: rect.height)
                                .scaleEffect(pressedTab == tab ? 0.98 : 1.0)
                                .offset(x: rect.minX, y: rect.minY)
                                .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.84),
                                           value: tab)
                                .animation(reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.82),
                                           value: pressedTab == tab)
                        }
                    }
                }
                .allowsHitTesting(false)
            }
            .padding(12)
        }
        .frame(width: 200)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .general: general
        case .menubar:
            menubar
            MenuBarPortsSection(state: state, model: state.ports)
        case .notch: notchSettings
        case .navigation: SidebarSettingsSection()
        case .reminders: TaskReminderSettings()
        case .data: dataSettings
        case .publish: publishSettings
        case .about: about
        }
    }

    // ------------------------------------------------------------ 通用 ----

    private var languageTitle: String {
        switch language.selection {
        case .system: L10n.text("跟随系统")
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }

    private var terminalTitle: String {
        switch state.prefs.terminalApp {
        case "terminal": "Terminal"
        case "iterm": "iTerm2"
        case "wezterm": "WezTerm"
        case "ghostty": "Ghostty"
        default: L10n.text("自动检测")
        }
    }

    private var general: some View {
        SettingsSection {
            SettingsRow(L10n.text("语言 / Language")) {
                SettingsMenuPicker(title: languageTitle) {
                    Picker(L10n.text("语言 / Language"), selection: $language.selection) {
                        Text(L10n.text("跟随系统")).tag(AppLanguage.system)
                        Text("简体中文").tag(AppLanguage.simplifiedChinese)
                        Text("English").tag(AppLanguage.english)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            SettingsDivider()
            SettingsToggle(L10n.text("开机自动启动"), isOn: Binding(
                get: { state.prefs.launchAtLogin },
                set: { on in
                    state.updateSetting(key: "launch_at_login", value: on)
                    applyLoginItem(on)
                }
            ))
            SettingsDivider()
            SettingsRow(L10n.text("终端 App"), detail: L10n.text("从会话详情继续会话时打开的终端。")) {
                SettingsMenuPicker(title: terminalTitle) {
                    Picker(L10n.text("终端 App"), selection: Binding(
                        get: { state.prefs.terminalApp },
                        set: { state.updateSetting(key: "terminal_app", value: $0) }
                    )) {
                        Text(L10n.text("自动检测")).tag("auto")
                        Text("Terminal").tag("terminal")
                        Text("iTerm2").tag("iterm")
                        Text("WezTerm").tag("wezterm")
                        Text("Ghostty").tag("ghostty")
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
        }
    }

    // ---------------------------------------------------------- 状态栏 ----

    private var menubarProviderTitle: String {
        if provider == "off" { return L10n.text("仅今日用量") }
        if provider == "tokens" { return L10n.text("仅显示 Token 数字") }
        if let entry = state.quotaEntries.first(where: { $0.id == provider }) {
            return L10n.text("今日用量 + \(entry.name)")
        }
        return L10n.text("仅今日用量")
    }

    private var menubar: some View {
        SettingsSection(L10n.text("状态栏标题")) {
            SettingsRow(L10n.text("标题显示")) {
                SettingsMenuPicker(title: menubarProviderTitle) {
                    Picker(L10n.text("标题显示"), selection: Binding(
                        get: { provider },
                        set: { state.updateSetting(key: "menubar_provider", value: $0) }
                    )) {
                        ForEach(state.quotaEntries, id: \.id) { entry in
                            LocalizedText("今日用量 + \(entry.name)").tag(entry.id)
                        }
                        Text(L10n.text("仅今日用量")).tag("off")
                        Text(L10n.text("仅显示 Token 数字")).tag("tokens")
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            SettingsDivider()
            SettingsToggle(L10n.text("圆环显示配额"), isOn: binding("menubar_ring"))
                .disabled(provider == "tokens")
            SettingsDivider()
            SettingsToggle(L10n.text("紧凑标题"), isOn: binding("menubar_compact"))
            SettingsDivider()
            SettingsToggle(L10n.text("大数以「亿」显示"),
                           detail: L10n.text("中文使用万／亿；英文使用 K/M/B。"),
                           isOn: binding("unit_yi"))
                .disabled(L10n.isEnglish)
        }
    }

    // -------------------------------------------------------- 刘海圆环 ----

    @ViewBuilder
    private var notchSettings: some View {
        SettingsSection(footer: L10n.text("固定显示在内置屏幕刘海左侧；全屏时隐藏。长菜单可能与圆环重叠，可从状态栏菜单快速隐藏。")) {
            SettingsToggle(L10n.text("显示刘海圆环"), isOn: $notch.enabled)
            SettingsDivider()
            SettingsRow(L10n.text("额度显示")) {
                SettingsMenuPicker(title: notch.quotaDisplay.label) {
                    Picker(L10n.text("额度显示"), selection: $notch.quotaDisplay) {
                        ForEach(NotchHUDQuotaDisplay.allCases) { mode in Text(mode.label).tag(mode) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .disabled(!notch.enabled)
        }
        SettingsSection(L10n.text("显示的账号"),
                        footer: L10n.text("仅显示当前登录账号的官方配额；本地 Token 不用于推算订阅额度。")) {
            ForEach(Array(notchProviders.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { SettingsDivider() }
                SettingsToggle(entry.name, isOn: Binding(
                    get: { notch.providers.contains(entry.id) },
                    set: { notch.setProvider(entry.id, visible: $0) }
                ))
                .disabled(!notch.enabled || (notch.providers.count == 1 && notch.providers.contains(entry.id)))
            }
        }
    }

    // ------------------------------------------------------- 价格与数据 ----

    @ViewBuilder
    private var dataSettings: some View {
        SettingsSection(L10n.text("价格估算")) {
            SettingsToggle(L10n.text("自动同步官方价格"),
                           detail: L10n.text("每天从模型供应商的公开页面更新 API 费率。关闭后仍用本机已保存的费率估算；Token 统计和来源费用不受影响。"),
                           isOn: binding("price_sync_enabled"))
            SettingsDivider()
            SettingsRow(priceSyncStatusText, detail: priceSyncDetail) {
                HStack(spacing: 8) {
                    if state.priceSyncRunning { ProgressView().controlSize(.small) }
                    Button(L10n.text("立即同步")) { state.syncPricesNow() }
                        .disabled(state.priceSyncRunning)
                }
            }
            if !state.priceSyncMessage.isEmpty {
                Text(state.priceSyncMessage)
                    .font(.caption)
                    .foregroundStyle(state.priceSyncState == "failed" ? .red : .secondary)
                    .lineLimit(3)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        SettingsSection(L10n.text("本地数据"),
                        footer: L10n.text("原始用量日志始终只在本机读取和保存。设置保存在 ~/.tokentracker/settings.json。")) {
            SettingsRow(L10n.text("数据目录"), detail: "~/.tokentracker") {
                Button(L10n.text("在 Finder 中打开")) {
                    let path = NSHomeDirectory() + "/.tokentracker"
                    try? FileManager.default.createDirectory(atPath: path,
                                                             withIntermediateDirectories: true)
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            }
        }
        AntigravityWorkspaceHookSection(state: state)
    }

    private var priceSyncDetail: String {
        guard state.priceSyncLastSuccessAtMs > 0 else { return L10n.text("上次成功同步：从未") }
        let date = Date(timeIntervalSince1970: Double(state.priceSyncLastSuccessAtMs) / 1000)
        return L10n.text("上次成功同步：\(date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)))")
    }

    // ------------------------------------------------------- 关于与更新 ----

    @ViewBuilder
    private var about: some View {
        SettingsSection {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("TokenTracker").font(.title3.weight(.semibold))
                    Text("v\(TokenTrackerCore.version)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Link(L10n.text("作者主页"), destination: URL(string: "https://sakuramu.edu.kg/")!)
            }
            .padding(16)
        }
        SettingsSection(L10n.text("更新")) {
            SettingsToggle(L10n.text("接收测试版更新"),
                           detail: L10n.text("开启后会收到尚未正式发布的开发版本，可能不稳定；关闭后只接收正式版，已装的测试版不会自动回退。"),
                           isOn: Binding(
                get: { state.prefs.updateBeta },
                set: { on in
                    state.updateSetting(key: "update_beta", value: on)
                    // 换通道后旧的检查结果不再适用，马上按新通道查一次
                    state.updateInfo = nil
                    updater.check(applyTo: state)
                }
            ))
            SettingsDivider()
            updateRow
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }

    private var notchProviders: [MenuBarQuotaEntry] {
        var entries = state.quotaEntries
        for id in notch.providers where !entries.contains(where: { $0.id == id }) {
            entries.append(MenuBarQuotaEntry(id: id, name: id == "codex" ? "Codex" : id == "claude" ? "Claude" : id, windows: []))
        }
        return entries
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
    private var publishSettings: some View {
        SettingsSection(footer: publishPrivacyText) {
            SettingsToggle(L10n.text("扫描后自动上传"), isOn: Binding(
                get: { state.prefs.publishEnabled },
                set: { state.setPublishEnabled($0) }
            ))
        }
        SettingsSection(L10n.text("服务配置")) {
            SettingsRow(L10n.text("HTTPS 服务地址")) {
                TextField(L10n.text("HTTPS 服务地址"), text: $publishEndpoint,
                          prompt: Text("https://tt.example.com"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }
            SettingsDivider()
            SettingsRow(L10n.text("用户名")) {
                TextField(L10n.text("用户名"), text: $publishHandle, prompt: Text("your-handle"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }
            SettingsDivider()
            SettingsRow(L10n.text("公开时间范围")) {
                SettingsMenuPicker(title: publishDaysTitle) {
                    Picker(L10n.text("公开时间范围"), selection: $publishDays) {
                        Text(L10n.text("90 天")).tag(90)
                        Text(L10n.text("365 天")).tag(365)
                        Text(L10n.text("730 天")).tag(730)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            SettingsDivider()
            SettingsRow(L10n.text("发布 Token")) {
                HStack(spacing: 8) {
                    SettingsBadge(text: state.publishTokenConfigured ? L10n.text("已配置") : L10n.text("未配置"),
                                tint: state.publishTokenConfigured ? .green : .secondary)
                    SecureField(L10n.text("发布 Token（留空保持现有）"), text: $publishToken)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }
            }
            SettingsDivider()
            HStack {
                if let url = state.publicStatsURL {
                    Link(L10n.text("打开公开数据 →"), destination: url).font(.callout)
                }
                Spacer()
                Button(L10n.text("保存配置")) {
                    state.savePublishConfiguration(endpoint: publishEndpoint,
                                                   handle: publishHandle,
                                                   days: publishDays,
                                                   token: publishToken)
                    publishToken = ""
                    loadPublishDrafts()
                }
                .buttonStyle(SettingsPrimaryButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        SettingsSection(L10n.text("上传")) {
            publishStatus
            SettingsDivider()
            HStack(spacing: 10) {
                Button(L10n.text("按规则上传")) { state.performPublish(trigger: .manual) }
                    .disabled(!state.publishConfigurationReady || state.publishBusy)
                Button(L10n.text("强制上传…")) { showForceConfirmation = true }
                    .disabled(!state.publishConfigurationReady || state.publishBusy)
                if state.publishBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button(L10n.text("查看上传记录…")) { state.showPublishHistory() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            if let message = state.publishMessage, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(state.publishFailed ? .red : .secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
    }

    @ViewBuilder
    private var publishStatus: some View {
        let snapshot = state.publishState
        SettingsRow(L10n.text("上次成功")) {
            Text(snapshot.lastSuccessAt > 0
                 ? Date(timeIntervalSince1970: snapshot.lastSuccessAt)
                    .formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale))
                 : L10n.text("从未"))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        SettingsDivider()
        SettingsRow(L10n.text("本机上传记录")) {
            Text(L10n.text("\(state.publishHistory.count) 条"))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        if !snapshot.lastError.isEmpty {
            SettingsDivider()
            Text(L10n.text("上次错误：\(snapshot.lastError)"))
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .help(snapshot.lastError)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }

    private var publishPrivacyText: String {
        let enabled = state.prefs.publishEnabled
        return enabled
            ? L10n.text("自动上传已开启。只发送聚合数字；项目路径、会话、提示词、模型名和账号信息不会上传。")
            : L10n.text("自动上传已关闭。手动上传仍可使用；原始日志和敏感信息不会离开本机。")
    }

    private var publishDaysTitle: String {
        switch publishDays {
        case 90: L10n.text("90 天")
        case 730: L10n.text("730 天")
        default: L10n.text("365 天")
        }
    }

    private func loadPublishDrafts() {
        publishEndpoint = state.prefs.publishEndpoint
        publishHandle = state.prefs.publishHandle
        publishDays = state.prefs.publishDays
    }

    // ------------------------------------------------------------ 更新 ----

    @ViewBuilder
    private var updateRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                statusText
                Spacer()
                Button(updater.stage == .checking ? L10n.text("检查中…") : L10n.text("检查更新")) {
                    updater.check(applyTo: state)
                }
                .disabled(updater.busy)
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
            } else {
                Text(L10n.text("软件更新"))
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

/// 「状态栏显示的端口」：勾选本机正在监听的端口，或提前加上还没运行的端口号。
struct MenuBarPortsSection: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var state: AppState
    @ObservedObject var model: PortsModel
    @State private var draft = ""
    @State private var hint: String?

    private static let limit = 20

    private var pinned: [Int] { state.prefs.menubarPorts }
    private var all: [Int] { Set(model.ports.map(\.port)).union(pinned).sorted() }

    var body: some View {
        SettingsSection(L10n.text("状态栏显示的端口"),
                        footer: L10n.text("勾选的端口只有正在运行时才出现在状态栏面板里。")) {
            if all.isEmpty {
                Text(model.loaded ? L10n.text("没有正在监听的端口") : L10n.text("正在扫描端口…"))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                SettingsDivider()
            }
            ForEach(all, id: \.self) { number in
                HStack(spacing: 10) {
                    Toggle(isOn: Binding(get: { pinned.contains(number) },
                                         set: { set(number, $0) })) {
                        HStack(spacing: 8) {
                            Text(verbatim: ":\(number)").font(.body.monospacedDigit()).frame(minWidth: 64, alignment: .leading)
                            Text(owner(number)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .toggleStyle(SettingsCheckboxStyle())
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                SettingsDivider()
            }
            HStack(spacing: 8) {
                TextField("", text: $draft, prompt: Text(L10n.text("添加端口号，例如 8080")))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .onSubmit(add)
                Button(L10n.text("添加"), action: add)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .onAppear { model.beginWatching() }
        .onDisappear { model.endWatching() }
    }

    private func owner(_ number: Int) -> String {
        guard let port = model.ports.first(where: { $0.port == number }) else { return L10n.text("未运行") }
        return port.projectName ?? port.process
    }

    private func set(_ number: Int, _ on: Bool) {
        var next = Set(pinned)
        if on {
            guard next.count < Self.limit else {
                hint = L10n.text("最多选择 \(Self.limit) 个端口")
                return
            }
            next.insert(number)
        } else {
            next.remove(number)
        }
        hint = nil
        state.updateSetting(key: "menubar_ports", value: next.sorted())
    }

    private func add() {
        guard let number = Int(draft.trimmingCharacters(in: .whitespaces)), (1...65535).contains(number) else {
            hint = L10n.text("端口号需要是 1–65535 之间的整数")
            return
        }
        draft = ""
        set(number, true)
    }
}

/// 可选的 Antigravity 全局 hooks.json 工作区映射配置（在「价格与数据」中展示）。
struct AntigravityWorkspaceHookSection: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var state: AppState
    @State private var installed = false
    @State private var mappedCount = 0
    @State private var preview: AntigravityHookConfiguration?
    @State private var installing = true
    @State private var notice: String?

    private var hookPath: String { AntigravityHookConfiguration.defaultPath }
    private var channel: String { TaskReminderModel.channel }

    var body: some View {
        SettingsSection(
            L10n.text("Antigravity 工作区映射"),
            footer: L10n.text("可选。仅靠本地日志即可统计 Antigravity 的 Token 与会话；接入全局 hooks.json 后仅额外记录会话与工作区目录的对应关系，用于项目归属，不保存提示词或内容。")
        ) {
            SettingsRow(L10n.text("全局 Hooks 配置"), detail: "~/.gemini/config/hooks.json") {
                HStack(spacing: 8) {
                    SettingsBadge(text: L10n.text(installed ? "已配置" : "未配置"),
                                  tint: installed ? .green : .secondary)
                    Menu {
                        Button(L10n.text("移除接入…")) { prepare(installing: false) }
                            .disabled(!installed)
                    } label: {
                        Label(L10n.text("更多"), systemImage: "ellipsis.circle")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.pageIcon)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    Button(L10n.text("配置接入…")) { prepare(installing: true) }
                }
            }
            SettingsDivider()
            SettingsRow(L10n.text("已记录会话目录")) {
                Text(L10n.text("\(mappedCount) 个会话"))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let notice {
                SettingsDivider()
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: state.updatedAt) { _, _ in reload() }
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
                }
                .padding(20)
                .frame(width: 760, height: 540)
            }
        }
    }

    private func reload() {
        installed = AntigravityHookConfiguration.isInstalled(path: hookPath, channel: channel)
        mappedCount = AntigravityWorkspaceMap.load(path: state.scanRoots.antigravityWorkspaceMap).count
    }

    private func configView(_ title: String, data: Data?) -> some View {
        let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return VStack(alignment: .leading) {
            Text(title).font(.headline)
            ScrollView([.vertical, .horizontal]) {
                Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func prepare(installing: Bool) {
        self.installing = installing
        do {
            preview = try AntigravityHookConfiguration.preview(
                path: hookPath,
                helper: TaskReminderModel.helperURL.path,
                channel: channel,
                installing: installing)
        } catch {
            notice = L10n.text("无法读取 Hooks 配置；未修改原文件")
        }
    }

    private func apply(_ preview: AntigravityHookConfiguration) {
        do {
            if installing {
                try TaskReminderModel.installHelper()
            }
            try preview.apply()
            reload()
            notice = L10n.text(installing
                ? "已配置 Antigravity 工作区映射；新会话或下轮对话结束后生效。"
                : "已移除 Antigravity 工作区映射；其他 Hooks 配置已保留。")
            self.preview = nil
            state.requestScan()
        } catch TaskBridgeError.unavailable {
            notice = L10n.text("未找到内置 Helper；请以打包后的 .app 运行后再配置。")
        } catch {
            notice = L10n.text("配置已变化或写入失败；未覆盖配置，请重新预览")
        }
    }
}
