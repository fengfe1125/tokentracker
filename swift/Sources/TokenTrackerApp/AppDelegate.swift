//
//  AppDelegate.swift
//  TokenTrackerApp
//
//  组装应用：AppState（数据 + 调度）→ StatusItemController（状态栏）→
//  MainWindowController（主面板）。5s 轮询驱动状态栏渲染/自愈。
//

import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var statusItem: StatusItemController?
    private var mainWindow: MainWindowController?
    private var detailWindow: SessionDetailWindowController?
    private var tickTimer: Timer?
    private var wasScanning = false

    private func dbg(_ message: String) {
        // 诊断输出（TT_DEBUG_TITLE=1 时生效；.app 场景 stderr 不可见，只用于排障）
        guard ProcessInfo.processInfo.environment["TT_DEBUG_TITLE"] == "1" else { return }
        FileHandle.standardError.write(Data("[tt] \(message)\n".utf8))
    }

    func applicationDidFinishLaunching(_: Notification) {
        dbg("AppDelegate.start")
        NSApp.setActivationPolicy(.accessory)   // 无 Dock 图标

        let bar = StatusItemController(appState: appState)
        bar.onOpenMain = { [weak self] in self?.showMainPanel() }
        bar.onOpenSettings = { [weak self] in self?.openSettings() }
        bar.onQuit = { NSApp.terminate(nil) }
        bar.install()
        statusItem = bar
        dbg("statusItem installed")

        mainWindow = MainWindowController(appState: appState)
        let detail = SessionDetailWindowController(appState: appState)
        appState.onSessionDetail = { explicit in explicit ? detail.show() : detail.autoShow() }
        detailWindow = detail
        appState.start()
        dbg("appState started")

        // 5s 一件事：渲染 / 动画启停 / 自愈 / 轻推（对齐 menubar.py tt_loop）
        tickTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.appState.scanning && !self.wasScanning {
                    self.statusItem?.noteScanningStarted()
                }
                self.wasScanning = self.appState.scanning
                self.statusItem?.tickMain()
            }
        }

        installFileMenu()   // ⌘W 关闭主面板（只隐藏）
    }

    func applicationWillTerminate(_: Notification) {
        appState.scheduler.stop()
    }

    private func showMainPanel() {
        mainWindow?.show()
    }

    private func openSettings() {
        showMainPanel()
        appState.selection = .settings
    }

    /// 文件菜单提供 ⌘W（关闭主面板 = 隐藏）。
    private func installFileMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let fileMenu = NSMenu(title: "文件")
        let closeItem = NSMenuItem(title: "关闭", action: #selector(NSWindow.performClose(_:)),
                                   keyEquivalent: "w")
        fileMenu.addItem(closeItem)
        let fileMenuItem = NSMenuItem(title: "文件", action: nil, keyEquivalent: "")
        fileMenuItem.submenu = fileMenu
        mainMenu.insertItem(fileMenuItem, at: 1)
    }
}
