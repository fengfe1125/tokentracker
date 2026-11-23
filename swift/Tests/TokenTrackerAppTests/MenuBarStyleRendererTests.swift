import AppKit
import XCTest
import TokenTrackerCore
@testable import TokenTrackerApp

@MainActor
final class MenuBarStyleRendererTests: XCTestCase {
    private let labels = MenuBarLabels(today: "今日 Token", scanning: "扫描中…")

    private func display(pct: Double?, provider: String = "codex", tokens: Int64? = 44_120_000) -> MenuBarDisplay {
        let entry = MenuBarQuotaEntry(id: provider, name: provider == "codex" ? "Codex" : "Claude",
                                      windows: pct.map { [MenuBarQuotaWindow(pct: $0, source: "official",
                                                                              stale: false, label: "5h")] } ?? [])
        return MenuBarFmt.display(today: tokens.map { MenuBarToday(tokens: $0, cost: 0) },
                                  entries: [entry], provider: provider, yi: true)
    }

    func testTemplateOnlyWhenNoColorNeeded() {
        let calm = display(pct: 22)
        XCTAssertFalse(MenuBarStyleRenderer.needsColor(display: calm, style: .native, anim: .init()))
        XCTAssertFalse(MenuBarStyleRenderer.needsColor(display: calm, style: .stacked, anim: .init()))
        XCTAssertTrue(MenuBarStyleRenderer.needsColor(display: calm, style: .capsule, anim: .init()))
        XCTAssertTrue(MenuBarStyleRenderer.needsColor(display: display(pct: 65), style: .native, anim: .init()))
        XCTAssertTrue(MenuBarStyleRenderer.needsColor(display: calm, style: .native,
                                                      anim: MenuBarAnimation(flash: 0.3)))
        let image = MenuBarStyleRenderer.image(display: calm, style: .native, compact: false,
                                               anim: .init(), labels: labels)
        XCTAssertTrue(image.isTemplate)
    }

    func testWidthsAreStableAndCompactIsNarrower() {
        for style in MenuBarStyle.allCases {
            let normal = MenuBarStyleRenderer.image(display: display(pct: 38), style: style, compact: false,
                                                    anim: .init(), labels: labels)
            XCTAssertEqual(normal.size.height, MenuBarStyleRenderer.height)
            XCTAssertGreaterThan(normal.size.width, 30, "\(style)")
            XCTAssertLessThan(normal.size.width, 140, "\(style)")
            if style != .stacked {
                let compact = MenuBarStyleRenderer.image(display: display(pct: 38), style: style, compact: true,
                                                         anim: .init(), labels: labels)
                XCTAssertLessThan(compact.size.width, normal.size.width, "\(style)")
            }
            // 扫描中保留数字，标题宽度不跳到「扫描中…」
            let scanning = MenuBarStyleRenderer.image(display: display(pct: 38), style: style, compact: false,
                                                      anim: MenuBarAnimation(scanning: true, spin: 3), labels: labels)
            XCTAssertEqual(scanning.size.width, normal.size.width, accuracy: style == .native ? 0.5 : 20,
                           "\(style)")
        }
    }

    func testCacheKeyTracksContentStyleAndAnimation() {
        let base = MenuBarStyleRenderer.cacheKey(display: display(pct: 38), style: .native, compact: false,
                                                 anim: .init(), labels: labels)
        XCTAssertEqual(base, MenuBarStyleRenderer.cacheKey(display: display(pct: 38), style: .native,
                                                           compact: false, anim: .init(), labels: labels))
        XCTAssertNotEqual(base, MenuBarStyleRenderer.cacheKey(display: display(pct: 39), style: .native,
                                                              compact: false, anim: .init(), labels: labels))
        XCTAssertNotEqual(base, MenuBarStyleRenderer.cacheKey(display: display(pct: 38), style: .capsule,
                                                              compact: false, anim: .init(), labels: labels))
        XCTAssertNotEqual(base, MenuBarStyleRenderer.cacheKey(display: display(pct: 38), style: .native,
                                                              compact: false, anim: MenuBarAnimation(pulse: 0.5),
                                                              labels: labels))
    }

    /// TT_RENDER_DIR=/path 时把各样式各状态渲染成 PNG（浅色 / 深色）供人工检查。
    func testRenderGalleryWhenRequested() throws {
        guard let dir = ProcessInfo.processInfo.environment["TT_RENDER_DIR"] else {
            throw XCTSkip("set TT_RENDER_DIR to dump previews")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let states: [(String, MenuBarDisplay, MenuBarAnimation)] = [
            ("ok", display(pct: 22), .init()),
            ("warn", display(pct: 65), .init()),
            ("crit", display(pct: 92), .init()),
            ("nodata", display(pct: nil), .init()),
            ("scan", display(pct: 38), MenuBarAnimation(scanning: true, spin: 3)),
            ("notoday", display(pct: 38, tokens: nil), .init()),
            ("off", MenuBarFmt.display(today: MenuBarToday(tokens: 44_120_000, cost: 0), entries: [],
                                       provider: "off", yi: true), .init()),
            ("flash", display(pct: 38), MenuBarAnimation(flash: 0.2)),
        ]
        for style in MenuBarStyle.allCases {
            for (name, value, anim) in states {
                for dark in [false, true] {
                    let image = MenuBarStyleRenderer.image(
                        display: value, style: style, compact: false, anim: anim, labels: labels,
                        appearance: NSAppearance(named: dark ? .darkAqua : .aqua), scale: 4)
                    let rep = NSBitmapImageRep(
                        bitmapDataPlanes: nil, pixelsWide: Int(image.size.width) + 16,
                        pixelsHigh: Int(image.size.height), bitsPerSample: 8, samplesPerPixel: 4,
                        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                        bitsPerPixel: 0)!
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                    (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                    NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh).fill()
                    image.draw(at: NSPoint(x: 8, y: 0), from: .zero, operation: .sourceOver, fraction: 1)
                    NSGraphicsContext.restoreGraphicsState()
                    let png = rep.representation(using: .png, properties: [:])!
                    try png.write(to: URL(fileURLWithPath: "\(dir)/\(style.rawValue)-\(name)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }
}
