//
//  PublishHistoryWindowController.swift
//  TokenTrackerApp
//

import AppKit
import SwiftUI

@MainActor
final class PublishHistoryWindowController: NSObject {
    private var window: NSWindow?
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: PublishHistoryView(state: appState))
            let window = NSWindow(contentViewController: hosting)
            window.title = "上传记录"
            window.setContentSize(NSSize(width: 660, height: 460))
            window.minSize = NSSize(width: 560, height: 320)
            window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable])
            window.isReleasedWhenClosed = false
            self.window = window
        }
        appState.refreshPublishInfo()
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible == false { window?.center() }
        window?.makeKeyAndOrderFront(nil)
    }
}
