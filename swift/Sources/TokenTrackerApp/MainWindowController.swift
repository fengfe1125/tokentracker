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
        log2("MainWindowController.show: window=\(window == nil ? "新建" : "唤回")")
        if window == nil {
            let hosting = NSHostingController(rootView: RootView(state: appState).appLanguage())
            let window = NSWindow(contentViewController: hosting)
            window.title = "TokenTracker"
            let narrow = ProcessInfo.processInfo.environment["TT_UI_PREVIEW_NARROW"] == "1"
            window.setContentSize(NSSize(width: narrow ? 820 : 960, height: narrow ? 520 : 640))
            window.minSize = NSSize(width: 820, height: 520)
            window.styleMask.formUnion([.miniaturizable, .resizable])
            window.isReleasedWhenClosed = false     // 关闭只隐藏
            window.delegate = self
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)         // 主面板打开时临时出现 Dock 图标
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible == false { window?.center() }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        log2("MainWindowController.show: done, visible=\(window?.isVisible == true)")
    }

    private func log2(_ message: String) {
        let path = ProcessInfo.processInfo.environment["TT_UI_PREVIEW"] == "1"
            ? NSTemporaryDirectory() + "/tokentracker-preview.log" : NSHomeDirectory() + "/.tokentracker/app.log"
        let line = "\(Date()) \(message)\n"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
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
