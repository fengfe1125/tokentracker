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
                    Text(L10n.text("全部 Agent · 独立时间范围 · 本地时区"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
            }
            Picker(L10n.text("热力图时间范围"), selection: $model.request.period) {
                ForEach(HeatmapPeriod.allCases, id: \.self) { period in
                    Text(L10n.text(period.title)).tag(period)
                }
            }.pickerStyle(.segmented).labelsHidden()
            rangeControls
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

    @ViewBuilder private var rangeControls: some View {
        if model.request.period == .custom {
            HStack(spacing: 8) {
                DatePicker(L10n.text("开始"), selection: $model.request.start,
                           in: ...model.request.end, displayedComponents: .date)
                DatePicker(L10n.text("结束"), selection: $model.request.end,
                           in: model.request.start...Date(), displayedComponents: .date)
            }.font(.caption)
            Text(L10n.text("包含开始和结束日期；长时间范围自动按月或年汇总。"))
                .font(.caption2).foregroundStyle(.secondary)
        } else if model.request.period != .all {
            HStack(spacing: 8) {
                Button { model.move(-1) } label: { Image(systemName: "chevron.left") }
                    .help(L10n.text("上一时段")).accessibilityLabel(L10n.text("上一时段"))
                DatePicker(L10n.text("日期"), selection: $model.request.anchor,
                           in: ...Date(), displayedComponents: .date).labelsHidden()
                Button { model.move(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.canMoveForward)
                    .help(L10n.text("下一时段")).accessibilityLabel(L10n.text("下一时段"))
                Spacer()
                Button(L10n.text("回到今天")) { model.showToday() }
            }.controlSize(.small)
        }
    }
}

private struct HeatmapChartPanel: View {
    let chart: UsageHeatmap
    let yi: Bool
    let locale: Locale
    @State private var focused: UsageHeatmap.Day?

    private var unitLabel: L10n.Template {
        switch chart.unit {
        case .hour: "每格 1 小时"
        case .day: "每格 1 天"
        case .month: "每格 1 月"
        case .year(let step): step == 1 ? "每格 1 年" : "每格 \(step) 年"
        }
    }
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
                Text(L10n.text(unitLabel))
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
                    Text(HeatmapCanvasView.label(day, unit: chart.unit, locale: locale))
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
            if chart.hourlyExcludedTokens > 0 {
                Text(L10n.text("当日另有 \(UIFormat.tokens(chart.hourlyExcludedTokens, yi: yi)) Token 仅能定位到天，未分摊至小时。"))
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
struct HeatmapGridLayout {
    let cell: CGFloat
    let left: CGFloat
    let top: CGFloat = 20
    let gap: CGFloat = 3
    let chart: UsageHeatmap
    init(chart: UsageHeatmap, width: CGFloat) {
        self.chart = chart
        left = chart.columnMajor ? 24 : 0
        let maximum: CGFloat = chart.columnMajor ? 12 : 32
        cell = max(1, min(maximum, (width - left) / CGFloat(chart.columns) - gap))
    }
    static func height(for chart: UsageHeatmap) -> CGFloat {
        22 + CGFloat(chart.rowCount) * (chart.columnMajor ? 15 : 35)
    }
    func rect(_ index: Int) -> NSRect {
        let column = chart.columnMajor ? index / chart.rowCount : index % chart.columns
        let row = chart.columnMajor ? index % chart.rowCount : index / chart.columns
        // Nonannual grids use all available width for readable labels.
        return NSRect(x: left + CGFloat(column) * (cell + gap),
                      y: top + CGFloat(row) * (cell + gap), width: cell, height: cell)
    }
    func index(at point: NSPoint) -> Int? {
        guard point.x >= left, point.y >= top else { return nil }
        let col = Int((point.x - left) / (cell + gap)), row = Int((point.y - top) / (cell + gap))
        guard col < chart.columns, row < chart.rowCount,
              (point.x - left).truncatingRemainder(dividingBy: cell + gap) <= cell,
              (point.y - top).truncatingRemainder(dividingBy: cell + gap) <= cell else { return nil }
        let i = chart.columnMajor ? col * chart.rowCount + row : row * chart.columns + col
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
    private var smallLabels: [String] = []
    private var hovered: Int?
    private var selected: Int?
    private var focusIndex: Int? { hovered ?? selected }
    var onFocus: ((UsageHeatmap.Day?) -> Void)?

    static func color(_ level: Int) -> NSColor {
        level == 0 ? .labelColor.withAlphaComponent(0.08) : .systemGreen.withAlphaComponent([0, 0.25, 0.45, 0.7, 1][level])
    }
    static func label(_ day: UsageHeatmap.Day, unit: UsageHeatmap.Unit, locale: Locale) -> String {
        var style = Date.FormatStyle.dateTime.year().month().day().locale(locale)
        if unit == .hour { style = style.hour().minute().timeZone(.specificName(.short)) }
        var text = day.date.formatted(style)
        if let end = day.end, unit != .hour {
            let last = Calendar.current.date(byAdding: .day, value: -1, to: end)!
            text += " – " + last.formatted(style)
        }
        return text + " · " + day.tokens.formatted(.number.locale(locale)) + " Token"
    }
    func update(_ newChart: UsageHeatmap, locale: Locale) {
        guard chart?.id != newChart.id || self.locale != locale else { return }
        chart = newChart; self.locale = locale
        hovered = nil; selected = nil
        labels = newChart.cells.map { $0.map { Self.label($0, unit: newChart.unit, locale: locale) } ?? "" }
        smallLabels = newChart.cells.map { day in
            guard let day else { return "" }
            switch newChart.unit {
            case .hour: return day.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).locale(locale))
            case .day: return String(Calendar.current.component(.day, from: day.date))
            case .month:
                let parts = Calendar.current.dateComponents([.year, .month], from: day.date)
                return String(format: "%02d/%02d", (parts.year ?? 0) % 100, parts.month ?? 1)
            case .year: return String(Calendar.current.component(.year, from: day.date))
            }
        }
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
        let font = NSFont.systemFont(ofSize: chart.columnMajor ? 9 : 10)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        if chart.columnMajor {
            let weekLabels: [L10n.Template] = ["一", "", "三", "", "五", "", "日"]
            for row in 0..<7 {
                (L10n.text(weekLabels[row]) as NSString).draw(at: NSPoint(x: 0, y: layout.top + CGFloat(row) * (layout.cell + layout.gap)), withAttributes: attrs)
            }
        } else if chart.unit == .day {
            let labels: [L10n.Template] = ["一", "二", "三", "四", "五", "六", "日"]
            for col in 0..<7 {
                (L10n.text(labels[col]) as NSString).draw(at: NSPoint(x: CGFloat(col) * (layout.cell + layout.gap) + 8, y: 0), withAttributes: attrs)
            }
        }
        for i in chart.cells.indices {
            guard let day = chart.cells[i] else { continue }
            let rect = layout.rect(i)
            guard rect.intersects(dirtyRect.insetBy(dx: -2, dy: -20)) else { continue }
            if chart.columnMajor, Calendar.current.component(.day, from: day.date) == 1 {
                let month = day.date.formatted(.dateTime.month(.abbreviated).locale(locale))
                (month as NSString).draw(at: NSPoint(x: rect.minX, y: 0), withAttributes: attrs)
            }
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            Self.color(chart.level(for: day.tokens)).setFill(); path.fill()
            if !chart.columnMajor {
                let text = smallLabels[i] as NSString
                let textAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: chart.unit == .month ? 8 : 10),
                    .foregroundColor: chart.level(for: day.tokens) >= 3 ? NSColor.black : NSColor.labelColor]
                let size = text.size(withAttributes: textAttrs)
                text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: textAttrs)
            }
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
        case 123: step = chart.columnMajor ? -chart.rowCount : -1
        case 124: step = chart.columnMajor ? chart.rowCount : 1
        case 125: step = chart.columnMajor ? 1 : chart.columns
        case 126: step = chart.columnMajor ? -1 : -chart.columns
        default: super.keyDown(with: event); return
        }
        var candidate = focusIndex.map { $0 + step } ?? (chart.cells.firstIndex { $0 != nil } ?? 0)
        while chart.cells.indices.contains(candidate), chart.cells[candidate] == nil { candidate += step > 0 ? 1 : -1 }
        if chart.cells.indices.contains(candidate) { hovered = nil; selected = candidate; publishFocus(from: old) }
    }
}
