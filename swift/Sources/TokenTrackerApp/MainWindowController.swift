//
//  MainWindowController.swift
//  TokenTrackerApp
//
//  主面板窗口：红绿灯 + 原生阴影；关闭（红灯/⌘W）只隐藏不退出，
//  从状态栏随时唤回。无 Dock 图标（主面板打开时临时出现）。
//

import AppKit
import SwiftUI

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: RootView(state: appState))
            let window = NSWindow(contentViewController: hosting)
            window.title = "TokenTracker"
            window.setContentSize(NSSize(width: 1180, height: 780))
            window.minSize = NSSize(width: 900, height: 560)
            window.styleMask.formUnion([.miniaturizable, .resizable])
            window.isReleasedWhenClosed = false     // 关闭只隐藏
            window.delegate = self
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)         // 主面板打开时临时出现 Dock 图标
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible == false { window?.center() }
        window?.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    // NSWindowDelegate：红点关闭 → 只隐藏不退出
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }
}
