//
//  AppPreferences.swift
//  TokenTrackerApp
//
//  settings.json 的带类型读取。键名和默认值只在这里出现一次；
//  写入仍走 AppState.updateSetting（SettingsStore 负责白名单校验）。
//

import Foundation
import TokenTrackerCore

struct AppPreferences {
    /// effective 设置：默认值 + 校验后的已存值
    let values: [String: Any]

    private func bool(_ key: String, _ fallback: Bool) -> Bool {
        (values[key] as? NSNumber)?.boolValue ?? fallback
    }
    private func int(_ key: String, _ fallback: Int) -> Int {
        (values[key] as? NSNumber)?.intValue ?? fallback
    }
    private func string(_ key: String, _ fallback: String) -> String {
        values[key] as? String ?? fallback
    }

    /// 大数以「亿」显示
    var unitYi: Bool { bool("unit_yi", false) }
    /// 状态栏标题追加显示的平台配额；"off" = 仅今日用量，"tokens" = 仅数字
    var menubarProvider: String { string("menubar_provider", MenuBarFmt.defaultProvider) }
    var menubarCompact: Bool { bool("menubar_compact", false) }
    var menubarRing: Bool { bool("menubar_ring", true) }
    var launchAtLogin: Bool { bool("launch_at_login", false) }
    /// 继续会话用哪个终端
    var terminalApp: String { string("terminal_app", "auto") }
    /// 自动扫描/刷新节奏（秒）
    var scanInterval: Int { int("scan_interval", 60) }
    var priceSyncEnabled: Bool { bool("price_sync_enabled", true) }
    /// 接收测试版（预发布）更新
    var updateBeta: Bool { bool("update_beta", false) }
    var publishEnabled: Bool { bool("publish_enabled", false) }
    var publishEndpoint: String { string("publish_endpoint", "") }
    var publishHandle: String { string("publish_handle", "") }
    var publishDays: Int { int("publish_days", 365) }
    /// 状态栏面板里显示的端口
    var menubarPorts: [Int] {
        ((values["menubar_ports"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.intValue }.sorted()
    }
    /// 手动填写的启动命令：项目目录 → 命令
    var projectCommands: [String: String] { values["project_commands"] as? [String: String] ?? [:] }
}

extension AppState {
    var prefs: AppPreferences { AppPreferences(values: settings) }
}
