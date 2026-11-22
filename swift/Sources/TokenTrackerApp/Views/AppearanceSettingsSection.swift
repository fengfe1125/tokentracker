//
//  AppearanceSettingsSection.swift
//  TokenTrackerApp
//
//  设置 › 外观与状态栏：合并原「状态栏」「刘海圆环」「导航」三个零散分类。
//  状态栏固定端口改为紧凑标签管理（完整端口操作统一在「端口」页），
//  刘海圆环关闭时隐藏子项，顶栏导航排序按需展开。
//

import SwiftUI
import TokenTrackerCore

struct AppearanceSettingsSection: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject private var notch = NotchHUDPreferences.shared
    @ObservedObject var state: AppState

    @State private var showAddPort = false
    @State private var portDraft = ""
    @State private var portHint: String?
    @State private var showNavigation = false

    private var provider: String { state.prefs.menubarProvider }
    private var pinnedPorts: [Int] { state.prefs.menubarPorts }

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { (state.settings[key] as? NSNumber)?.boolValue ?? false },
            set: { state.updateSetting(key: key, value: $0) }
        )
    }

    var body: some View {
        menubarSection
        notchSection
        navigationDisclosure
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

    private var menubarSection: some View {
        SettingsSection(L10n.text("状态栏"),
                        footer: L10n.text("固定的端口仅在运行时出现在状态栏面板里；可在「端口」页一键固定或取消。")) {
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
            pinnedPortsRow
        }
    }

    private var pinnedPortsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("状态栏固定端口"))
                    Text(pinnedPorts.isEmpty
                         ? L10n.text("尚未固定端口")
                         : L10n.text("已固定 \(pinnedPorts.count) 个端口"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(L10n.text("添加端口…")) {
                    portDraft = ""
                    portHint = nil
                    showAddPort = true
                }
                .popover(isPresented: $showAddPort, arrowEdge: .bottom) { addPortPopover }
                Button(L10n.text("前往端口页 →")) {
                    state.selection = .ports
                }
                .buttonStyle(.link)
                .font(.callout)
            }
            if !pinnedPorts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(pinnedPorts, id: \.self) { port in
                            HStack(spacing: 4) {
                                Text(verbatim: ":\(port)")
                                    .font(.caption.monospaced())
                                Button {
                                    removePort(port)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8.5, weight: .bold))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help(L10n.text("取消固定"))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.sunkSurface, in: Capsule())
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var addPortPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("固定端口到状态栏")).font(.headline)
            HStack(spacing: 8) {
                TextField("", text: $portDraft, prompt: Text(L10n.text("例如 3000")))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .onSubmit(addPort)
                Button(L10n.text("添加"), action: addPort)
                    .disabled(portDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let portHint {
                Text(portHint).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 240)
    }

    private func addPort() {
        guard let number = Int(portDraft.trimmingCharacters(in: .whitespaces)), (1...65535).contains(number) else {
            portHint = L10n.text("端口号需要是 1–65535 之间的整数")
            return
        }
        var next = Set(pinnedPorts)
        guard next.contains(number) || next.count < PortsModel.pinLimit else {
            portHint = L10n.text("最多选择 \(PortsModel.pinLimit) 个端口")
            return
        }
        next.insert(number)
        state.updateSetting(key: "menubar_ports", value: next.sorted())
        portDraft = ""
        portHint = nil
        showAddPort = false
    }

    private func removePort(_ port: Int) {
        let next = pinnedPorts.filter { $0 != port }
        state.updateSetting(key: "menubar_ports", value: next)
    }

    // -------------------------------------------------------- 刘海圆环 ----

    private var notchSection: some View {
        SettingsSection(
            L10n.text("刘海圆环"),
            footer: L10n.text("固定显示在内置屏幕刘海左侧；全屏时隐藏。仅展示当前登录账号的官方配额。")
        ) {
            SettingsToggle(L10n.text("显示刘海圆环"), isOn: $notch.enabled)
            if notch.enabled {
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
                ForEach(notchProviders, id: \.id) { entry in
                    SettingsDivider()
                    SettingsToggle(L10n.text("显示 \(entry.name)"), isOn: Binding(
                        get: { notch.providers.contains(entry.id) },
                        set: { notch.setProvider(entry.id, visible: $0) }
                    ))
                    .disabled(notch.providers.count == 1 && notch.providers.contains(entry.id))
                }
            }
        }
    }

    private var notchProviders: [MenuBarQuotaEntry] {
        var entries = state.quotaEntries
        for id in notch.providers where !entries.contains(where: { $0.id == id }) {
            let fallback = ["codex": "Codex", "claude": "Claude", "antigravity": "Antigravity"][id] ?? id
            entries.append(MenuBarQuotaEntry(id: id, name: fallback, windows: []))
        }
        return entries
    }

    // -------------------------------------------------------- 顶栏与 Agent ----

    private var navigationDisclosure: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection(L10n.text("顶栏与 Agent 显示")) {
                SettingsDisclosureRow(isExpanded: $showNavigation) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("自定义导航项与 Agent 顺序"))
                        Text(L10n.text("控制顶栏标签显隐与 Agent 筛选菜单顺序；隐藏不影响扫描。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if showNavigation {
                SidebarSettingsSection()
            }
        }
    }
}
