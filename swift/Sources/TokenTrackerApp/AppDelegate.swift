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
    private var activityDetailWindow: ActivityDetailWindowController?
    private var publishHistoryWindow: PublishHistoryWindowController?
    private var tickTimer: Timer?
    private var wasScanning = false
    private var languageObserver: NSObjectProtocol?
    private var windowObserver: NSObjectProtocol?
    private var menuObserver: NSObjectProtocol?
    private var menuCompositionObserver: NSObjectProtocol?
    private var menuLocalizationPending = false

    private func dbg(_ message: String) {
        // 诊断输出（TT_DEBUG_TITLE=1 时生效；.app 场景 stderr 不可见，只用于排障）
        guard ProcessInfo.processInfo.environment["TT_DEBUG_TITLE"] == "1" else { return }
        FileHandle.standardError.write(Data("[tt] \(message)\n".utf8))
    }

    func applicationDidFinishLaunching(_: Notification) {
        dbg("AppDelegate.start")
        if ProcessInfo.processInfo.environment["TT_UI_PREVIEW"] == "1", ProcessInfo.processInfo.environment["TT_UI_PREVIEW_DARK"] == "1" { NSApp.appearance = NSAppearance(named:.darkAqua) }
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
        let activityDetail = ActivityDetailWindowController(appState: appState)
        appState.onActivityDetail = { activityDetail.show() }
        activityDetailWindow = activityDetail
        let history = PublishHistoryWindowController(appState: appState)
        appState.onPublishHistory = { history.show() }
        publishHistoryWindow = history
        if ProcessInfo.processInfo.environment["TT_UI_TEST_SHOW_MAIN"] == "1" {
            appState.selection = .activity
            DispatchQueue.main.async { [weak self] in self?.showMainPanel() }
        }
        appState.insights.onInspect = { [weak self] in self?.appState.selection = .projects; self?.showMainPanel() }
        appState.insights.onSession = { [weak self] tool,session in self?.appState.showInsightSession(tool:tool,sessionID:session) }
        appState.insights.onNavigate = { [weak self] project in
            self?.appState.insights.query.projectID = project
            self?.appState.selection = .projects
            self?.showMainPanel()
        }
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

        _ = LanguageManager.shared
        languageObserver = NotificationCenter.default.addObserver(forName: .appLanguageChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.statusItem?.languageDidChange()
                self?.installFileMenu()
                self?.localizeStandardMenus()
                for window in NSApp.windows {
                    if let key = window.identifier?.rawValue,
                       ["会话详情", "Agent 活动详情", "上传记录", "数据健康"].contains(key) {
                        window.title = L10n.label(key)
                    }
                }
            }
        }
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleMenuLocalization() }
        }
        menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleMenuLocalization() }
        }
        menuCompositionObserver = NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleMenuLocalization() }
        }
        installFileMenu()
        localizeStandardMenus()   // ⌘W 关闭主面板（只隐藏）
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


    private func scheduleMenuLocalization() {
        guard !menuLocalizationPending else { return }
        menuLocalizationPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.menuLocalizationPending = false
            self.installFileMenu()
            self.localizeStandardMenus()
        }
    }

    private func localizeStandardMenus() {
        let actions: [String: String] = [
            "undo:": "撤销", "redo:": "重做", "cut:": "剪切", "copy:": "拷贝",
            "paste:": "粘贴", "delete:": "删除", "pasteAsPlainText:": "粘贴并匹配样式", "selectAll:": "全选",
            "performMiniaturize:": "最小化", "performZoom:": "缩放", "toggleFullScreen:": "切换全屏",
            "hide:": "隐藏 TokenTracker", "hideOtherApplications:": "隐藏其他", "unhideAllApplications:": "全部显示",
            "terminate:": "退出 TokenTracker", "orderFrontStandardAboutPanel:": "关于 TokenTracker",
            "showSettingsWindow:": "设置…", "showPreferencesWindow:": "设置…"
        ]
        let headings = ["编辑": "Edit", "显示": "View", "窗口": "Window", "帮助": "Help", "服务": "Services"]
        func update(_ menu: NSMenu) {
            for item in menu.items {
                if let action = item.action, let key = actions[NSStringFromSelector(action)] {
                    item.title = L10n.label(key)
                } else if let key = headings.first(where: { $0.key == item.title || $0.value == item.title })?.key {
                    item.title = L10n.label(key)
                }
                if let submenu = item.submenu {
                    submenu.title = item.title
                    update(submenu)
                }
            }
        }
        if let menu = NSApp.mainMenu { update(menu) }
    }

    /// 文件菜单提供 ⌘W（关闭主面板 = 隐藏）。
    private func installFileMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        if let existing = mainMenu.items.first(where: { $0.identifier?.rawValue == "tt.file" }) {
            existing.title = L10n.text("文件")
            existing.submenu?.items.first?.title = L10n.text("关闭")
            return
        }
        let fileMenu = NSMenu(title: L10n.text("文件"))
        let closeItem = NSMenuItem(title: L10n.text("关闭"), action: #selector(NSWindow.performClose(_:)),
                                   keyEquivalent: "w")
        fileMenu.addItem(closeItem)
        let fileMenuItem = NSMenuItem(title: L10n.text("文件"), action: nil, keyEquivalent: "")
        fileMenuItem.identifier = NSUserInterfaceItemIdentifier("tt.file")
        fileMenuItem.submenu = fileMenu
        mainMenu.insertItem(fileMenuItem, at: 1)
    }
}
