//
//  SettingsView.swift
//  TokenTrackerApp
//
//  设置：收拢为 5 个清晰分类（通用 / 外观与状态栏 / 提醒与集成 / 数据与同步 / 关于与更新），
//  与 ~/.tokentracker/settings.json 双向同步（SettingsStore 白名单校验写入），状态栏 5s 内热生效。
//  账号管理在「账号」页（AccountsView），完整端口管理在「端口」页（PortsView）。
//

import AppKit
import ServiceManagement
import SwiftUI
import TokenTrackerCore

/// 设置分类；rawValue 同时是持久化键（resolve(_:) 兼容历史 8 标签保存值）。
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appearance, integrations, data, about
    static let storageKey = "tt.settings.tab"
    var id: String { rawValue }

    /// 兼容旧版本保存的分类键（menubar / notch / navigation -> appearance，reminders -> integrations，publish -> data）。
    static func resolve(_ raw: String?) -> SettingsTab {
        guard let raw else { return .general }
        if let direct = SettingsTab(rawValue: raw) { return direct }
        switch raw {
        case "menubar", "notch", "navigation": return .appearance
        case "reminders": return .integrations
        case "publish": return .data
        default: return .general
        }
    }

    var title: String {
        switch self {
        case .general: L10n.text("通用")
        case .appearance: L10n.text("外观与状态栏")
        case .integrations: L10n.text("提醒与集成")
        case .data: L10n.text("数据与同步")
        case .about: L10n.text("关于与更新")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "menubar.rectangle"
        case .integrations: "bell.badge.fill"
        case .data: "externaldrive.fill"
        case .about: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .appearance: .blue
        case .integrations: .orange
        case .data: .green
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
    @AppStorage(SettingsTab.storageKey) private var tabRaw = SettingsTab.general.rawValue
    @ObservedObject var state: AppState
    @StateObject private var updater = UpdaterModel()
    @State private var hoveredTab: SettingsTab?
    @State private var pressedTab: SettingsTab?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tab: SettingsTab { SettingsTab.resolve(tabRaw) }

    private func select(_ next: SettingsTab) {
        tabRaw = next.rawValue
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
    }

    /// 左侧分类：图标方块 + 名称，选中为浮起中性卡片胶囊，弹簧滑动切换。
    private var categoryList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsTab.allCases) { item in
                    let selected = tab == item
                    let pressed = pressedTab == item
                    Button { select(item) } label: {
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
        case .appearance: AppearanceSettingsSection(state: state)
        case .integrations: IntegrationsSettingsSection(state: state)
        case .data: DataSettingsSection(state: state)
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

    private var scanIntervalTitle: String {
        switch state.scanIntervalSeconds {
        case 30: return "30s"
        case 300: return L10n.text("5分钟")
        case 600: return L10n.text("10分钟")
        default: return L10n.text("1分钟")
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
            SettingsRow(L10n.text("终端 App"), detail: L10n.text("继续会话或启动开发项目时打开的终端。")) {
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
            SettingsDivider()
            SettingsRow(L10n.text("自动扫描间隔")) {
                SettingsMenuPicker(title: scanIntervalTitle) {
                    Picker(L10n.text("刷新间隔"), selection: Binding(
                        get: { state.scanIntervalSeconds },
                        set: { state.updateSetting(key: "scan_interval", value: $0) }
                    )) {
                        Text("30s").tag(30)
                        Text(L10n.text("1分钟")).tag(60)
                        Text(L10n.text("5分钟")).tag(300)
                        Text(L10n.text("10分钟")).tag(600)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            SettingsDivider()
            SettingsToggle(L10n.text("大数以「亿」显示"),
                           detail: L10n.text("中文使用万／亿；英文使用 K/M/B。"),
                           isOn: binding("unit_yi"))
                .disabled(L10n.isEnglish)
        }
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
