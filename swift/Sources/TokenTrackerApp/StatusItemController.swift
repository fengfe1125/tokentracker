//
//  StatusItemController.swift
//  TokenTrackerApp
//
//  移植自 app/menubar.py：NSStatusItem 常驻（分段着色富文本标题 + AppKit
//  矢量配额圆 + 动画降级 + Tahoe 自愈）。格式化纯逻辑在
//  TokenTrackerCore.MenuBarFmt。
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
    private var todayItem: NSMenuItem?
    private var quotaItems: [NSMenuItem] = []
    private var displayItem: NSMenuItem?
    private static let maxQuotaLines = 4

    // 动画状态
    private var animTimer: Timer?
    private var flashStart: Date?
    private var scanStarted: Date?
    private var lastPlain: String?
    private var lastAnimKey: String?
    private var lastRingKey: String?

    // 自愈状态
    private var invisibleSince: Date?
    private var healLevel = 0
    private var lastHeal = Date.distantPast
    private var lastNudge = Date.distantPast

    var onOpenMain: (() -> Void)?
    var onOpenSettings: (() -> Void)?
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
        appState.settings["menubar_provider"] as? String ?? MenuBarFmt.defaultProvider
    }
    private var compact: Bool { (appState.settings["menubar_compact"] as? NSNumber)?.boolValue ?? false }
    private var ring: Bool { (appState.settings["menubar_ring"] as? NSNumber)?.boolValue ?? true }
    private var yi: Bool { (appState.settings["unit_yi"] as? NSNumber)?.boolValue ?? false }

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
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = ring ? "—" : "⚡ —"

        let menu = NSMenu()
        menu.delegate = self
        let today = NSMenuItem(title: "今日暂无数据", action: nil, keyEquivalent: "")
        today.isEnabled = false
        menu.addItem(today)
        todayItem = today
        for _ in 0..<Self.maxQuotaLines {
            let it = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            it.isEnabled = false
            it.isHidden = true
            menu.addItem(it)
            quotaItems.append(it)
        }
        menu.addItem(.separator())
        let display = NSMenuItem(title: "状态栏显示", action: nil, keyEquivalent: "")
        display.submenu = NSMenu()
        menu.addItem(display)
        displayItem = display
        menu.addItem(.separator())
        addAction(menu, title: "打开主面板", action: #selector(openMain))
        addAction(menu, title: "设置…", action: #selector(openSettings), key: ",")
        addAction(menu, title: "立即扫描", action: #selector(rescan))
        menu.addItem(.separator())
        addAction(menu, title: "退出 TokenTracker", action: #selector(quitApp), key: "q")
        item.menu = menu
        statusItem = item
        log("状态栏已安装")
        render()
    }

    private func addAction(_ menu: NSMenu, title: String, action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    // ------------------------------------------------------------ 标题渲染 ----

    /// 渲染状态栏标题。动画参数为 nil 时用静态值。
    /// macOS 26 Tahoe 缺陷：重复设置相同 attributedTitle 会导致图标消失，
    /// 因此只在内容或动画值变化时才写 button。
    func render(spin: Int? = nil, flash: Double? = nil, pulse: Double? = nil) {
        guard let button = statusItem?.button else { return }
        if appState.scanning {
            let frame = spin.map(MenuBarFmt.spinnerFrame) ?? "⟳"
            let plain = "\(frame) 扫描中…"
            let key = "\(plain)|\(spin ?? -1)"
            if key != lastAnimKey {
                lastAnimKey = key
                lastPlain = nil
                applyRing(button, pulse: nil)          // 扫描中收起圆环
                button.title = plain
                button.attributedTitle = attributed([MenuBarSegment(plain, "dim")])
            }
            return
        }
        let segs = MenuBarFmt.fmtSegments(today: appState.today, entries: appState.quotaEntries,
                                          provider: provider, compact: compact,
                                          yi: yi, ring: ring)
        let plain = segs.map(\.text).joined()
        // 圆环模式的标题里已无百分比段，脉冲只作用在圆上
        let textPulse = ring ? nil : pulse
        // 圆环模式：平台字母承担文字版的紧急度着色
        let glyphRole = ring
            ? MenuBarFmt.ringSpec(entries: appState.quotaEntries, provider: provider).role
            : nil
        var parts: [MenuBarSegment] = []
        for seg in segs {
            var role = seg.role
            if role == "glyph", let glyphRole { role = glyphRole }
            if role == "tokens", flash != nil { role = "__flash" }
            else if role == "quota_crit", textPulse != nil { role = "__pulse" }
            parts.append(MenuBarSegment(seg.text, role))
        }
        applyRing(button, pulse: pulse)
        let animKey = "\(plain)|f:\(flash.map { String(format: "%.2f", $0) } ?? "-")|p:\(textPulse.map { String(format: "%.2f", $0) } ?? "-")"
        if plain != lastPlain {
            lastPlain = plain
            // NSVariableStatusItemLength 只按纯文本测量宽度，两者必须同时设
            button.title = plain
        }
        if animKey != lastAnimKey {
            lastAnimKey = animKey
            button.attributedTitle = attributedCustom(parts, flash: flash, pulse: textPulse)
        }
        // 诊断：渲染结果落盘（排查 launchd 环境下的链条问题）
        if ProcessInfo.processInfo.environment["TT_DEBUG_TITLE"] == "1" {
            let debug = "title=\(plain) today=\(appState.today?.tokens ?? -1) "
                + "entries=\(appState.quotaEntries.count) scanning=\(appState.scanning)\n"
            if let h = FileHandle(forWritingAtPath: "/tmp/tt_swift_debug.log") {
                h.seekToEndOfFile(); h.write(Data(debug.utf8)); try? h.close()
            } else {
                FileManager.default.createFile(atPath: "/tmp/tt_swift_debug.log",
                                               contents: Data(debug.utf8))
            }
        }
    }

    /// 带自定义颜色（闪光混合/脉冲透明）的富文本。
    private func attributedCustom(_ segments: [MenuBarSegment],
                                  flash: Double?, pulse: Double?) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for seg in segments {
            var color = color(for: seg.role)
            if seg.role == "__flash", let flash {
                color = Self.accent.blended(withFraction: flash, of: .labelColor) ?? .labelColor
            } else if seg.role == "__pulse", let pulse {
                color = color.withAlphaComponent(pulse)
            }
            result.append(NSAttributedString(
                string: seg.text, attributes: [.foregroundColor: color]))
        }
        return result
    }

    // ------------------------------------------------------------ 配额圆 ----

    /// 状态栏配额圆：14pt 彩色扇形（填充角 = 百分比，颜色按紧急度）。
    private func ringImage(spec: (pct: Double?, role: String), alpha: Double) -> NSImage {
        let side = MenuBarFmt.ringPt
        let c = side / 2
        let r = c - 1.4
        let pct = spec.pct
        let baseColor = color(for: spec.role)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            var drawColor = baseColor
            if alpha < 1 { drawColor = baseColor.withAlphaComponent(alpha) }
            let rect = NSRect(x: c - r, y: c - r, width: r * 2, height: r * 2)
            guard let pct else {
                // 无数据：灰色空心圆
                drawColor.setStroke()
                let circle = NSBezierPath(ovalIn: rect)
                circle.lineWidth = 1.3
                circle.stroke()
                return true
            }
            // 未用完的部分：同色低透明轨道
            drawColor.withAlphaComponent(0.22 * alpha).setFill()
            NSBezierPath(ovalIn: rect).fill()
            let frac = max(0, min(1, pct / 100))
            if frac > 0 {
                drawColor.setFill()
                let pie = NSBezierPath()
                pie.move(to: NSPoint(x: c, y: c))
                // 12 点方向起、顺时针扫过 frac 圈
                pie.appendArc(withCenter: NSPoint(x: c, y: c), radius: r,
                              startAngle: 90, endAngle: 90 - 360 * frac, clockwise: true)
                pie.close()
                pie.fill()
            }
            return true
        }
        image.isTemplate = false   // 保留彩色，不被系统染成菜单栏单色
        return image
    }

    /// 把配额圆写到按钮（变化才重绘：按整数百分点 + 量化脉冲缓存）。
    private func applyRing(_ button: NSStatusBarButton, pulse: Double?) {
        if !ring || appState.scanning {
            if lastRingKey != nil || button.image != nil {
                lastRingKey = nil
                button.image = nil
            }
            return
        }
        let spec = MenuBarFmt.ringSpec(entries: appState.quotaEntries, provider: provider)
        let alpha = pulse ?? 1
        let key = "\(spec.pct.map { Int($0.rounded()) } ?? -1)|\(spec.role)|\(pulse.map { Int($0 * 100) } ?? -1)"
        if key == lastRingKey { return }
        lastRingKey = key
        button.image = ringImage(spec: spec, alpha: alpha)
        button.imagePosition = .imageLeft
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
        let path = NSHomeDirectory() + "/.tokentracker/app.log"
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"   // 与 Python time.strftime 本地时间一致
        let line = "\(fmt.string(from: Date())) \(message)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }

    /// 图标被系统隐藏 → 延迟后自愈（先强制重排，再销毁重建），失败退避。
    func checkVisibility() {
        guard let item = statusItem else { return }
        let visible = item.isVisible
        let now = Date()
        if visible {
            if invisibleSince != nil { log("状态栏图标恢复可见") }
            invisibleSince = nil
            healLevel = 0
            return
        }
        guard let since = invisibleSince else {
            invisibleSince = now
            log("状态栏图标不可见，观察中")
            return
        }
        guard now.timeIntervalSince(since) >= Self.healDelay,
              now.timeIntervalSince(lastHeal) >= Self.healBackoff else { return }
        lastHeal = now
        if healLevel == 0 {
            log("自愈：强制重排状态栏项")
            item.isVisible = false
            item.isVisible = true
            healLevel = 1
        } else {
            log("自愈：重建状态栏项")
            recreateStatusItem()
            healLevel = 0
        }
    }

    private func recreateStatusItem() {
        let old = statusItem
        statusItem = nil
        old?.isVisible = false
        install()
        lastPlain = nil
        lastAnimKey = nil
        lastRingKey = nil
        render()
    }

    /// 无条件重排轻推：刘海溢出导致的卡隐藏无法经 isVisible 探测（实测返回 true）。
    private func nudge() {
        guard let item = statusItem else { return }
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

    func menuNeedsUpdate(_ menu: NSMenu) {
        if let todayItem {
            todayItem.attributedTitle = attributed(
                MenuBarFmt.todayLineSegments(appState.today, yi: yi))
        }
        let entries = Array(appState.quotaEntries.prefix(Self.maxQuotaLines))
        for (index, item) in quotaItems.enumerated() {
            if index < entries.count {
                item.attributedTitle = attributed(MenuBarFmt.quotaLineSegments(entries[index]))
                item.isHidden = false
            } else {
                item.isHidden = true
            }
        }
        rebuildDisplayMenu()
    }

    private var titlePreview: String {
        let text = MenuBarFmt.fmtTitle(today: appState.today, entries: appState.quotaEntries,
                                       provider: provider, compact: compact, yi: yi, ring: ring)
        guard ring else { return text }
        let glyph = MenuBarFmt.ringGlyph(
            MenuBarFmt.ringSpec(entries: appState.quotaEntries, provider: provider))
        return "\(glyph)\(compact ? "" : " ")\(text)"
    }

    private func rebuildDisplayMenu() {
        let sub = NSMenu()
        let preview = NSMenuItem(title: "当前：" + titlePreview, action: nil, keyEquivalent: "")
        preview.isEnabled = false
        sub.addItem(preview)
        sub.addItem(.separator())
        for entry in appState.quotaEntries {
            addProviderItem(sub, pid: entry.id, title: "今日用量 + \(entry.name)",
                            dot: "dot_\(entry.id)")
        }
        if !appState.quotaEntries.isEmpty { sub.addItem(.separator()) }
        addProviderItem(sub, pid: "off", title: "仅今日用量", dot: "dot_off")
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
        log("菜单动作：打开主面板")
        onOpenMain?()
    }
    @objc private func openSettings(_: Any?) {
        log("菜单动作：设置")
        onOpenSettings?()
    }

    @objc private func rescan(_: Any?) {
        appState.requestScan()
    }

    @objc private func quitApp(_: Any?) { onQuit?() }

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
