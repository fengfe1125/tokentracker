//
//  SessionDetailWindowController.swift
//  TokenTrackerApp
//
//  会话详情的独立浮动面板。用 NSPanel 而不是 .inspector：inspector 是从主
//  窗口里挤出来的一列，一展开表格就被压得看不全；面板是另一个窗口，可以拖到
//  一边，列表宽度不受影响。
//
//  becomesKeyOnlyIfNeeded：面板不抢键盘焦点，表格里方向键翻行时详情跟着变。
//

import AppKit
import SwiftUI

@MainActor
final class SessionDetailWindowController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let appState: AppState
    /// 用户手动关过一次就不再自动弹（双击 / ⌘I / 右键菜单可重新打开）
    private var userDismissed = false

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    /// 选中变化时调用：只在面板已开、且用户没主动关过时才露面。
    func autoShow() {
        guard appState.selectedSessionID != nil, !userDismissed else { return }
        present(activate: false)
    }

    /// 双击 / ⌘I / 右键「查看详情」：无条件打开。
    func show() {
        guard appState.selectedSessionID != nil else { return }
        userDismissed = false
        present(activate: true)
    }

    private func present(activate: Bool) {
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        if !panel.isVisible { positionBesideMainWindow(panel) }
        if activate {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFront(nil)   // 不抢焦点：表格里继续用方向键翻行
        }
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingController(rootView: SessionDetailView(state: appState).appLanguage())
        let panel = NSPanel(contentViewController: hosting)
        panel.identifier = NSUserInterfaceItemIdentifier("会话详情")
        panel.title = L10n.text("会话详情")
        panel.styleMask.formUnion([.titled, .closable, .resizable, .utilityWindow])
        panel.setContentSize(NSSize(width: 380, height: 620))
        panel.minSize = NSSize(width: 320, height: 300)
        panel.isFloatingPanel = true          // 浮在主面板之上，不会被压到后面
        panel.becomesKeyOnlyIfNeeded = true   // 点里面的文本框才拿焦点
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        return panel
    }

    /// 优先贴主面板右侧；右边放不下就贴左侧；都放不下才盖在右上角。
    private func positionBesideMainWindow(_ panel: NSPanel) {
        let size = panel.frame.size
        guard let main = NSApp.windows.first(where: { $0 !== panel && $0.isVisible
                                                     && $0.frame.width > 600 }),
              let screen = main.screen ?? NSScreen.main else {
            panel.center()
            return
        }
        let gap: CGFloat = 12
        let visible = screen.visibleFrame
        let top = main.frame.maxY
        var origin = NSPoint(x: main.frame.maxX + gap, y: top - size.height)
        if origin.x + size.width > visible.maxX {
            origin.x = main.frame.minX - gap - size.width
        }
        if origin.x < visible.minX {
            origin.x = min(visible.maxX - size.width, main.frame.maxX - size.width)
        }
        origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
        panel.setFrameOrigin(origin)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // 用户点红灯关掉 → 记住，之后单击选中不再自动弹出
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel else { return }
        userDismissed = true
    }
}
