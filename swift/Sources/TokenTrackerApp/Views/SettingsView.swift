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
    @StateObject private var updater = UpdaterModel()

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
            PanelHeader(title: "设置")
            form
        }
        .navigationTitle("设置")
    }

    private var form: some View {
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
                updateRow
            }
        }
        // .grouped 自带内边距，外面不再叠 .padding()（此前是双份）
        .formStyle(.grouped)
    }

    // ------------------------------------------------------------ 更新 ----

    @ViewBuilder
    private var updateRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(updater.stage == .checking ? "检查中…" : "检查更新") {
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
                    Text("正在下载 \(Int(fraction * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .installing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在替换应用…").font(.caption).foregroundStyle(.secondary)
                }
            case .installed:
                HStack {
                    Text("新版本已装好").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("重启以完成更新") { updater.relaunch() }
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
            Text("已是最新版本").font(.caption).foregroundStyle(.secondary)
        case .available(let release):
            Text("发现 \(release.tag)").font(.caption).foregroundStyle(.orange)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
                .lineLimit(2).help(message)
        default:
            // 没手动查过就用启动时那次后台检查的结果
            if let update = state.updateInfo,
               UpdateChecker.updateAvailable(update, current: TokenTrackerCore.version) {
                Link("发现新版本 \(update.latest) →", destination: URL(string: update.url)!)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func availableRow(_ release: ReleaseInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if release.dmg != nil, updater.appPath != nil {
                    Button("下载并安装") { updater.downloadAndInstall(release) }
                        .disabled(updater.busy)
                }
                if let url = URL(string: release.htmlURL), !release.htmlURL.isEmpty {
                    Link("查看发布说明 →", destination: url).font(.caption)
                }
            }
            if let dmg = release.dmg, updater.appPath != nil {
                Text("会下载 \(dmg.name)（\(ByteCountFormatter.string(fromByteCount: dmg.size, countStyle: .file))），"
                     + "校验后替换当前应用，然后需要重启。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if updater.appPath == nil {
                Text("当前不是以 .app 方式运行，只能手动下载。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("这个版本没有提供 .dmg 安装包，请到发布页手动下载。")
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
    @ObservedObject var state: AppState

    var body: some View {
        SettingsPanelView(state: state)
            .frame(width: 520, height: 420)
    }
}
