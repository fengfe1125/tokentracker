import AppKit
import Carbon
import Combine
import SwiftUI
import TokenTrackerCore

@MainActor
final class NotchHUDController {
    private let state: AppState
    private let preferences: NotchHUDPreferences
    let detail: NotchHUDDetailModel
    private var strip: NotchHUDPanel?
    private var card: NotchHUDPanel?
    private var tooltip: NotchHUDPanel?
    private var subscriptions: Set<AnyCancellable> = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var visibilityTimer: Timer?
    private var hoverTask: Task<Void, Never>?
    private var hovered: String?
    private var localMouse: Any?
    private var globalMouse: Any?
    private var localKey: Any?
    private var escapeKey: EventHotKeyRef?
    private var escapeHandler: EventHandlerRef?
    private var openedAt: TimeInterval = 0
    private var sessionActive = true
    private var menuTracking = false
    private var anchorScreen: NSScreen?
    private var lastVisible = false
    var onOpenMain: (() -> Void)?
    var onOpenQuota: (() -> Void)?
    var taskAnchor: CGRect? { strip?.isVisible == true ? strip?.frame : nil }

    init(state: AppState, preferences: NotchHUDPreferences = .shared) {
        self.state = state
        self.preferences = preferences
        let path = state.readStore.path
        let quotasPath = ProcessInfo.processInfo.environment["TOKENTRACKER_QUOTAS"] ?? ""
        detail = NotchHUDDetailModel { provider in
            try await Task.detached(priority: .userInitiated) {
                let tool = QuotasConfig.load(from: quotasPath).entries.first { $0.id == provider }?.tool ?? provider
                return try NotchHUDUsage.load(path: path, provider: tool)
            }.value
        }
    }

    func start() {
        preferences.$enabled.combineLatest(preferences.$providers)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.preferencesChanged() }
            .store(in: &subscriptions)
        state.$updatedAt.dropFirst().sink { [weak self] _ in self?.detail.refresh() }
            .store(in: &subscriptions)
        NSApp.publisher(for: \.currentSystemPresentationOptions)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcile() }
            .store(in: &subscriptions)
        let center = NotificationCenter.default
        observe(center, NSApplication.didChangeScreenParametersNotification) { $0.reconcile() }
        observe(center, .appLanguageChanged) { $0.rebuildStrip(); $0.reconcile() }
        // Let native menus take precedence over the fixed-position overlay.
        observe(center, NSMenu.didBeginTrackingNotification) { $0.menuTracking = true; $0.reconcile() }
        observe(center, NSMenu.didEndTrackingNotification) { $0.menuTracking = false; $0.reconcile() }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observe(workspace, name) { $0.reconcile() }
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observe(workspace, name) { $0.sessionActive = false; $0.reconcile() }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observe(workspace, name) { $0.sessionActive = true; $0.reconcile() }
        }
        preferencesChanged()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping @MainActor (NotchHUDController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        observers.append((center, token))
    }

    private func preferencesChanged() {
        closeDetail()
        rebuildStrip()
        visibilityTimer?.invalidate()
        visibilityTimer = nil
        if preferences.enabled {
            // Geometry only. This is not an animation or data/network refresh timer.
            // Space notifications alone miss same-app video/full-screen transitions.
            visibilityTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcile() }
            }
            visibilityTimer?.tolerance = 0.2
        }
        reconcile()
    }

    private func rebuildStrip() {
        guard preferences.enabled else { strip?.orderOut(nil); return }
        let panel = strip ?? NotchHUDPanel(identifier: "tt.notch.strip")
        panel.hasShadow = false
        panel.contentView = NSHostingView(rootView: NotchHUDStripView(
            state: state, preferences: preferences,
            onHover: { [weak self] provider, inside in self?.hover(provider, inside: inside) },
            onClick: { [weak self] provider in self?.toggleDetail(provider) }).appLanguage())
        strip = panel
    }

    func reconcile() {
        guard preferences.enabled else { hide(); return }
        let candidate = NSScreen.screens.first { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(id.uint32Value) != 0 && screen.safeAreaInsets.top > 0
        }
        let frame = candidate.flatMap {
            NotchHUDLayout.stripFrame(leftArea: $0.auxiliaryTopLeftArea, screen: $0.frame,
                                      topInset: $0.safeAreaInsets.top, builtIn: true,
                                      count: preferences.providers.count)
        }
        let fullScreen = candidate.map(isFullScreen) ?? false
        let visible = NotchHUDVisibility.shouldShow(enabled: preferences.enabled, hasAnchor: frame != nil,
                                                   sessionActive: sessionActive && !menuTracking,
                                                   fullScreen: fullScreen)
        guard visible, let frame, let candidate else { hide(); return }
        anchorScreen = candidate
        if strip == nil { rebuildStrip() }
        if strip.map({ NotchHUDLayout.needsPlacement(current: $0.frame, target: frame) }) ?? true {
            closeDetail()
            strip?.setFrame(frame, display: true)
        }
        if strip?.isVisible != true { strip?.orderFrontRegardless() }
        if !lastVisible { debug("visible \(frame) presentation=\(NSApp.currentSystemPresentationOptions.rawValue)") }
        lastVisible = true
    }

    private func isFullScreen(_ screen: NSScreen) -> Bool {
        // The camera safe area can make a native full-screen window's bounds
        // identical to a maximized window. AppKit reports the active app's mode.
        if NSApp.currentSystemPresentationOptions.contains(.fullScreen) { return true }
        guard let primary = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else {
            return true // No Window Server session: do not show on login/transition screens.
        }
        let target = NotchHUDLayout.windowServerFrame(screen.frame, primaryTop: primary.frame.maxY)
        return windows.contains { window in
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let dictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary) else { return false }
            return NotchHUDLayout.coversDisplay(window: bounds, screen: target)
        }
    }

    private func hide() {
        strip?.orderOut(nil)
        closeDetail()
        anchorScreen = nil
        if lastVisible { debug("hidden") }
        lastVisible = false
    }

    private func hover(_ provider: String, inside: Bool) {
        hoverTask?.cancel()
        tooltip?.orderOut(nil)
        hovered = inside ? provider : nil
        guard inside, detail.provider == nil else { return }
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, self.hovered == provider,
                  self.detail.provider == nil, self.strip?.isVisible == true,
                  let strip = self.strip, let screen = self.anchorScreen else { return }
            let panel = self.tooltip ?? NotchHUDPanel(identifier: "tt.notch.tooltip")
            panel.ignoresMouseEvents = true
            panel.contentView = NSHostingView(rootView: NotchHUDTooltipView(
                state: self.state, preferences: self.preferences, provider: provider).appLanguage())
            panel.setFrame(NotchHUDLayout.cardFrame(strip: strip.frame, screen: screen.frame,
                                                   size: CGSize(width: 240, height: 62)), display: true)
            panel.orderFrontRegardless()
            self.tooltip = panel
            self.debug("tooltip \(provider)")
        }
    }

    func toggleDetail(_ provider: String) {
        onOpenQuota?()
        guard strip?.isVisible == true, let strip, let screen = anchorScreen else { return }
        if detail.provider == provider { closeDetail(); return }
        hoverTask?.cancel()
        tooltip?.orderOut(nil)
        detail.open(provider)
        openedAt = ProcessInfo.processInfo.systemUptime
        let panel = card ?? NotchHUDPanel(identifier: "tt.notch.detail")
        panel.title = L10n.text("刘海圆环")
        panel.contentView = NSHostingView(rootView: NotchHUDDetailView(
            state: state, model: detail, preferences: preferences, provider: provider,
            onClose: { [weak self] in self?.closeDetail() },
            onOpenMain: { [weak self] in self?.closeDetail(); self?.onOpenMain?() }).appLanguage())
        panel.setFrame(NotchHUDLayout.cardFrame(strip: strip.frame, screen: screen.frame,
                                               size: CGSize(width: 320, height: 380)), display: true)
        card = panel
        panel.orderFrontRegardless()
        // Expose the open card as the app's main accessibility window without
        // becoming key or activating the app. Typing stays in the original app.
        panel.makeMain()
        installDismissal()
        debug("detail \(provider) frontPID=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1) key=\(NSApp.keyWindow?.identifier?.rawValue ?? "none")")
    }

    func closeDetail(reason: String = #function) {
        hoverTask?.cancel()
        hovered = nil
        tooltip?.orderOut(nil)
        card?.orderOut(nil)
        if card?.isMainWindow == true { card?.resignMain() }
        if detail.provider != nil { debug("detail closed: \(reason)") }
        detail.close()
        for monitor in [localMouse, globalMouse, localKey].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
        localMouse = nil; globalMouse = nil; localKey = nil
        if let escapeKey { UnregisterEventHotKey(escapeKey); self.escapeKey = nil }
        if let escapeHandler { RemoveEventHandler(escapeHandler); self.escapeHandler = nil }
    }

    private func installDismissal() {
        guard localMouse == nil else { return }
        localMouse = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.dismissOutside(event); return event
        }
        globalMouse = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.dismissOutside(event)
        }
        localKey = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.closeDetail(); return nil }
            return event
        }
        // Register Escape only for the lifetime of the card. Unlike global key monitors,
        // Carbon hot keys do not need AX/Input Monitoring and do not change keyboard focus.
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                Unmanaged<NotchHUDController>.fromOpaque(context).takeUnretainedValue().closeDetail()
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &escapeHandler)
        if result == noErr {
            let id = EventHotKeyID(signature: 0x54544E48, id: 1)
            let status = RegisterEventHotKey(UInt32(kVK_Escape), 0, id, GetApplicationEventTarget(), 0, &escapeKey)
            if status != noErr { debug("Escape registration failed: \(status)") }
        }
    }

    private func dismissOutside(_ event: NSEvent) {
        // Global monitors are asynchronous; an earlier queued click must not
        // dismiss a just-opened card. Use the event position, not a later cursor.
        let point: NSPoint
        if let window = event.window {
            point = window.convertPoint(toScreen: event.locationInWindow)
        } else if let location = event.cgEvent?.location, let primary = NSScreen.screens.first {
            point = NSPoint(x: location.x, y: primary.frame.maxY - location.y)
        } else { return }
        guard NotchHUDInteraction.shouldDismissClick(point: point, timestamp: event.timestamp,
                                                     openedAt: openedAt, strip: strip?.frame,
                                                     card: card?.frame) else { return }
        debug("outside \(point) strip=\(String(describing: strip?.frame))")
        closeDetail()
    }

    func stop() {
        hide()
        visibilityTimer?.invalidate()
        visibilityTimer = nil
        subscriptions.removeAll()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    private func debug(_ message: String) {
        guard ProcessInfo.processInfo.environment["TT_DEBUG_NOTCH"] == "1" else { return }
        FileHandle.standardError.write(Data("[notch] \(message)\n".utf8))
    }
}

final class NotchHUDPanel: NSPanel {
    init(identifier: String) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isMovable = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { identifier?.rawValue == "tt.notch.detail" }
}
