//
//  SettingsView.swift
//  TokenTrackerApp
//
//  设置：与 ~/.tokentracker/settings.json 双向同步（SettingsStore 白名单
//  校验写入），状态栏 5s 内热生效。开机启动走 SMAppService。
//

import AppKit
import ServiceManagement
import SwiftUI
import TokenTrackerCore

struct SettingsPanelView: View {
    @ObservedObject var state: AppState

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
        Form {
            Section("状态栏") {
                Picker("标题显示", selection: Binding(
                    get: { provider },
                    set: { state.updateSetting(key: "menubar_provider", value: $0) }
                )) {
                    ForEach(state.quotaEntries, id: \.id) { entry in
                        Text("今日用量 + \(entry.name)").tag(entry.id)
                    }
                    Text("仅今日用量").tag("off")
                }
                Toggle("圆环显示配额", isOn: binding("menubar_ring"))
                Toggle("紧凑标题", isOn: binding("menubar_compact"))
                Toggle("大数以「亿」显示", isOn: binding("unit_yi"))
            }
            Section("通用") {
                Toggle("开机自动启动", isOn: Binding(
                    get: { (state.settings["launch_at_login"] as? NSNumber)?.boolValue ?? false },
                    set: { on in
                        state.updateSetting(key: "launch_at_login", value: on)
                        applyLoginItem(on)
                    }
                ))
                Picker("终端 App（继续会话用）", selection: Binding(
                    get: { state.settings["terminal_app"] as? String ?? "auto" },
                    set: { state.updateSetting(key: "terminal_app", value: $0) }
                )) {
                    Text("自动检测").tag("auto")
                    Text("Terminal").tag("terminal")
                    Text("iTerm2").tag("iterm")
                    Text("WezTerm").tag("wezterm")
                    Text("Ghostty").tag("ghostty")
                }
            }
            Section("数据") {
                Button("在 Finder 中打开本地数据目录") {
                    let path = NSHomeDirectory() + "/.tokentracker"
                    try? FileManager.default.createDirectory(atPath: path,
                                                             withIntermediateDirectories: true)
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
                Text("用量日志在本机读取和保存，不上传。设置保存在 ~/.tokentracker/settings.json。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("关于") {
                HStack {
                    Text("TokenTracker")
                    Spacer()
                    Text("v\(TokenTrackerCore.version)")
                        .foregroundStyle(.secondary)
                }
                if let update = state.updateInfo,
                   UpdateChecker.updateAvailable(update, current: TokenTrackerCore.version) {
                    Link("发现新版本 \(update.latest) →", destination: URL(string: update.url)!)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
        .padding()
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
    @ObservedObject var state: AppState

    var body: some View {
        SettingsPanelView(state: state)
            .frame(width: 520, height: 420)
    }
}
