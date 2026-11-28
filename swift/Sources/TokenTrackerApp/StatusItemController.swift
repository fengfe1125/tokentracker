//
//  StatusItemController.swift
//  TokenTrackerApp
//
//  移植自 app/menubar.py：NSStatusItem 常驻（分段着色富文本标题 + AppKit
//  矢量配额圆 + 动画降级 + Tahoe 自愈）。格式化纯逻辑在
//  TokenTrackerCore.MenuBarFmt。
//  左键弹出速览面板（MenuBarPanelView），右键 / Control 点击弹出文字菜单。
//

import AppKit
import Combine
import SwiftUI
import TokenTrackerCore

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private static let animInterval = 0.12
    private static let healDelay = 10.0      // 图标不可见多久后触发自愈
    private static let healBackoff = 30.0    // 自愈失败后的重试退避
    private static let nudgeInterval = 60.0  // 无条件重排轻推间隔
    private static let accent = NSColor(calibratedRed: Double(0xD9) / 255,
                                        green: Double(0x77) / 255,
                                        blue: Double(0x57) / 255, alpha: 1)

    private unowned let appState: AppState
    private var cancellables: [AnyCancellable] = []

    private var statusItem: NSStatusItem?
    /// 右键菜单。不挂在 statusItem.menu 上：挂上后左键也会弹菜单，面板就出不来。
    private var menu: NSMenu?
    private var popover: NSPopover?
    private var todayItem: NSMenuItem?
    private var riskItem: NSMenuItem?
    private var quotaItems: [NSMenuItem] = []
    private var displayItem: NSMenuItem?
    private var notchItem: NSMenuItem?
    private static let maxQuotaLines = 5

    // 动画状态
    private var animTimer: Timer?
    private var flashStart: Date?
    private var scanStarted: Date?
    private var lastRenderKey: String?
    private var appearanceObservation: NSKeyValueObservation?

    // 自愈状态
    private var invisibleSince: Date?
    private var healLevel = 0
    private var lastHeal = Date.distantPast
    private var lastNudge = Date.distantPast

    var onOpenMain: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenTasks: (() -> Void)?
    var onOpenSession: ((String, String) -> Void)?
    var onOpenAccounts: (() -> Void)?
    var onQuit: (() -> Void)?

    init(appState: AppState) {
        self.appState = appState
        super.init()
        appState.$today
            .combineLatest(appState.$quotaEntries, appState.$scanning, appState.$settings)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _, _ in self?.render() }
            .store(in: &cancellables)
        appState.onTokensChanged = { [weak self] in self?.flashStart = Date() }
    }

    // ------------------------------------------------------------ 偏好 ----

    private var provider: String {
        appState.prefs.menubarProvider
    }
    private var compact: Bool { appState.prefs.menubarCompact }
    private var style: MenuBarStyle { appState.prefs.menubarStyle }
    private var yi: Bool { appState.prefs.unitYi }

    private var currentDisplay: MenuBarDisplay {
        MenuBarFmt.display(today: appState.today, entries: appState.quotaEntries,
                           provider: provider, yi: yi && !L10n.isEnglish)
    }

    static var labels: MenuBarLabels {
        MenuBarLabels(today: L10n.text("今日 Token"), scanning: L10n.text("扫描中…"))
    }

    /// 读屏与菜单「当前：」预览用的纯文本描述。
    static func describe(_ display: MenuBarDisplay) -> String {
        let tokens = display.hasTokens ? L10n.text("今日 \(display.tokensText) Token") : L10n.text("今日暂无数据")
        guard let quota = display.quota else { return tokens }
        guard let pct = quota.pct else { return tokens + " · " + L10n.text("\(quota.name) 暂无配额数据") }
        return tokens + " · " + L10n.text("\(quota.name) 已用 \(String(format: "%.0f%%", pct))")
    }

    // ------------------------------------------------------------ 颜色 ----

    private func color(for role: String) -> NSColor {
        switch role {
        case "bolt", "tokens": return Self.accent
        case "ink": return .labelColor
        case "dim", "glyph", "cost": return .secondaryLabelColor
        case "marker": return .tertiaryLabelColor
        case "quota_ok": return .systemGreen
        case "quota_warn": return .systemOrange
        case "quota_crit": return .systemRed
        case "quota_none": return .tertiaryLabelColor
        default:
            if role.hasPrefix("dot_"),
               let hex = MenuBarFmt.toolHex[String(role.dropFirst(4))] {
                let (r, g, b) = MenuBarFmt.hexRGB(hex)
                return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
            }
            if role.hasPrefix("dot_") { return .tertiaryLabelColor }
            return .labelColor
        }
    }

    private func attributed(_ segments: [MenuBarSegment]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for seg in segments {
            result.append(NSAttributedString(
                string: seg.text,
                attributes: [.foregroundColor: color(for: seg.role)]))
        }
        return result
    }

    // ------------------------------------------------------------ 安装 ----

    func install() {
        guard statusItem == nil else { return }
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Do not assign an autosave name here. macOS restores named status items
        // from Control Center's persisted position, and a stale record can place
        // this variable-width item outside the visible menu bar permanently.
        // An anonymous item is laid out against the current screen on every run.
        item.isVisible = true
        item.button?.title = ""
        item.button?.imagePosition = .imageOnly
        // 菜单栏随壁纸切换深浅色时，彩色图片要按新外观重画
        appearanceObservation = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.render() }
            }
        }

        let menu = NSMenu()
        menu.delegate = self
        let today = NSMenuItem(title: L10n.text("今日暂无数据"), action: nil, keyEquivalent: "")
        today.isEnabled = false
        menu.addItem(today)
        todayItem = today
        let risk = NSMenuItem(title:"",action:nil,keyEquivalent:"")
        risk.isEnabled=false;menu.addItem(risk);riskItem=risk
        for _ in 0..<Self.maxQuotaLines {
            let it = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            it.isEnabled = false
            it.isHidden = true
            menu.addItem(it)
            quotaItems.append(it)
        }
        menu.addItem(.separator())
        let display = NSMenuItem(title: L10n.text("状态栏显示"), action: nil, keyEquivalent: "")
        display.submenu = NSMenu()
        menu.addItem(display)
        displayItem = display
        let notch = NSMenuItem(title: "", action: #selector(toggleNotchHUD), keyEquivalent: "")
        notch.target = self
        menu.addItem(notch)
        notchItem = notch
        addAction(menu, title: L10n.text("任务提醒"), action: #selector(openTasks))
        menu.addItem(.separator())
        addAction(menu, title: L10n.text("打开主面板"), action: #selector(openMain))
        addAction(menu, title: L10n.text("设置…"), action: #selector(openSettings), key: ",")
        addAction(menu, title: L10n.text("立即扫描"), action: #selector(rescan))
        menu.addItem(.separator())
        addAction(menu, title: L10n.text("退出 TokenTracker"), action: #selector(quitApp), key: "q")
        self.menu = menu
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        log(L10n.text("状态栏已安装"))
        render()
        // 首轮 run loop 后再确认一次，避免启动阶段的布局恢复覆盖首次渲染。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.statusItem === item else { return }
            item.isVisible = true
            self.render()
        }
    }

    private func addAction(_ menu: NSMenu, title: String, action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }
    @objc private func openTasks() { onOpenTasks?() }

    // ------------------------------------------------------------ 点击 ----

    private func debug(_ message: String) {
        guard ProcessInfo.processInfo.environment["TT_DEBUG_TITLE"] == "1" else { return }
        FileHandle.standardError.write(Data("[tt] \(message)\n".utf8))
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        debug("status item clicked: type=\(event?.type.rawValue ?? 0) panelShown=\(panelShown)")
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePanel()
        }
    }

    /// 右键菜单：临时挂上菜单再点一次按钮，弹完立刻摘掉，左键才不会被菜单接管。
    private func showMenu() {
        closePanel()
        guard let item = statusItem, let menu else { return }
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    var panelShown: Bool { popover?.isShown == true }

    func closePanel() { popover?.performClose(nil) }

    private func togglePanel() {
        if panelShown { closePanel() } else { showPanel() }
    }

    func showPanel() {
        guard !panelShown else { return }
        guard let button = statusItem?.button else { return }
        let actions = MenuBarPanelActions(
            openMain: { [weak self] in self?.closePanel(); self?.onOpenMain?() },
            openSession: { [weak self] tool, session in self?.closePanel(); self?.onOpenSession?(tool, session) },
            openAccounts: { [weak self] in self?.closePanel(); self?.onOpenAccounts?() },
            openSettings: { [weak self] in self?.closePanel(); self?.onOpenSettings?() },
            openPorts: { [weak self] in
                guard let self else { return }
                self.closePanel()
                self.appState.selection = .ports
                self.onOpenMain?()
            },
            openPort: { [weak self] port in
                guard let self else { return }
                self.closePanel()
                self.appState.ports.revealPort(port)
                self.appState.selection = .ports
                self.onOpenMain?()
            },
            openTasks: { [weak self] in self?.closePanel(); self?.onOpenTasks?() },
            quit: { [weak self] in self?.onQuit?() })
        let hosting = NSHostingController(
            rootView: MenuBarPanelView(state: appState, actions: actions).appLanguage())
        hosting.sizingOptions = [.preferredContentSize]   // 面板高度跟随内容
        let popover = NSPopover()
        popover.behavior = .transient                     // 点面板外即关闭
        popover.contentViewController = hosting
        self.popover = popover
        // 无 Dock 图标的应用要先激活，面板才能拿到键盘焦点、外部点击才会触发关闭
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        debug("panel shown=\(popover.isShown) button=\(button.window?.frame ?? .zero) size=\(hosting.preferredContentSize)")
    }

    // ------------------------------------------------------------ 标题渲染 ----

    /// 渲染状态栏标题（整段一张图，样式见 MenuBarStyleRenderer）。动画参数为 nil 时用静态值。
    /// macOS 26 Tahoe 缺陷：重复设置相同内容会导致图标消失，因此只在缓存键变化时才写 button。
    func render(spin: Int? = nil, flash: Double? = nil, pulse: Double? = nil) {
        guard let button = statusItem?.button else { return }
        let display = currentDisplay
        let anim = MenuBarAnimation(scanning: appState.scanning && !display.tokensOnly,
                                    spin: spin ?? 0, flash: flash, pulse: pulse)
        let labels = Self.labels
        let appearance = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])?.rawValue ?? ""
        let key = MenuBarStyleRenderer.cacheKey(display: display, style: style, compact: compact,
                                                anim: anim, labels: labels) + "|" + appearance
        guard key != lastRenderKey else { return }
        lastRenderKey = key
        if !button.title.isEmpty { button.title = "" }
        button.image = MenuBarStyleRenderer.image(display: display, style: style, compact: compact,
                                                  anim: anim, labels: labels)
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel(Self.describe(display))
        // 诊断：渲染结果落盘（排查 launchd 环境下的链条问题）
        if ProcessInfo.processInfo.environment["TT_DEBUG_TITLE"] == "1" {
            let debug = "style=\(style.rawValue) title=\(Self.describe(display)) today=\(appState.today?.tokens ?? -1) "
                + "entries=\(appState.quotaEntries.count) scanning=\(appState.scanning)\n"
            if let h = FileHandle(forWritingAtPath: "/tmp/tt_swift_debug.log") {
                h.seekToEndOfFile(); h.write(Data(debug.utf8)); try? h.close()
            } else {
                FileManager.default.createFile(atPath: "/tmp/tt_swift_debug.log",
                                               contents: Data(debug.utf8))
            }
        }
    }

    // ------------------------------------------------------------ 动画 ----

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var pulseActive: Bool {
        guard let best = MenuBarFmt.bestWindow(
            appState.quotaEntries.first { $0.id == provider }) else { return false }
        return (best.pct ?? 0) >= MenuBarFmt.critPct
    }

    /// 闪光进度 0..1；已结束返回 nil 并清状态。
    private var flashProgress: Double? {
        guard let flashStart else { return nil }
        let elapsed = Date().timeIntervalSince(flashStart)
        if elapsed >= MenuBarFmt.flashDur {
            self.flashStart = nil
            return nil
        }
        return MenuBarFmt.flashAlpha(elapsed)
    }

    /// 按需启停动画计时器（空闲零开销）。
    func syncAnim() {
        if statusItem == nil || reduceMotion {
            stopAnim()
            return
        }
        let want = appState.scanning || flashStart != nil || pulseActive
        if want && animTimer == nil {
            animTimer = Timer.scheduledTimer(withTimeInterval: Self.animInterval,
                                             repeats: true) { _ in
                // Timer 在主 runloop 上触发（调度时处于主线程）
                MainActor.assumeIsolated { [weak self] in self?.animTick() }
            }
        } else if !want {
            stopAnim()
        }
    }

    private func stopAnim() {
        animTimer?.invalidate()
        animTimer = nil
    }

    private func animTick() {
        var spin: Int?
        if appState.scanning {
            let origin = scanStarted ?? Date()
            spin = Int(Date().timeIntervalSince(origin) / Self.animInterval)
        }
        let flash = flashProgress
        let pulse = pulseActive ? MenuBarFmt.pulseAlpha(Date().timeIntervalSince1970) : nil
        if !(appState.scanning || flash != nil || pulse != nil) {
            stopAnim()
        }
        render(spin: spin, flash: flash, pulse: pulse)
    }

    // ------------------------------------------------------------ 自愈 ----

    private func log(_ message: String) {
        AppLog.write(message)
    }

    /// 图标被系统隐藏 → 延迟后自愈（先强制重排，再销毁重建），失败退避。
    func checkVisibility() {
        guard let item = statusItem else { return }
        let visible = item.isVisible
        let now = Date()
        if visible {
            if invisibleSince != nil { log(L10n.text("状态栏图标恢复可见")) }
            invisibleSince = nil
            healLevel = 0
            return
        }
        guard let since = invisibleSince else {
            invisibleSince = now
            log(L10n.text("状态栏图标不可见，观察中"))
            return
        }
        guard now.timeIntervalSince(since) >= Self.healDelay,
              now.timeIntervalSince(lastHeal) >= Self.healBackoff else { return }
        lastHeal = now
        if healLevel == 0 {
            log(L10n.text("自愈：强制重排状态栏项"))
            item.isVisible = false
            item.isVisible = true
            healLevel = 1
        } else {
            log(L10n.text("自愈：重建状态栏项"))
            recreateStatusItem()
            healLevel = 0
        }
    }

    private func recreateStatusItem() {
        closePanel()
        let old = statusItem
        statusItem = nil
        if let old { NSStatusBar.system.removeStatusItem(old) }
        appearanceObservation = nil
        lastRenderKey = nil
        install()
        render()
    }

    /// 无条件重排轻推：刘海溢出导致的卡隐藏无法经 isVisible 探测（实测返回 true）。
    private func nudge() {
        // 面板锚在按钮上，开着的时候不重排，避免面板被带走
        guard let item = statusItem, !panelShown else { return }
        item.isVisible = false
        item.isVisible = true
    }

    /// 每 5s 一件事：渲染 / 动画启停 / 自愈检查 / 周期轻推。
    func tickMain() {
        if animTimer == nil { render() }   // 动画运行中由计时器负责渲染
        syncAnim()
        checkVisibility()
        if Date().timeIntervalSince(lastNudge) >= Self.nudgeInterval {
            lastNudge = Date()
            nudge()
        }
    }

    // ------------------------------------------------------------ 菜单 ----

    func languageDidChange() {
        guard let menu else { return }
        displayItem?.title = L10n.text("状态栏显示")
        for item in menu.items {
            switch item.action {
            case #selector(openMain): item.title = L10n.text("打开主面板")
            case #selector(openSettings): item.title = L10n.text("设置…")
            case #selector(openTasks): item.title = L10n.text("任务提醒")
            case #selector(rescan): item.title = L10n.text("立即扫描")
            case #selector(quitApp): item.title = L10n.text("退出 TokenTracker")
            default: break
            }
        }
        menuNeedsUpdate(menu)
        render()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        notchItem?.title = L10n.text(NotchHUDPreferences.shared.enabled ? "隐藏刘海圆环" : "显示刘海圆环")
        let risks = appState.insights.risks.filter { $0.level > 0 }
        riskItem?.title = risks.isEmpty ? "" : L10n.text("⚠︎ \(risks.count) 项预算 / 配额风险，打开项目查看")
        riskItem?.isHidden = risks.isEmpty
        if let todayItem {
            todayItem.attributedTitle = attributed(
                MenuBarFmt.todayLineSegments(appState.today, yi: (yi && !L10n.isEnglish)).map { MenuBarSegment(L10n.label($0.text), $0.role) })
        }
        let entries = Array(appState.quotaEntries.prefix(Self.maxQuotaLines))
        for (index, item) in quotaItems.enumerated() {
            if index < entries.count {
                item.attributedTitle = attributed(MenuBarFmt.quotaLineSegments(UIFormat.quotaEntry(entries[index])))
                item.isHidden = false
            } else {
                item.isHidden = true
            }
        }
        rebuildDisplayMenu()
    }

    private func rebuildDisplayMenu() {
        let sub = NSMenu()
        let preview = NSMenuItem(title: L10n.text("当前：") + Self.describe(currentDisplay),
                                 action: nil, keyEquivalent: "")
        preview.isEnabled = false
        sub.addItem(preview)
        sub.addItem(.separator())
        let styleHeader = NSMenuItem(title: L10n.text("样式"), action: nil, keyEquivalent: "")
        styleHeader.isEnabled = false
        sub.addItem(styleHeader)
        for option in MenuBarStyle.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(pickStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == style ? .on : .off
            item.indentationLevel = 1
            item.image = MenuBarStyleRenderer.image(
                display: MenuBarStylePreview.sample(provider: provider, entries: appState.quotaEntries,
                                                    yi: yi && !L10n.isEnglish),
                style: option, compact: false, anim: MenuBarAnimation(), labels: Self.labels)
            sub.addItem(item)
        }
        sub.addItem(.separator())
        for entry in appState.quotaEntries {
            addProviderItem(sub, pid: entry.id, title: L10n.text("今日用量 + \(entry.name)"),
                            dot: "dot_\(entry.id)")
        }
        if !appState.quotaEntries.isEmpty { sub.addItem(.separator()) }
        addProviderItem(sub, pid: "off", title: L10n.text("仅今日用量"), dot: "dot_off")
        addProviderItem(sub, pid: "tokens", title: L10n.text("仅显示 Token 数字"), dot: nil)
        displayItem?.submenu = sub
    }

    private func addProviderItem(_ menu: NSMenu, pid: String, title: String, dot: String?) {
        let item = NSMenuItem(title: title, action: #selector(pickProvider(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = pid
        item.state = pid == provider ? .on : .off
        if let dot { item.image = dotImage(dot) }
        menu.addItem(item)
    }

    private func dotImage(_ role: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12))
        image.lockFocus()
        color(for: role).set()
        NSBezierPath(ovalIn: NSRect(x: 2.5, y: 2.5, width: 7, height: 7)).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    // ------------------------------------------------------------ 动作 ----

    @objc private func openMain(_: Any?) {
        log(L10n.text("菜单动作：打开主面板"))
        onOpenMain?()
    }
    @objc private func openSettings(_: Any?) {
        log(L10n.text("菜单动作：设置"))
        onOpenSettings?()
    }

    @objc private func rescan(_: Any?) {
        appState.requestScan()
    }

    @objc private func quitApp(_: Any?) { onQuit?() }

    @objc private func toggleNotchHUD(_: Any?) {
        NotchHUDPreferences.shared.enabled.toggle()
    }

    @objc private func pickStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, raw != style.rawValue else { return }
        appState.updateSetting(key: "menubar_style", value: raw)
        render()
    }

    @objc private func pickProvider(_ sender: NSMenuItem) {
        guard let pid = sender.representedObject as? String, pid != provider else { return }
        appState.updateSetting(key: "menubar_provider", value: pid)
        render()
    }

    /// 扫描状态变化时记住起点（旋转指示计帧）。
    func noteScanningStarted() {
        scanStarted = Date()
    }
}
