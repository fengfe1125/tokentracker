//
//  TokenTrackerApp.swift
//  TokenTrackerApp
//
//  应用入口：状态栏常驻 + 主面板（按需唤出）。
//  启动不弹窗、无 Dock 图标；⌘, 打开设置场景。
//

import SwiftUI

@main
struct TokenTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 主面板窗口由 MainWindowController 手动管理（NSHostingController）。
        // Settings 场景提供系统 ⌘, 入口。
        Settings {
            SettingsSceneView(state: appDelegate.appState)
        }
    }
}
