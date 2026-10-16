import AppKit
import SwiftUI
import Combine
import Carbon

@MainActor
final class TaskReminderWindowController {
    private let model: TaskReminderModel
    private let hud: NotchHUDController
    private var panel: TaskReminderPanel?
    private var list: NSWindow?
    private var current: String?
    private var explicit = false
    private var closeTimer: Timer?
    private var geometryTimer: Timer?
    private var localMonitor: Any?
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var remaining = 8.0
    private var scheduledAt: Date?
    private var hovering = false
    private func debug(_ message: String) {
        if ProcessInfo.processInfo.environment["TT_DEBUG_NOTCH"] == "1" {
            FileHandle.standardError.write(Data("[task-card] \(message)\n".utf8))
        }
    }
    init(model: TaskReminderModel, hud: NotchHUDController) { self.model = model; self.hud = hud }
    func start() {
        model.onPresent = { [weak self] id, explicit in self?.show(id, explicit: explicit) }
        model.onShowList = { [weak self] in self?.showList() }
        hud.onOpenQuota = { [weak self] in self?.close() }
    }
    func showList() {
        if list == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = L10n.text("任务提醒"); window.isReleasedWhenClosed = false
            window.center(); list = window
        }
        list?.contentView = NSHostingView(rootView: TaskReminderList(model: model).appLanguage())
        list?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func show(_ id: String, explicit: Bool) {
        guard let row = model.reminders.first(where: { $0.id == id }) else { return }
        close()
        // Automatic cards obey the same notch/full-screen/session visibility as quota.
        if !explicit && hud.taskAnchor == nil { return }
        hud.closeDetail()
        current = id; self.explicit = explicit; remaining = 8; hovering = false
        let panel = panel ?? TaskReminderPanel()
        panel.interactive = explicit
        panel.contentView = NSHostingView(rootView: TaskReminderCard(model: model, id: id,
            close: { [weak self] in self?.close() }, hover: { [weak self] in self?.hover($0) }).appLanguage())
        self.panel = panel
        place()
        if explicit { panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        else { panel.orderFrontRegardless(); panel.makeMain() }
        installDismissal()
        debug("show explicit=\(explicit) frame=\(panel.frame) key=\(panel.isKeyWindow)")
        if row.state == .ended { scheduleClose() }
        geometryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
    }
    private func place() {
        guard let panel, current != nil else { return }
        if let anchor = hud.taskAnchor, let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) {
            let target = NotchHUDLayout.cardFrame(strip: anchor, screen: screen.frame,
                size: CGSize(width: 360, height: 420))
            if NotchHUDLayout.needsPlacement(current: panel.frame, target: target) {
                panel.setFrame(target, display: true)
            }
        } else if explicit {
            if panel.frame.size != CGSize(width: 360, height: 420) {
                panel.setContentSize(CGSize(width: 360, height: 420)); panel.center()
            }
        } else { debug("anchor hidden"); close() }
    }
    private func hover(_ inside: Bool) {
        hovering = inside
        if inside {
            if let scheduledAt { remaining = max(0, remaining - Date().timeIntervalSince(scheduledAt)) }
            closeTimer?.invalidate(); closeTimer = nil; scheduledAt = nil
        } else { scheduleClose() }
    }
    private func scheduleClose() {
        guard let id = current, model.reminders.first(where: { $0.id == id })?.state == .ended,
              !hovering, closeTimer == nil else { return }
        scheduledAt = Date()
        closeTimer = Timer.scheduledTimer(withTimeInterval: max(0.1, remaining), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }
    private func installDismissal() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            MainActor.assumeIsolated { if event.keyCode == 53 { self?.close() } }
            return event
        }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { Unmanaged<TaskReminderWindowController>.fromOpaque(context).takeUnretainedValue().close() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
        if result == noErr {
            _ = RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: 0x54545441, id: 2),
                                   GetApplicationEventTarget(), 0, &hotKey)
        }
    }
    func close() {
        panel?.orderOut(nil); current = nil
        closeTimer?.invalidate(); closeTimer = nil; scheduledAt = nil
        geometryTimer?.invalidate(); geometryTimer = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
        if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }; hotKeyHandler = nil
    }
}

final class TaskReminderPanel: NSPanel {
    var interactive = false
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        identifier = NSUserInterfaceItemIdentifier("tt.task.card"); title = "TokenTracker"
        isOpaque = false; backgroundColor = .clear; hasShadow = true; isReleasedWhenClosed = false
        hidesOnDeactivate = false; level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    }
    override var canBecomeKey: Bool { interactive }
    override var canBecomeMain: Bool { true }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { interactive = true }
        super.sendEvent(event)
    }
}
