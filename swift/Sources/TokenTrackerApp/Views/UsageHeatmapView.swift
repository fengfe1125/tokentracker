import AppKit
import SwiftUI
import TokenTrackerCore

struct UsageHeatmapView: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var model: UsageHeatmapModel
    let yi: Bool

    private var chart: UsageHeatmap? {
        model.loadedRequest == model.request ? model.chart : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(L10n.text("Token 用量热力图")).font(.headline)
                        if model.loading { ProgressView().controlSize(.mini) }
                    }
                    Text(chart.map { L10n.text("全部 Agent · \(rangeText($0))") } ?? L10n.text("全部 Agent · 本地时区"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let chart { HeatmapStats(chart: chart, yi: yi, locale: language.locale) }
            }
            if model.failed {
                HStack {
                    Label(L10n.text("用量读取失败，请重新扫描后重试"), systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button(L10n.text("重试")) { model.refresh() }
                }.font(.caption).foregroundStyle(.secondary)
            }
            if let chart {
                HeatmapChartPanel(chart: chart, yi: yi, locale: language.locale)
                    .opacity(model.failed ? 0.5 : 1)
            } else if !model.failed {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 150)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
        .onAppear { if model.chart == nil { model.refresh() } }
    }

    private func rangeText(_ chart: UsageHeatmap) -> String {
        let last = Calendar.current.date(byAdding: .day, value: -1, to: chart.end)!
        let sameYear = Calendar.current.isDate(chart.start, equalTo: last, toGranularity: .year)
        let short = Date.FormatStyle.dateTime.month().day().locale(language.locale)
        let long = short.year()
        if last == chart.start { return chart.start.formatted(long) }
        return chart.start.formatted(sameYear ? short : long) + " – " + last.formatted(long)
    }
}

/// Range totals shown beside the title; every value counts only the selected days.
private struct HeatmapStats: View {
    let chart: UsageHeatmap
    let yi: Bool
    let locale: Locale

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            metric(L10n.text("合计"), UIFormat.tokens(chart.totalTokens, yi: yi), nil)
            metric(L10n.text("活跃天数"), "\(chart.activeDays) / \(chart.rangeDays)", nil)
            metric(L10n.text("单日峰值"), chart.peak.map { UIFormat.tokens($0.tokens, yi: yi) } ?? "—",
                   chart.peak?.date.formatted(.dateTime.month().day().locale(locale)))
        }
    }

    private func metric(_ title: String, _ value: String, _ detail: String?) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }
}

private struct HeatmapChartPanel: View {
    let chart: UsageHeatmap
    let yi: Bool
    let locale: Locale
    @State private var focused: UsageHeatmap.Day?
    @State private var width: CGFloat = 640

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeatmapCanvas(chart: chart, locale: locale) { focused = $0 }
                .frame(height: HeatmapGridLayout(chart: chart, width: width).height)
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            HStack(alignment: .center, spacing: 12) {
                detail.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 3) {
                    Text(L10n.text("少")).padding(.trailing, 2)
                    ForEach(0..<5) { level in
                        RoundedRectangle(cornerRadius: 2.5).fill(Color(nsColor: HeatmapCanvasView.color(level)))
                            .frame(width: 10, height: 10)
                    }
                    Text(L10n.text("多")).padding(.leading, 2)
                }.font(.caption2).foregroundStyle(.secondary)
            }
            .frame(minHeight: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("所选范围外的日期以淡色显示，灰格为无已记录用量；含输入、输出与缓存 Token。"))
                if chart.excludedTokens > 0 {
                    Text(L10n.text("全部历史另有 \(UIFormat.tokens(chart.excludedTokens, yi: yi)) Token 无法可靠定位到天，未着色。"))
                }
            }.font(.caption2).foregroundStyle(.tertiary)
        }.onChange(of: chart.id) { _, _ in focused = nil }
    }

    @ViewBuilder private var detail: some View {
        if let day = focused {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(day.date.formatted(.dateTime.year().month().day().weekday(.abbreviated).locale(locale)))
                        .foregroundStyle(.secondary)
                    Text(L10n.text("\(UIFormat.tokens(day.tokens, yi: yi)) Token")).fontWeight(.semibold)
                    if day.estimatedTokens > 0 {
                        Text(L10n.text("其中区间估算 \(UIFormat.tokens(day.estimatedTokens, yi: yi)) Token"))
                            .foregroundStyle(.secondary)
                    }
                }.font(.caption.monospacedDigit())
                HStack(spacing: 10) {
                    if day.agents.isEmpty { Text(L10n.text("无已记录用量")) }
                    ForEach(day.agents.prefix(5), id: \.tool) { agent in
                        HStack(spacing: 4) {
                            Circle().fill(toolColor(agent.tool)).frame(width: 6, height: 6)
                            Text("\(toolDisplayName(agent.tool)) \(UIFormat.tokens(agent.tokens, yi: yi))")
                        }
                    }
                }.font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        } else {
            Text(L10n.text("悬停或点选格子查看当日明细"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Fixed-cost hit testing; no per-cell SwiftUI buttons, hover handlers, or formatters.
/// Annual grid: weekday rows, week columns, one stacked block per calendar year, filling the width.
struct HeatmapGridLayout {
    static let maximumCell: CGFloat = 16
    static let header: CGFloat = 18
    static let bandGap: CGFloat = 14
    let cell: CGFloat
    let left: CGFloat = 26
    let gap: CGFloat
    let chart: UsageHeatmap
    init(chart: UsageHeatmap, width: CGFloat) {
        self.chart = chart
        let pitch = (width - left) / CGFloat(max(1, chart.columns))
        gap = pitch >= 12 ? 3 : 2
        cell = max(2, min(Self.maximumCell, pitch - gap))
    }
    var bandHeight: CGFloat { Self.header + 7 * (cell + gap) + Self.bandGap }
    var height: CGFloat { CGFloat(chart.bands.count) * bandHeight - Self.bandGap }
    func top(of band: Int) -> CGFloat { CGFloat(band) * bandHeight + Self.header }
    func band(ofColumn column: Int) -> Int {
        chart.bands.lastIndex { $0.firstColumn <= column } ?? 0
    }
    func rect(_ index: Int) -> NSRect {
        let column = index / 7, row = index % 7, band = band(ofColumn: column)
        return NSRect(x: left + CGFloat(column - chart.bands[band].firstColumn) * (cell + gap),
                      y: top(of: band) + CGFloat(row) * (cell + gap), width: cell, height: cell)
    }
    func index(at point: NSPoint) -> Int? {
        guard point.x >= left, point.y >= 0 else { return nil }
        let band = Int(point.y / bandHeight)
        guard chart.bands.indices.contains(band) else { return nil }
        let y = point.y - top(of: band), x = point.x - left
        guard y >= 0 else { return nil }
        let col = Int(x / (cell + gap)), row = Int(y / (cell + gap))
        guard col < chart.bands[band].columns, row < 7,
              x.truncatingRemainder(dividingBy: cell + gap) <= cell,
              y.truncatingRemainder(dividingBy: cell + gap) <= cell else { return nil }
        let i = (chart.bands[band].firstColumn + col) * 7 + row
        return chart.cells.indices.contains(i) && chart.cells[i] != nil ? i : nil
    }
}

private struct HeatmapCanvas: NSViewRepresentable {
    let chart: UsageHeatmap
    let locale: Locale
    let focus: (UsageHeatmap.Day?) -> Void
    func makeNSView(context: Context) -> HeatmapCanvasView { HeatmapCanvasView() }
    func updateNSView(_ view: HeatmapCanvasView, context: Context) {
        view.onFocus = focus
        view.update(chart, locale: locale)
    }
}

final class HeatmapCanvasView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private(set) var chart: UsageHeatmap?
    private var locale = Locale.current
    private var labels: [String] = []
    private var hovered: Int?
    private var selected: Int?
    private var focusIndex: Int? { hovered ?? selected }
    var onFocus: ((UsageHeatmap.Day?) -> Void)?

    /// GitHub-style greens tuned separately for light and dark appearances.
    static func color(_ level: Int) -> NSColor {
        let light: [UInt32] = [0xEBEDF0, 0x9BE9A8, 0x40C463, 0x30A14E, 0x216E39]
        let dark: [UInt32] = [0x2D333B, 0x0E4429, 0x006D32, 0x26A641, 0x39D353]
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let rgb = (isDark ? dark : light)[max(0, min(4, level))]
            return NSColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255,
                           blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        }
    }
    static func label(_ day: UsageHeatmap.Day, locale: Locale) -> String {
        day.date.formatted(.dateTime.year().month().day().weekday(.abbreviated).locale(locale))
            + " · " + day.tokens.formatted(.number.locale(locale)) + " Token"
    }
    func update(_ newChart: UsageHeatmap, locale: Locale) {
        guard chart?.id != newChart.id || self.locale != locale else { return }
        chart = newChart; self.locale = locale
        hovered = nil; selected = nil
        labels = newChart.cells.map { $0.map { Self.label($0, locale: locale) } ?? "" }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.text("Token 用量热力图"))
        setAccessibilityHelp(L10n.text("悬停或点选格子查看明细；聚焦后可用方向键浏览。"))
        setAccessibilityValue(L10n.text("请选择一个格子"))
        needsDisplay = true
    }
    override func updateTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        guard let chart else { return }
        let layout = HeatmapGridLayout(chart: chart, width: bounds.width)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9.5), .foregroundColor: NSColor.secondaryLabelColor]
        let yearAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.labelColor]
        let weekLabels: [L10n.Template] = ["一", "", "三", "", "五", "", ""]
        for band in chart.bands.indices {
            let top = layout.top(of: band)
            if chart.bands.count > 1 {
                (String(chart.bands[band].year) as NSString).draw(at: NSPoint(x: 0, y: top - HeatmapGridLayout.header), withAttributes: yearAttrs)
            }
            for row in 0..<7 where !weekLabels[row].key.isEmpty {
                let text = L10n.text(weekLabels[row]) as NSString
                let size = text.size(withAttributes: attrs)
                text.draw(at: NSPoint(x: 0, y: top + CGFloat(row) * (layout.cell + layout.gap) + (layout.cell - size.height) / 2), withAttributes: attrs)
            }
        }
        var lastLabel = (y: CGFloat(-1), end: CGFloat(0))
        let radius = min(3, layout.cell / 4)
        let placeholder = NSColor.labelColor.withAlphaComponent(0.04)
        for i in chart.cells.indices {
            guard let day = chart.cells[i] else {
                if chart.future.contains(i) {
                    placeholder.setFill()
                    NSBezierPath(roundedRect: layout.rect(i), xRadius: radius, yRadius: radius).fill()
                }
                continue
            }
            let rect = layout.rect(i)
            if Calendar.current.component(.day, from: day.date) == 1 {
                let month = day.date.formatted(.dateTime.month(.abbreviated).locale(locale)) as NSString
                let y = rect.minY - CGFloat(i % 7) * (layout.cell + layout.gap) - HeatmapGridLayout.header + 1
                if lastLabel.y != y || rect.minX >= lastLabel.end {
                    month.draw(at: NSPoint(x: rect.minX, y: y), withAttributes: attrs)
                    lastLabel = (y, rect.minX + month.size(withAttributes: attrs).width + 4)
                }
            }
            guard rect.intersects(dirtyRect.insetBy(dx: -3, dy: -3)) else { continue }
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            let color = Self.color(chart.level(for: day.tokens))
            (chart.contains(day) ? color : color.withAlphaComponent(0.28)).setFill(); path.fill()
            if focusIndex == i {
                NSColor.labelColor.setStroke(); path.lineWidth = 1.5; path.stroke()
            } else if day.date == chart.today {
                let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
                NSColor.controlAccentColor.setStroke(); ring.lineWidth = 1; ring.stroke()
            }
        }
    }
    private func invalidate(_ index: Int?) {
        guard let chart, let index else { return }
        setNeedsDisplay(HeatmapGridLayout(chart: chart, width: bounds.width).rect(index).insetBy(dx: -2, dy: -2))
    }
    private func publishFocus(from old: Int?) {
        guard old != focusIndex else { return }
        invalidate(old); invalidate(focusIndex)
        let day = focusIndex.flatMap { chart?.cells[$0] }
        onFocus?(day)
        setAccessibilityValue(focusIndex.map { labels[$0] } ?? L10n.text("请选择一个格子"))
        NSAccessibility.post(element: self, notification: .valueChanged)
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        focus(at: convert(event.locationInWindow, from: nil))
    }
    func focus(at point: NSPoint) {
        guard let chart else { return }
        let old = focusIndex
        hovered = HeatmapGridLayout(chart: chart, width: bounds.width).index(at: point)
        publishFocus(from: old)
    }
    override func mouseExited(with event: NSEvent) {
        let old = focusIndex; hovered = nil; publishFocus(from: old)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mouseMoved(with: event)
        selected = hovered
    }
    override func keyDown(with event: NSEvent) {
        guard let chart else { return }
        let old = focusIndex
        if event.keyCode == 53 { hovered = nil; selected = nil; publishFocus(from: old); return }
        let step: Int
        switch event.keyCode {
        case 123: step = -7
        case 124: step = 7
        case 125: step = 1
        case 126: step = -1
        default: super.keyDown(with: event); return
        }
        var candidate = focusIndex.map { $0 + step } ?? (chart.cells.firstIndex { $0 != nil } ?? 0)
        while chart.cells.indices.contains(candidate), chart.cells[candidate] == nil { candidate += step > 0 ? 1 : -1 }
        if chart.cells.indices.contains(candidate) { hovered = nil; selected = candidate; publishFocus(from: old) }
    }
}
