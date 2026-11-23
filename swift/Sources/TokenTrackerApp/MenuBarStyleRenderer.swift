//
//  MenuBarStyleRenderer.swift
//  TokenTrackerApp
//
//  把 MenuBarDisplay 按 MenuBarStyle 画成一张状态栏图片（A 原生单色 / B 双行仪表 /
//  C 配额胶囊）。整段标题都是一张矢量图：布局与宽度在外面算好，颜色在绘制时按当前
//  外观解析。无需彩色时输出 template 图，交给系统按菜单栏外观着色。
//  设置页与右键菜单的样式预览复用同一个渲染器，预览与实际效果一致。
//

import AppKit
import TokenTrackerCore

/// 动画状态（由 StatusItemController 的计时器驱动）。
struct MenuBarAnimation: Equatable {
    var scanning = false
    /// 扫描中帧序号（0.12s 一帧）
    var spin = 0
    /// 数值刷新闪光：0 = 品牌橙，1 = 回到前景色；nil = 不闪
    var flash: Double?
    /// 配额临界呼吸透明度；nil = 不呼吸
    var pulse: Double?
}

/// 渲染器用到的界面文案（调用方负责本地化）。
struct MenuBarLabels: Equatable {
    /// B 样式「仅今日用量」时的下行文字
    var today: String
    /// B 样式扫描中的下行文字
    var scanning: String
}

enum MenuBarStyleRenderer {
    static let height: CGFloat = 22
    static let accent = NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)

    /// 缓存键：内容、样式与量化后的动画值都相同就不重绘（Tahoe 重复赋值会丢图标）。
    static func cacheKey(display: MenuBarDisplay, style: MenuBarStyle, compact: Bool,
                         anim: MenuBarAnimation, labels: MenuBarLabels) -> String {
        let flash = anim.flash.map { String(format: "%.2f", $0) } ?? "-"
        let pulse = anim.pulse.map { String(format: "%.2f", $0) } ?? "-"
        let spin = anim.scanning ? String(anim.spin % 48) : "-"
        return "\(style.rawValue)|\(compact)|\(display)|\(labels)|s:\(spin)|f:\(flash)|p:\(pulse)"
    }

    /// 是否必须用彩色图（否则输出 template 图，由系统着色）。
    static func needsColor(display: MenuBarDisplay, style: MenuBarStyle, anim: MenuBarAnimation) -> Bool {
        if anim.flash != nil { return true }
        guard let quota = display.quota, !display.tokensOnly else { return false }
        switch style {
        case .capsule: return true
        case .native, .stacked: return quota.urgency == .warn || quota.urgency == .crit
        }
    }

    /// 生成状态栏图片。appearance 非空时强制按该外观解析颜色、scale 放大绘制（设置页预览用）。
    static func image(display: MenuBarDisplay, style: MenuBarStyle, compact: Bool,
                      anim: MenuBarAnimation, labels: MenuBarLabels,
                      appearance: NSAppearance? = nil, scale: CGFloat = 1) -> NSImage {
        let template = appearance == nil && !needsColor(display: display, style: style, anim: anim)
        let layout = Layout.make(display: display, style: style, compact: compact,
                                 anim: anim, labels: labels)
        let size = NSSize(width: layout.width * scale, height: height * scale)
        let image = NSImage(size: size, flipped: true) { _ in
            let draw = {
                if scale != 1 {
                    let transform = NSAffineTransform()
                    transform.scale(by: scale)
                    transform.concat()
                }
                layout.draw(Palette(template: template), anim)
            }
            if let appearance {
                appearance.performAsCurrentDrawingAppearance(draw)
            } else {
                draw()
            }
            return true
        }
        image.isTemplate = template
        return image
    }
}

// ------------------------------------------------------------ 调色 ----

private struct Palette {
    let template: Bool

    var ink: NSColor { template ? .black : .labelColor }
    var dim: NSColor { template ? NSColor.black.withAlphaComponent(0.55) : .secondaryLabelColor }
    var track: NSColor { ink.withAlphaComponent(0.24) }
    var faint: NSColor { ink.withAlphaComponent(0.13) }

    func urgency(_ urgency: MenuBarDisplay.Urgency) -> NSColor {
        switch urgency {
        case .warn: return .systemOrange
        case .crit: return .systemRed
        case .ok, .none: return ink
        }
    }

    /// 胶囊底色填充：常态低透明前景色，预警/临界换成橙/红。
    func fill(_ urgency: MenuBarDisplay.Urgency) -> NSColor {
        switch urgency {
        case .warn: return NSColor.systemOrange.withAlphaComponent(0.38)
        case .crit: return NSColor.systemRed.withAlphaComponent(0.42)
        case .ok, .none: return faint
        }
    }

    /// 今日 Token 数字颜色：常态前景色，刷新时由品牌橙回落。
    func number(_ display: MenuBarDisplay, flash: Double?) -> NSColor {
        guard display.hasTokens else { return dim }
        guard let flash else { return ink }
        return MenuBarStyleRenderer.accent.blended(withFraction: flash, of: ink) ?? ink
    }
}

// ------------------------------------------------------------ 排版 ----

private struct Layout {
    let width: CGFloat
    let draw: (Palette, MenuBarAnimation) -> Void

    static let height = MenuBarStyleRenderer.height
    static var numberFont: NSFont {
        let size = NSFont.menuBarFont(ofSize: 0).pointSize
        return .monospacedDigitSystemFont(ofSize: size > 0 ? size : 13, weight: .regular)
    }

    static func make(display: MenuBarDisplay, style: MenuBarStyle, compact: Bool,
                     anim: MenuBarAnimation, labels: MenuBarLabels) -> Layout {
        if display.tokensOnly { return number(display) }
        switch style {
        case .native: return native(display, compact: compact)
        case .stacked: return stacked(display, compact: compact, anim: anim, labels: labels)
        case .capsule: return display.quota == nil ? number(display) : capsule(display, compact: compact, anim: anim)
        }
    }

    // ------------------------------------------------ 仅数字 ----

    static func number(_ display: MenuBarDisplay) -> Layout {
        let font = numberFont
        let width = ceil(textWidth(display.tokensText, font))
        return Layout(width: width) { palette, anim in
            drawText(display.tokensText, font: font, color: palette.number(display, flash: anim.flash),
                     x: 0, baseline: centeredBaseline(font))
        }
    }

    // ------------------------------------------------ A 原生单色 ----

    static func native(_ display: MenuBarDisplay, compact: Bool) -> Layout {
        let font = numberFont
        let gap: CGFloat = compact ? 3 : 5
        let iconW: CGFloat = display.quota == nil ? 10 : 16
        let textX = iconW + gap
        let width = ceil(textX + textWidth(display.tokensText, font))
        return Layout(width: width) { palette, anim in
            if let quota = display.quota {
                drawRing(quota, palette: palette, anim: anim)
            } else {
                drawBolt(palette.ink)
            }
            drawText(display.tokensText, font: font, color: palette.number(display, flash: anim.flash),
                     x: textX, baseline: centeredBaseline(font))
        }
    }

    /// 16pt 进度环：12 点方向起顺时针，环心是平台字母。
    static func drawRing(_ quota: MenuBarDisplay.Quota, palette: Palette, anim: MenuBarAnimation) {
        let center = NSPoint(x: 8, y: height / 2)
        let radius: CGFloat = 6.6
        let lineWidth: CGFloat = 1.5
        let noData = quota.pct == nil && !anim.scanning

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        if noData { track.setLineDash([2, 2.1], count: 2, phase: 0) }
        palette.track.setStroke()
        track.stroke()

        let arc = NSBezierPath()
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        var color = palette.urgency(quota.urgency)
        if anim.scanning {
            // 翻转坐标系里角度递增 = 屏幕上顺时针
            let start = -90 + CGFloat(anim.spin % 12) * 30
            arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: start + 100)
            color = palette.ink
        } else if let pct = quota.pct, pct > 0 {
            let end = -90 + 360 * CGFloat(min(pct, 100) / 100)
            arc.appendArc(withCenter: center, radius: radius, startAngle: -90, endAngle: end)
            if quota.urgency == .crit, let pulse = anim.pulse { color = color.withAlphaComponent(pulse) }
        }
        if !arc.isEmpty {
            color.setStroke()
            arc.stroke()
        }

        let glyphFont = roundedFont(8, weight: .bold)
        let glyphW = textWidth(quota.glyph, glyphFont)
        drawText(quota.glyph, font: glyphFont, color: noData ? palette.dim : palette.ink,
                 x: center.x - glyphW / 2, baseline: center.y + glyphFont.capHeight / 2)
    }

    /// 仅今日用量时的闪电图标（描边）。
    static func drawBolt(_ color: NSColor) {
        let oy = (height - 14) / 2
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 6.2, y: oy + 0.6))
        path.line(to: NSPoint(x: 1.0, y: oy + 7.8))
        path.line(to: NSPoint(x: 4.8, y: oy + 7.8))
        path.line(to: NSPoint(x: 4.0, y: oy + 13.4))
        path.line(to: NSPoint(x: 9.2, y: oy + 6.0))
        path.line(to: NSPoint(x: 5.5, y: oy + 6.0))
        path.close()
        path.lineWidth = 1.2
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    // ------------------------------------------------ B 双行仪表 ----

    static func stacked(_ display: MenuBarDisplay, compact: Bool, anim: MenuBarAnimation,
                        labels: MenuBarLabels) -> Layout {
        let topFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let bottomFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium)
        let bottomBold = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .bold)
        let quota = display.quota

        // 下行：平台名 + 百分比；扫描中 / 仅今日用量换成提示文字
        let name: String
        let pctText: String
        if quota == nil {
            name = labels.today; pctText = ""
        } else if anim.scanning {
            name = labels.scanning; pctText = ""
        } else if let quota {
            name = quota.name + " "
            pctText = quota.pct.map { (quota.approximate ? "≈" : "") + String(format: "%.0f%%", $0) } ?? "—"
        } else {
            name = ""; pctText = ""
        }
        let alert = quota.map { $0.urgency == .warn || $0.urgency == .crit } ?? false
        let pctFont = alert ? bottomBold : bottomFont
        let nameW = textWidth(name, bottomFont)
        let bottomW = nameW + textWidth(pctText, pctFont)
        let textW = max(textWidth(display.tokensText, topFont), bottomW)
        let gap: CGFloat = compact ? 3 : 5
        let barW: CGFloat = 3.5
        let width = ceil(textW + (quota == nil ? 0 : gap + barW))

        return Layout(width: width) { palette, anim in
            drawText(display.tokensText, font: topFont, color: palette.number(display, flash: anim.flash),
                     x: 0, baseline: 10)
            drawText(name, font: bottomFont, color: palette.dim, x: 0, baseline: 19.5)
            if let quota, !pctText.isEmpty {
                let color = alert ? palette.urgency(quota.urgency) : palette.dim
                drawText(pctText, font: pctFont, color: color, x: nameW, baseline: 19.5)
            }
            guard let quota else { return }
            let bar = NSRect(x: textW + gap, y: 3, width: barW, height: 16)
            palette.track.setFill()
            NSBezierPath(roundedRect: bar, xRadius: barW / 2, yRadius: barW / 2).fill()
            var fill: NSRect
            var color = palette.urgency(quota.urgency)
            if anim.scanning {
                // 来回滑动的不定进度块
                let phase = CGFloat(anim.spin % 16) / 8
                let tri = phase <= 1 ? phase : 2 - phase
                let h = bar.height * 0.4
                fill = NSRect(x: bar.minX, y: bar.maxY - h - (bar.height - h) * tri, width: barW, height: h)
                color = palette.dim
            } else {
                let h = bar.height * CGFloat(min(quota.pct ?? 0, 100) / 100)
                fill = NSRect(x: bar.minX, y: bar.maxY - h, width: barW, height: h)
                if quota.urgency == .crit, let pulse = anim.pulse { color = color.withAlphaComponent(pulse) }
            }
            guard fill.height > 0 else { return }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: bar, xRadius: barW / 2, yRadius: barW / 2).addClip()
            color.setFill()
            fill.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // ------------------------------------------------ C 配额胶囊 ----

    static func capsule(_ display: MenuBarDisplay, compact: Bool, anim: MenuBarAnimation) -> Layout {
        guard let quota = display.quota else { return number(display) }
        let font = numberFont
        let pctFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let pctText: String = anim.scanning
            ? "···"
            : quota.pct.map { (quota.approximate ? "≈" : "") + String(format: "%.0f%%", $0) } ?? "—"
        let numW = textWidth(display.tokensText, font)
        let gap: CGFloat = compact ? 4 : 6
        let avatar: CGFloat = 12
        let pillH: CGFloat = 17
        let pillW = ceil(2.5 + avatar + 3.5 + textWidth(pctText, pctFont) + 6)
        let pillX = ceil(numW + gap)
        let width = pillX + pillW

        return Layout(width: width) { palette, anim in
            drawText(display.tokensText, font: font, color: palette.number(display, flash: anim.flash),
                     x: 0, baseline: centeredBaseline(font))

            let pill = NSRect(x: pillX, y: (height - pillH) / 2, width: pillW, height: pillH)
            let shape = NSBezierPath(roundedRect: pill, xRadius: pillH / 2, yRadius: pillH / 2)
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            if anim.scanning {
                // 扫光：一段半透明亮带从左向右滑过
                let band = pill.width * 0.45
                let phase = CGFloat(anim.spin % 12) / 12
                palette.faint.setFill()
                NSRect(x: pill.minX - band + (pill.width + band) * phase, y: pill.minY,
                       width: band, height: pill.height).fill()
            } else if let pct = quota.pct, pct > 0 {
                var color = palette.fill(quota.urgency)
                if quota.urgency == .crit, let pulse = anim.pulse {
                    color = color.withAlphaComponent(color.alphaComponent * pulse)
                }
                color.setFill()
                NSRect(x: pill.minX, y: pill.minY, width: pill.width * CGFloat(min(pct, 100) / 100),
                       height: pill.height).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            let border = NSBezierPath(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5),
                                      xRadius: (pillH - 1) / 2, yRadius: (pillH - 1) / 2)
            border.lineWidth = 1
            palette.track.setStroke()
            border.stroke()

            // 品牌色头像
            let disc = NSRect(x: pill.minX + 2.5, y: pill.midY - avatar / 2, width: avatar, height: avatar)
            brandColor(quota.brandHex).setFill()
            NSBezierPath(ovalIn: disc).fill()
            let glyphFont = roundedFont(7.5, weight: .heavy)
            let glyphW = textWidth(quota.glyph, glyphFont)
            drawText(quota.glyph, font: glyphFont, color: .white,
                     x: disc.midX - glyphW / 2, baseline: disc.midY + glyphFont.capHeight / 2)

            let pctColor: NSColor
            if anim.scanning || quota.pct == nil { pctColor = palette.dim }
            else if quota.urgency == .crit { pctColor = .systemRed }
            else { pctColor = palette.ink }
            drawText(pctText, font: pctFont, color: pctColor,
                     x: disc.maxX + 3.5, baseline: pill.midY + pctFont.capHeight / 2)
        }
    }

    // ------------------------------------------------ 工具 ----

    static func roundedFont(_ size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    static func brandColor(_ hex: String?) -> NSColor {
        guard let hex else { return .systemGray }
        let (r, g, b) = MenuBarFmt.hexRGB(hex)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    /// 让大写字母/数字在 22pt 高度内垂直居中的基线位置（翻转坐标）。
    static func centeredBaseline(_ font: NSFont) -> CGFloat {
        ((height + font.capHeight) / 2).rounded()
    }

    static func textWidth(_ text: String, _ font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return NSAttributedString(string: text, attributes: [.font: font]).size().width
    }

    /// 以基线定位绘制单行文字（不受中文回退字体行高影响）。
    static func drawText(_ text: String, font: NSFont, color: NSColor, x: CGFloat, baseline: CGFloat) {
        guard !text.isEmpty else { return }
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        string.draw(with: NSRect(x: x, y: baseline, width: string.size().width + 4, height: 0),
                    options: [], context: nil)
    }
}
