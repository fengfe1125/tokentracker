import AppKit
import SwiftUI
import TokenTrackerCore

struct UsageHeatmapView: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var model: UsageHeatmapModel
    let yi: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("Token 用量热力图")).font(.headline)
                    Text(L10n.text("全部 Agent · 跟随上方时间范围 · 本地时区"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
            }
            if model.failed {
                HStack {
                    Label(L10n.text("用量读取失败，请重新扫描后重试"), systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button(L10n.text("重试")) { model.refresh() }
                }.font(.caption).foregroundStyle(.secondary)
            }
            if let chart = model.chart, model.loadedRequest == model.request {
                HeatmapChartPanel(chart: chart, yi: yi, locale: language.locale)
                    .opacity(model.failed ? 0.5 : 1)
            } else if !model.failed {
                Text(L10n.text("正在读取用量…")).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
        .onAppear { if model.chart == nil { model.refresh() } }
    }
}

private struct HeatmapChartPanel: View {
    let chart: UsageHeatmap
    let yi: Bool
    let locale: Locale
    @State private var focused: UsageHeatmap.Day?

    private var dateRange: String {
        let last = Calendar.current.date(byAdding: .day, value: -1, to: chart.end)!
        let style = Date.FormatStyle.dateTime.year().month().day().locale(locale)
        return chart.start.formatted(style) + (last == chart.start ? "" : " – " + last.formatted(style))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(dateRange)
                Spacer()
                Text(L10n.text("每格 1 天"))
            }.font(.caption).foregroundStyle(.secondary)
            HeatmapCanvas(chart: chart, locale: locale) { focused = $0 }
                .frame(height: HeatmapGridLayout.height(for: chart))
            HStack {
                Text(L10n.text("已记录 \(UIFormat.tokens(chart.totalTokens, yi: yi)) Token · \(chart.activeDays) 个活跃日"))
                Spacer()
                Text(L10n.text("少"))
                ForEach(0..<5) { level in
                    RoundedRectangle(cornerRadius: 2).fill(HeatmapCanvasView.color(level).swiftUIColor)
                        .frame(width: 9, height: 9)
                }
                Text(L10n.text("多"))
            }.font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                if let day = focused {
                    Text(HeatmapCanvasView.label(day, locale: locale))
                        .font(.caption.monospacedDigit())
                    Text(day.agents.isEmpty ? L10n.text("无已记录用量") : day.agents.map {
                        "\(toolDisplayName($0.tool)) \(UIFormat.tokens($0.tokens, yi: yi))"
                    }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    if day.estimatedTokens > 0 {
                        Text(L10n.text("其中区间估算 \(UIFormat.tokens(day.estimatedTokens, yi: yi)) Token"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Text(L10n.text("悬停或点选格子查看明细；聚焦后可用方向键浏览。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(minHeight: 48, alignment: .topLeading)
            Text(L10n.text("含输入、输出与缓存 Token；空白格表示未来日期或范围外，灰格表示无已记录用量。"))
                .font(.caption2).foregroundStyle(.secondary)
            if chart.totalTokens == 0 {
                Text(L10n.text("此范围暂无可定位用量；无记录不代表 Agent 没有使用。"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if chart.excludedTokens > 0 {
                Text(L10n.text("全部历史另有 \(UIFormat.tokens(chart.excludedTokens, yi: yi)) Token 无法可靠定位到天，未着色。"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.onChange(of: chart.id) { _, _ in focused = nil }
    }
}

private extension NSColor { var swiftUIColor: Color { Color(nsColor: self) } }

/// Fixed-cost hit testing; no per-cell SwiftUI buttons, hover handlers, or formatters.
/// Annual-style grid: weekday rows, week columns, one stacked block per calendar year.
struct HeatmapGridLayout {
    static let maximumCell: CGFloat = 12
    static let header: CGFloat = 16
    static let bandGap: CGFloat = 10
    let cell: CGFloat
    let left: CGFloat = 24
    let gap: CGFloat = 3
    let chart: UsageHeatmap
    init(chart: UsageHeatmap, width: CGFloat) {
        self.chart = chart
        cell = max(1, min(Self.maximumCell, (width - left) / CGFloat(max(1, chart.columns)) - gap))
    }
    static func height(for chart: UsageHeatmap) -> CGFloat {
        CGFloat(chart.bands.count) * (header + 7 * (maximumCell + 3) + bandGap)
    }
    var bandHeight: CGFloat { Self.header + 7 * (cell + gap) + Self.bandGap }
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

    static func color(_ level: Int) -> NSColor {
        level == 0 ? .labelColor.withAlphaComponent(0.08) : .systemGreen.withAlphaComponent([0, 0.25, 0.45, 0.7, 1][level])
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
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor]
        let weekLabels: [L10n.Template] = ["一", "", "三", "", "五", "", "日"]
        for band in chart.bands.indices {
            let top = layout.top(of: band)
            if chart.bands.count > 1 {
                (String(chart.bands[band].year) as NSString).draw(at: NSPoint(x: 0, y: top - HeatmapGridLayout.header), withAttributes: attrs)
            }
            for row in 0..<7 {
                (L10n.text(weekLabels[row]) as NSString).draw(at: NSPoint(x: 0, y: top + CGFloat(row) * (layout.cell + layout.gap)), withAttributes: attrs)
            }
        }
        var lastLabel = (y: CGFloat(-1), end: CGFloat(0))
        let firstDay = chart.cells.firstIndex { $0 != nil }
        for i in chart.cells.indices {
            guard let day = chart.cells[i] else { continue }
            let rect = layout.rect(i)
            // Month labels mark the range start and each month's first day, skipping collisions.
            if i == firstDay || Calendar.current.component(.day, from: day.date) == 1 {
                let month = day.date.formatted(.dateTime.month(.abbreviated).locale(locale)) as NSString
                let y = rect.minY - CGFloat(i % 7) * (layout.cell + layout.gap) - HeatmapGridLayout.header + 2
                if lastLabel.y != y || rect.minX >= lastLabel.end {
                    month.draw(at: NSPoint(x: rect.minX, y: y), withAttributes: attrs)
                    lastLabel = (y, rect.minX + month.size(withAttributes: attrs).width + 4)
                }
            }
            guard rect.intersects(dirtyRect.insetBy(dx: -2, dy: -2)) else { continue }
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            Self.color(chart.level(for: day.tokens)).setFill(); path.fill()
            if focusIndex == i {
                NSColor.labelColor.setStroke(); path.lineWidth = 1.5; path.stroke()
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
