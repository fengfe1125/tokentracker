import AppKit
import SwiftUI

@MainActor
final class ActivityDetailWindowController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    func show() {
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        if !panel.isVisible { positionBesideMainWindow(panel) }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingController(rootView: ActivityDetailView(state: appState))
        let panel = NSPanel(contentViewController: hosting)
        panel.title = "Agent 活动详情"
        panel.styleMask.formUnion([.titled, .closable, .resizable, .utilityWindow])
        panel.setContentSize(NSSize(width: 980, height: 720))
        panel.minSize = NSSize(width: 760, height: 480)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        return panel
    }

    private func positionBesideMainWindow(_ panel: NSPanel) {
        let size = panel.frame.size
        guard let main = NSApp.windows.first(where: { $0 !== panel && $0.isVisible
                                                     && $0.frame.width > 600 }),
              let screen = main.screen ?? NSScreen.main else {
            panel.center()
            return
        }
        let visible = screen.visibleFrame
        let gap: CGFloat = 12
        var origin = NSPoint(x: main.frame.maxX + gap, y: main.frame.maxY - size.height)
        if origin.x + size.width > visible.maxX { origin.x = main.frame.minX - gap - size.width }
        if origin.x < visible.minX { origin.x = min(visible.maxX - size.width, main.frame.maxX - size.width) }
        origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
        panel.setFrameOrigin(origin)
    }
}
