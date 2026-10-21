//
//  TokenTrackerApp.swift
//  TokenTrackerApp
//
//  应用入口：状态栏常驻 + 主面板（按需唤出）。
//  手动启动显示主面板，登录项启动仅驻留菜单栏；⌘, 打开主面板设置页。
//

import SwiftUI

@main
struct TokenTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 主面板窗口由 MainWindowController 手动管理（NSHostingController）。
        // AppKit owns the status item and every window. A non-inserted menu
        // scene supplies app commands without a default/restorable window.
        MenuBarExtra("TokenTracker", isInserted: .constant(false)) {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(L10n.text("设置…")) { appDelegate.openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
