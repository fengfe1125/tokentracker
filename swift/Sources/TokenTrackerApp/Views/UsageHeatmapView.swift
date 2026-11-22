import AppKit
import SwiftUI
import TokenTrackerCore

struct UsageHeatmapView: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject var model: UsageHeatmapModel
    let yi: Bool
    @State private var slowLoading = false

    /// 切换范围时保留上一帧热力图，避免闪出空白加载圈和二次跳动。
    private var chart: UsageHeatmap? { model.chart }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(L10n.text("Token 用量热力图")).font(.headline)
                        if slowLoading { ProgressView().controlSize(.mini) }
                    }
                    Text(((model.loadedRequest?.tool ?? model.request.tool).map(toolDisplayName) ?? L10n.text("全部 Agent")) + " · "
                         + (chart.map(rangeText) ?? L10n.text("本地时区")))
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
        .card()
        .task(id: model.loading) {
            guard model.loading else { slowLoading = false; return }
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled { slowLoading = true }
        }
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
            if chart.unit == .hour {
                metric(L10n.text("活跃小时"), "\(chart.activeHours) / \(chart.elapsedHours)", nil)
                metric(L10n.text("峰值小时"), chart.peak.map { UIFormat.tokens($0.tokens, yi: yi) } ?? "—",
                       chart.peak.map { HeatmapCanvasView.hourLabel($0.date, short: chart.rangeDays > 1) })
            } else {
                metric(L10n.text("活跃天数"), "\(chart.activeDays) / \(chart.rangeDays)", nil)
                metric(L10n.text("单日峰值"), chart.peak.map { UIFormat.tokens($0.tokens, yi: yi) } ?? "—",
                       chart.peak?.date.formatted(.dateTime.month().day().locale(locale)))
            }
        }
    }

    private func metric(_ title: String, _ value: String, _ detail: String?) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
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
        let canvasHeight = HeatmapGridLayout(chart: chart, width: width).height
        VStack(alignment: .leading, spacing: 12) {
            // 外层平滑改变裁剪高度，内层 NSView 禁用帧内插值一次性重绘，避免每帧 120Hz 重复 draw(_:)。
            Color.clear
                .frame(height: canvasHeight)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topLeading) {
                    HeatmapCanvas(chart: chart, yi: yi, locale: locale) { focused = $0 }
                        .frame(height: canvasHeight)
                        .transaction { $0.animation = nil }
                }
                .clipped()
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
                switch chart.style {
                case .hourly:
                    Text(L10n.text("每格 1 小时，浅色格为尚未到来的时段，灰格为无已记录用量；含输入、输出与缓存 Token。"))
                case .monthCalendar:
                    Text(L10n.text("每格 1 天，浅色格为本月尚未到来的日期，灰格为无已记录用量；含输入、输出与缓存 Token。"))
                case .yearly:
                    Text(L10n.text("每格 1 天，范围前的日期以淡色显示，灰格为无已记录用量；含输入、输出与缓存 Token。"))
                }
                if chart.hourlyExcludedTokens > 0 {
                    Text(L10n.text("所选范围另有 \(UIFormat.tokens(chart.hourlyExcludedTokens, yi: yi)) Token 仅能定位到天，未分摊到小时。"))
                }
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
                    Text(day.date.formatted(.dateTime.year().month().day().weekday(.abbreviated).locale(locale))
                         + (chart.unit == .hour ? " " + HeatmapCanvasView.hourLabel(day.date, short: false) : ""))
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
            Text(L10n.text("悬停或点选格子查看明细"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Fixed-cost hit testing; no per-cell SwiftUI buttons, hover handlers, or formatters.
/// - `.hourly`: one row per day, 24 columns.
/// - `.monthCalendar`: Monday–Sunday calendar tiles (7 columns) with an optional row-aligned weekly summary column.
/// - `.yearly`: weekday rows, week columns, one band per year.
struct HeatmapGridLayout {
    static let header: CGFloat = 18
    static let monthHeader: CGFloat = 22
    static let bandGap: CGFloat = 14
    static let summaryGap: CGFloat = 20
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let left: CGFloat
    let gap: CGFloat
    let headerHeight: CGFloat
    let summaryX: CGFloat
    let summaryWidth: CGFloat
    let chart: UsageHeatmap
    init(chart: UsageHeatmap, width: CGFloat) {
        self.chart = chart
        switch chart.style {
        case .hourly:
            left = 40
            headerHeight = Self.header
            summaryX = width
            summaryWidth = 0
            let columns = CGFloat(max(1, chart.columns))
            gap = (width - left) / columns >= 12 ? 3 : 2
            let pitch = (width - left + gap) / columns // the last column ends flush with the right edge
            cellWidth = max(2, pitch - gap)
            let cap: CGFloat = chart.rowDays.count <= 7 ? 26 : 14
            cellHeight = min(cellWidth, cap)
        case .monthCalendar:
            left = 0
            headerHeight = Self.monthHeader
            gap = width >= 540 ? 6 : 4
            let showSummary = width >= 620
            let sumWidth: CGFloat = showSummary ? min(300, max(190, floor(width * 0.28))) : 0
            summaryWidth = sumWidth
            let gridWidth = showSummary ? width - sumWidth - Self.summaryGap : width
            summaryX = showSummary ? gridWidth + Self.summaryGap : width
            let pitch = (gridWidth + gap) / 7
            cellWidth = max(24, pitch - gap)
            let rows = max(1, chart.monthRowCount)
            let maxTileHeight: CGFloat = rows >= 6 ? 48 : 54
            cellHeight = min(maxTileHeight, max(44, round(cellWidth * 0.58)))
        case .yearly:
            left = 26
            headerHeight = Self.header
            summaryX = width
            summaryWidth = 0
            let columns = CGFloat(max(1, chart.columns))
            gap = (width - left) / columns >= 12 ? 3 : 2
            let pitch = (width - left + gap) / columns
            cellWidth = max(2, pitch - gap)
            cellHeight = min(cellWidth, 20)
        }
    }
    var rowPitch: CGFloat { cellHeight + gap }
    var rowCount: Int {
        switch chart.style {
        case .hourly: chart.rowDays.count
        case .monthCalendar: chart.monthRowCount
        case .yearly: 7
        }
    }
    var bandHeight: CGFloat { headerHeight + CGFloat(rowCount) * rowPitch + Self.bandGap }
    var height: CGFloat {
        switch chart.style {
        case .hourly:
            return headerHeight + CGFloat(rowCount) * rowPitch
        case .monthCalendar:
            return max(headerHeight, headerHeight + CGFloat(rowCount) * rowPitch - gap)
        case .yearly:
            return CGFloat(max(1, chart.bands.count)) * bandHeight - Self.bandGap
        }
    }
    func top(of band: Int) -> CGFloat { CGFloat(band) * bandHeight + headerHeight }
    func band(ofColumn column: Int) -> Int {
        chart.bands.lastIndex { $0.firstColumn <= column } ?? 0
    }
    func summaryRect(row: Int) -> NSRect? {
        guard chart.style == .monthCalendar, summaryWidth > 0, row >= 0, row < rowCount else { return nil }
        return NSRect(x: summaryX, y: top(of: 0) + CGFloat(row) * rowPitch,
                      width: summaryWidth, height: cellHeight)
    }
    func rect(_ index: Int) -> NSRect {
        switch chart.style {
        case .hourly:
            return NSRect(x: left + CGFloat(index % 24) * (cellWidth + gap),
                          y: top(of: 0) + CGFloat(index / 24) * rowPitch,
                          width: cellWidth, height: cellHeight)
        case .monthCalendar:
            return NSRect(x: left + CGFloat(index % 7) * (cellWidth + gap),
                          y: top(of: 0) + CGFloat(index / 7) * rowPitch,
                          width: cellWidth, height: cellHeight)
        case .yearly:
            let column = index / 7, row = index % 7, band = band(ofColumn: column)
            return NSRect(x: left + CGFloat(column - chart.bands[band].firstColumn) * (cellWidth + gap),
                          y: top(of: band) + CGFloat(row) * rowPitch, width: cellWidth, height: cellHeight)
        }
    }
    func index(at point: NSPoint) -> Int? {
        guard point.x >= left, point.y >= 0 else { return nil }
        switch chart.style {
        case .hourly:
            let x = point.x - left, y = point.y - top(of: 0)
            guard y >= 0 else { return nil }
            let col = Int(x / (cellWidth + gap)), row = Int(y / rowPitch)
            guard col < 24, row < rowCount,
                  x.truncatingRemainder(dividingBy: cellWidth + gap) <= cellWidth,
                  y.truncatingRemainder(dividingBy: rowPitch) <= cellHeight else { return nil }
            let i = row * 24 + col
            return chart.cells.indices.contains(i) && chart.cells[i] != nil ? i : nil
        case .monthCalendar:
            let x = point.x - left, y = point.y - top(of: 0)
            guard y >= 0 else { return nil }
            let col = Int(x / (cellWidth + gap)), row = Int(y / rowPitch)
            guard col < 7, row < rowCount,
                  x.truncatingRemainder(dividingBy: cellWidth + gap) <= cellWidth,
                  y.truncatingRemainder(dividingBy: rowPitch) <= cellHeight else { return nil }
            let i = row * 7 + col
            return chart.cells.indices.contains(i) && chart.cells[i] != nil ? i : nil
        case .yearly:
            let band = Int(point.y / bandHeight)
            let bandColumns = chart.bands.indices.contains(band) ? chart.bands[band].columns : 0
            guard bandColumns > 0 else { return nil }
            let y = point.y - top(of: band), x = point.x - left
            guard y >= 0 else { return nil }
            let col = Int(x / (cellWidth + gap)), row = Int(y / rowPitch)
            guard col < bandColumns, row < rowCount,
                  x.truncatingRemainder(dividingBy: cellWidth + gap) <= cellWidth,
                  y.truncatingRemainder(dividingBy: rowPitch) <= cellHeight else { return nil }
            let i = (chart.bands[band].firstColumn + col) * 7 + row
            return chart.cells.indices.contains(i) && chart.cells[i] != nil ? i : nil
        }
    }
}

private struct HeatmapCanvas: NSViewRepresentable {
    let chart: UsageHeatmap
    let yi: Bool
    let locale: Locale
    let focus: (UsageHeatmap.Day?) -> Void
    func makeNSView(context: Context) -> HeatmapCanvasView { HeatmapCanvasView() }
    func updateNSView(_ view: HeatmapCanvasView, context: Context) {
        view.onFocus = focus
        view.update(chart, yi: yi, locale: locale)
    }
}

final class HeatmapCanvasView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private(set) var chart: UsageHeatmap?
    private var yi = false
    private var locale = Locale.current
    private var hovered: Int?
    private var selected: Int?
    private var focusIndex: Int? { hovered ?? selected }
    private var hoverToken = HoverTokenBox()
    private var cachedMonthLabels: [(index: Int, text: NSString)] = []
    private var cachedRowLabels: [NSString] = []
    var onFocus: ((UsageHeatmap.Day?) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    /// 预建 5 级动态色，避免每次 draw 为每个格子重新分配 NSColor 闭包。
    private static let levelColors: [NSColor] = {
        let light: [UInt32] = [0xEBEDF0, 0xDCD0F7, 0xB9A2F0, 0x9470E6, 0x6F45D8]
        let dark: [UInt32] = [0x2D333B, 0x3B2D6E, 0x5C45B0, 0x8566E0, 0xA88CFF]
        return (0..<5).map { level in
            dynamicColor(lightRGB: light[level], darkRGB: dark[level])
        }
    }()

    /// 月历格子内的日期文字动态色，保证亮暗模式下所有热力色阶均有清晰对比度。
    private static let tileDayColors: [NSColor] = [
        .secondaryLabelColor,
        dynamicColor(lightRGB: 0x3B2B66, lightAlpha: 0.78, darkRGB: 0xD9D0FF, darkAlpha: 0.78),
        dynamicColor(lightRGB: 0x26174D, lightAlpha: 0.80, darkRGB: 0xEDE8FF, darkAlpha: 0.84),
        dynamicColor(lightRGB: 0xFFFFFF, lightAlpha: 0.86, darkRGB: 0xFFFFFF, darkAlpha: 0.88),
        dynamicColor(lightRGB: 0xFFFFFF, lightAlpha: 0.88, darkRGB: 0x1F1242, darkAlpha: 0.78),
    ]

    /// 月历格子内的 Token 数值动态色（暗色最高阶亮紫底配深墨字）。
    private static let tileValueColors: [NSColor] = [
        .secondaryLabelColor,
        dynamicColor(lightRGB: 0x26174D, darkRGB: 0xF2EEFF),
        dynamicColor(lightRGB: 0x1A0E38, darkRGB: 0xFFFFFF),
        dynamicColor(lightRGB: 0xFFFFFF, darkRGB: 0xFFFFFF),
        dynamicColor(lightRGB: 0xFFFFFF, darkRGB: 0x140A2E),
    ]

    /// 品牌紫动态色，用于月历「今天」弱色阶描边与标签，与热力色系保持一致。
    private static let brandAccent = dynamicColor(lightRGB: 0x6F45D8, darkRGB: 0xA88CFF)

    private static func dynamicColor(lightRGB: UInt32, lightAlpha: CGFloat = 1,
                                     darkRGB: UInt32, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let rgb = isDark ? darkRGB : lightRGB
            let alpha = isDark ? darkAlpha : lightAlpha
            return NSColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255,
                           green: CGFloat(rgb >> 8 & 0xFF) / 255,
                           blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
        }
    }

    static func color(_ level: Int) -> NSColor {
        levelColors[max(0, min(4, level))]
    }
    private static func tileDayColor(_ level: Int) -> NSColor {
        tileDayColors[max(0, min(4, level))]
    }
    private static func tileValueColor(_ level: Int) -> NSColor {
        tileValueColors[max(0, min(4, level))]
    }
    static func hourLabel(_ date: Date, short: Bool) -> String {
        let parts = Calendar.current.dateComponents([.month, .day, .hour], from: date)
        let hour = parts.hour ?? 0
        let range = String(format: "%02d:00–%02d:00", hour, (hour + 1) % 24)
        return short ? String(format: "%d/%d ", parts.month ?? 1, parts.day ?? 1) + String(format: "%02d:00", hour) : range
    }
    static func label(_ day: UsageHeatmap.Day, unit: UsageHeatmap.Unit, locale: Locale) -> String {
        day.date.formatted(.dateTime.year().month().day().weekday(.abbreviated).locale(locale))
            + (unit == .hour ? " " + hourLabel(day.date, short: false) : "")
            + " · " + day.tokens.formatted(.number.locale(locale)) + " Token"
    }
    func update(_ newChart: UsageHeatmap, yi: Bool = false, locale: Locale) {
        guard chart?.id != newChart.id || self.yi != yi || self.locale != locale else { return }
        let chartChanged = chart?.id != newChart.id
        chart = newChart; self.yi = yi; self.locale = locale
        if chartChanged {
            hoverToken.unregister()
            hovered = nil; selected = nil
        }
        rebuildLabelCaches(for: newChart, locale: locale)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.text("Token 用量热力图"))
        setAccessibilityHelp(L10n.text("悬停或点选格子查看明细；聚焦后可用方向键浏览。"))
        if chartChanged { setAccessibilityValue(L10n.text("请选择一个格子")) }
        needsDisplay = true
    }

    private func rebuildLabelCaches(for chart: UsageHeatmap, locale: Locale) {
        let cal = Calendar.current
        if chart.style == .hourly {
            cachedMonthLabels = []
            cachedRowLabels = chart.rowDays.map { day in
                let parts = cal.dateComponents([.month, .day], from: day)
                return String(format: "%d/%d", parts.month ?? 1, parts.day ?? 1) as NSString
            }
        } else if chart.style == .yearly {
            cachedRowLabels = []
            var months: [(index: Int, text: NSString)] = []
            for i in chart.cells.indices {
                guard let day = chart.cells[i], cal.component(.day, from: day.date) == 1 else { continue }
                let label = UIFormat.localizedDate(day.date, template: "MMM", locale: locale) as NSString
                months.append((i, label))
            }
            cachedMonthLabels = months
        } else {
            cachedMonthLabels = []
            cachedRowLabels = []
        }
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
        if chart.style == .monthCalendar {
            drawMonthCalendar(chart, layout: layout, dirtyRect: dirtyRect)
            return
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        let yearAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.labelColor]
        func drawLeft(_ string: NSString, row: Int, top: CGFloat) {
            let size = string.size(withAttributes: attrs)
            let y = top + CGFloat(row) * layout.rowPitch + (layout.cellHeight - size.height) / 2
            guard y + size.height >= dirtyRect.minY - 2 && y <= dirtyRect.maxY + 2 else { return }
            string.draw(at: NSPoint(x: 0, y: y), withAttributes: attrs)
        }
        let radius = min(3, layout.cellHeight / 4, layout.cellWidth / 4)
        if chart.style == .hourly {
            if dirtyRect.minY <= layout.headerHeight + 2 {
                for hour in stride(from: 0, to: 24, by: 3) {
                    (String(hour) as NSString).draw(at: NSPoint(x: layout.left + CGFloat(hour) * (layout.cellWidth + layout.gap), y: 1), withAttributes: attrs)
                }
            }
            if dirtyRect.minX <= layout.left + 2 {
                for (row, label) in cachedRowLabels.enumerated() {
                    drawLeft(label, row: row, top: layout.top(of: 0))
                }
            }
        } else {
            let weekLabels: [L10n.Template] = ["一", "", "三", "", "五", "", ""]
            for band in chart.bands.indices {
                let top = layout.top(of: band)
                let bandTop = top - layout.headerHeight
                guard bandTop <= dirtyRect.maxY + 2 && top + 7 * layout.rowPitch >= dirtyRect.minY - 2 else { continue }
                if chart.bands.count > 1 {
                    (String(chart.bands[band].year) as NSString).draw(at: NSPoint(x: 0, y: bandTop), withAttributes: yearAttrs)
                }
                if dirtyRect.minX <= layout.left + 2 {
                    for row in 0..<7 where !weekLabels[row].key.isEmpty {
                        drawLeft(L10n.text(weekLabels[row]) as NSString, row: row, top: top)
                    }
                }
            }
            var lastLabel = (y: CGFloat(-1), end: CGFloat(0))
            for entry in cachedMonthLabels {
                let rect = layout.rect(entry.index)
                let y = rect.minY - CGFloat(entry.index % 7) * layout.rowPitch - layout.headerHeight + 1
                if lastLabel.y != y || rect.minX >= lastLabel.end {
                    let w = entry.text.size(withAttributes: attrs).width
                    if y + layout.headerHeight >= dirtyRect.minY - 2 && y <= dirtyRect.maxY + 2 {
                        entry.text.draw(at: NSPoint(x: rect.minX, y: y), withAttributes: attrs)
                    }
                    lastLabel = (y, rect.minX + w + 4)
                }
            }
        }

        let currentHour = chart.style == .hourly ? Calendar.current.dateInterval(of: .hour, for: chart.now)?.start : nil
        let expandedDirty = dirtyRect.insetBy(dx: -3, dy: -3)

        // 批量合并同色阶格子路径，将数百次 NSBezierPath 分配与动态色解析压为 ≤11 次 CGContext 填充。
        let fillPaths = (0..<5).map { _ in CGMutablePath() }
        let dimmedPaths = (0..<5).map { _ in CGMutablePath() }
        let placeholderPath = CGMutablePath()
        var focusRect: CGRect?
        var nowRect: CGRect?

        for i in chart.cells.indices {
            let rect = layout.rect(i)
            guard rect.intersects(expandedDirty) else { continue }
            guard let day = chart.cells[i] else {
                if chart.style == .hourly {
                    placeholderPath.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
                }
                continue
            }
            let level = chart.level(for: day.tokens)
            let bucket = chart.contains(day) ? fillPaths[level] : dimmedPaths[level]
            bucket.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
            let isNow = chart.style == .hourly ? day.date == currentHour : day.date == chart.today
            if focusIndex == i {
                focusRect = rect
            } else if isNow {
                nowRect = rect
            }
        }

        if let cg = NSGraphicsContext.current?.cgContext {
            if !placeholderPath.isEmpty {
                cg.setFillColor(NSColor.labelColor.withAlphaComponent(0.04).cgColor)
                cg.addPath(placeholderPath)
                cg.fillPath()
            }
            for level in 0..<5 {
                let hasMain = !fillPaths[level].isEmpty
                let hasDim = !dimmedPaths[level].isEmpty
                guard hasMain || hasDim else { continue }
                let nsColor = Self.color(level)
                if hasMain {
                    cg.setFillColor(nsColor.cgColor)
                    cg.addPath(fillPaths[level])
                    cg.fillPath()
                }
                if hasDim {
                    cg.setFillColor(nsColor.withAlphaComponent(0.28).cgColor)
                    cg.addPath(dimmedPaths[level])
                    cg.fillPath()
                }
            }
            if let rect = nowRect {
                let ring = rect.insetBy(dx: 0.5, dy: 0.5)
                cg.setStrokeColor(NSColor.controlAccentColor.cgColor)
                cg.setLineWidth(1)
                cg.addPath(CGPath(roundedRect: ring, cornerWidth: radius, cornerHeight: radius, transform: nil))
                cg.strokePath()
            }
            if let rect = focusRect {
                cg.setStrokeColor(NSColor.labelColor.cgColor)
                cg.setLineWidth(1.5)
                cg.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                cg.strokePath()
            }
        }
    }

    private func drawMonthCalendar(_ chart: UsageHeatmap, layout: HeatmapGridLayout, dirtyRect: NSRect) {
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let padX: CGFloat = layout.cellWidth >= 76 ? 8 : 6
        let padY: CGFloat = layout.cellHeight >= 48 ? 6 : 5
        let weekdays: [L10n.Template] = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        for col in 0..<7 {
            let x = layout.left + CGFloat(col) * (layout.cellWidth + layout.gap) + padX
            (L10n.text(weekdays[col]) as NSString).draw(at: NSPoint(x: x, y: 2), withAttributes: headerAttrs)
        }
        let tileRadius: CGFloat = 8
        let futureFill = NSColor.labelColor.withAlphaComponent(0.024)
        let futureBorder = NSColor.labelColor.withAlphaComponent(0.065)
        let zeroBorder = NSColor.labelColor.withAlphaComponent(0.04)
        let futureDayAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        for i in chart.cells.indices {
            guard let dayNumber = chart.monthDayNumber(at: i) else { continue }
            let rect = layout.rect(i)
            guard rect.intersects(dirtyRect.insetBy(dx: -4, dy: -4)) else { continue }
            guard let day = chart.cells[i] else {
                // Remaining days of this month after today: subtle pale placeholder tile with muted day number.
                let path = NSBezierPath(roundedRect: rect, xRadius: tileRadius, yRadius: tileRadius)
                futureFill.setFill(); path.fill()
                let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.375, dy: 0.375),
                                          xRadius: tileRadius - 0.375, yRadius: tileRadius - 0.375)
                futureBorder.setStroke(); border.lineWidth = 0.75; border.stroke()
                (String(dayNumber) as NSString).draw(at: NSPoint(x: rect.minX + padX, y: rect.minY + padY),
                                                     withAttributes: futureDayAttrs)
                continue
            }
            let level = chart.level(for: day.tokens)
            let isToday = day.date == chart.today
            let path = NSBezierPath(roundedRect: rect, xRadius: tileRadius, yRadius: tileRadius)
            Self.color(level).setFill(); path.fill()
            if level == 0 {
                let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.375, dy: 0.375),
                                          xRadius: tileRadius - 0.375, yRadius: tileRadius - 0.375)
                zeroBorder.setStroke(); border.lineWidth = 0.75; border.stroke()
            }
            let dayColor = isToday && level == 0 ? Self.brandAccent : Self.tileDayColor(level)
            let dayFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: isToday ? .bold : .medium)
            let dayAttrs: [NSAttributedString.Key: Any] = [.font: dayFont, .foregroundColor: dayColor]
            let dayStr = String(dayNumber) as NSString
            let dayOrigin = NSPoint(x: rect.minX + padX, y: rect.minY + padY)
            dayStr.draw(at: dayOrigin, withAttributes: dayAttrs)
            if isToday {
                let daySize = dayStr.size(withAttributes: dayAttrs)
                let badgeText = L10n.text("今天") as NSString
                let badgeFg = level == 0 ? Self.brandAccent : Self.tileValueColor(level)
                let badgeAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                    .foregroundColor: badgeFg,
                ]
                let badgeSize = badgeText.size(withAttributes: badgeAttrs)
                let pillW = badgeSize.width + 10
                let pillH = badgeSize.height + 2
                let availableW = rect.maxX - padX - (dayOrigin.x + daySize.width + 4)
                if availableW >= pillW {
                    let pillRect = NSRect(x: rect.maxX - padX - pillW,
                                          y: dayOrigin.y + (daySize.height - pillH) / 2,
                                          width: pillW, height: pillH)
                    let pillBg = level == 0
                        ? Self.brandAccent.withAlphaComponent(0.14)
                        : Self.tileValueColor(level).withAlphaComponent(0.18)
                    pillBg.setFill()
                    NSBezierPath(roundedRect: pillRect, xRadius: pillH / 2, yRadius: pillH / 2).fill()
                    badgeText.draw(at: NSPoint(x: pillRect.minX + 5, y: pillRect.minY + 1), withAttributes: badgeAttrs)
                } else {
                    let dotSize: CGFloat = 4.5
                    let dotRect = NSRect(x: dayOrigin.x + daySize.width + 4,
                                         y: dayOrigin.y + (daySize.height - dotSize) / 2,
                                         width: dotSize, height: dotSize)
                    badgeFg.setFill()
                    NSBezierPath(ovalIn: dotRect).fill()
                }
            }
            if day.tokens > 0 {
                let valueStr = UIFormat.compact(day.tokens, yi: yi) as NSString
                let maxW = max(8, rect.width - padX * 2)
                var fontSize: CGFloat = layout.cellWidth >= 78 ? 12 : 10.5
                var valueAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold),
                    .foregroundColor: Self.tileValueColor(level),
                ]
                var valueSize = valueStr.size(withAttributes: valueAttrs)
                if valueSize.width > maxW {
                    fontSize = 9.5
                    valueAttrs[.font] = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
                    valueSize = valueStr.size(withAttributes: valueAttrs)
                }
                let valueY = max(rect.minY + padY + 14, rect.maxY - padY - valueSize.height)
                valueStr.draw(in: NSRect(x: rect.minX + padX, y: valueY, width: maxW, height: valueSize.height),
                              withAttributes: valueAttrs)
            }
            if focusIndex == i {
                let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 0.875, dy: 0.875),
                                        xRadius: tileRadius - 0.875, yRadius: tileRadius - 0.875)
                NSColor.labelColor.withAlphaComponent(0.85).setStroke(); ring.lineWidth = 1.75; ring.stroke()
            } else if isToday {
                let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75),
                                        xRadius: tileRadius - 0.75, yRadius: tileRadius - 0.75)
                let ringColor = level <= 2
                    ? Self.brandAccent.withAlphaComponent(0.85)
                    : Self.tileValueColor(level).withAlphaComponent(0.55)
                ringColor.setStroke(); ring.lineWidth = 1.5; ring.stroke()
            }
        }
        guard layout.summaryWidth > 0 else { return }
        (L10n.text("周合计") as NSString).draw(at: NSPoint(x: layout.summaryX, y: 2), withAttributes: headerAttrs)
        let dividerX = layout.summaryX - HeatmapGridLayout.summaryGap / 2
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: dividerX, y: layout.top(of: 0)))
        divider.line(to: NSPoint(x: dividerX, y: layout.height))
        NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
        divider.lineWidth = 0.75
        divider.stroke()

        let maxWeekTokens = max(chart.monthWeeks.map(\.tokens).max() ?? 0, 1)
        let focusedRow = focusIndex.map { $0 / 7 }
        let weekTotalAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let mutedTotalAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let weekMetaAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let trackFill = NSColor.labelColor.withAlphaComponent(0.065)
        let highlightFill = NSColor.labelColor.withAlphaComponent(0.035)
        for week in chart.monthWeeks {
            guard let sRect = layout.summaryRect(row: week.row),
                  sRect.insetBy(dx: -8, dy: -2).intersects(dirtyRect) else { continue }
            if focusedRow == week.row {
                highlightFill.setFill()
                NSBezierPath(roundedRect: sRect.insetBy(dx: -6, dy: 0), xRadius: tileRadius, yRadius: tileRadius).fill()
            }
            if week.elapsedDays == 0 {
                let dash = "—" as NSString
                let size = dash.size(withAttributes: mutedTotalAttrs)
                dash.draw(at: NSPoint(x: sRect.minX, y: sRect.midY - size.height / 2), withAttributes: mutedTotalAttrs)
                continue
            }
            let totalStr = (week.tokens > 0 ? UIFormat.compact(week.tokens, yi: yi) : "—") as NSString
            let totalAttrs = week.tokens > 0 ? weekTotalAttrs : mutedTotalAttrs
            let totalSize = totalStr.size(withAttributes: totalAttrs)
            let metaStr = L10n.text("\(week.activeDays)/\(week.elapsedDays) 天") as NSString
            let metaSize = metaStr.size(withAttributes: weekMetaAttrs)
            let barHeight: CGFloat = 6
            let innerGap: CGFloat = 6
            let blockHeight = totalSize.height + innerGap + barHeight
            let blockY = sRect.minY + floor((sRect.height - blockHeight) / 2)
            totalStr.draw(at: NSPoint(x: sRect.minX, y: blockY), withAttributes: totalAttrs)
            metaStr.draw(at: NSPoint(x: sRect.maxX - metaSize.width, y: blockY + (totalSize.height - metaSize.height) / 2),
                         withAttributes: weekMetaAttrs)
            let trackRect = NSRect(x: sRect.minX, y: blockY + totalSize.height + innerGap,
                                   width: sRect.width, height: barHeight)
            trackFill.setFill()
            NSBezierPath(roundedRect: trackRect, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
            if week.tokens > 0 {
                let fillWidth = max(barHeight, sRect.width * CGFloat(week.tokens) / CGFloat(maxWeekTokens))
                let fillRect = NSRect(x: trackRect.minX, y: trackRect.minY, width: fillWidth, height: barHeight)
                let weekLevel = week.tokens == maxWeekTokens
                    ? 4
                    : max(2, min(4, Int(ceil(sqrt(Double(week.tokens) / Double(maxWeekTokens)) * 4))))
                Self.color(weekLevel).setFill()
                NSBezierPath(roundedRect: fillRect, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
            }
        }
    }
    private func invalidate(_ index: Int?) {
        guard let chart, let index else { return }
        let layout = HeatmapGridLayout(chart: chart, width: bounds.width)
        setNeedsDisplay(layout.rect(index).insetBy(dx: -2, dy: -2))
        if chart.style == .monthCalendar, let sumRect = layout.summaryRect(row: index / 7) {
            setNeedsDisplay(sumRect.insetBy(dx: -8, dy: -2))
        }
    }
    private func publishFocus(from old: Int?) {
        guard old != focusIndex else { return }
        invalidate(old); invalidate(focusIndex)
        let day = focusIndex.flatMap { chart?.cells[$0] }
        onFocus?(day)
        let value = day.flatMap { d in chart.map { Self.label(d, unit: $0.unit, locale: locale) } }
        setAccessibilityValue(value ?? L10n.text("请选择一个格子"))
        NSAccessibility.post(element: self, notification: .valueChanged)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { hoverToken.unregister() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        guard !ScrollActivity.shared.isScrolling else { return }
        focus(at: convert(event.locationInWindow, from: nil))
        hoverToken.setActive(hovered != nil) { [weak self] in
            guard let self, self.hovered != nil else { return }
            let old = self.focusIndex
            self.hovered = nil
            self.publishFocus(from: old)
        }
    }
    func focus(at point: NSPoint) {
        guard let chart else { return }
        let old = focusIndex
        hovered = HeatmapGridLayout(chart: chart, width: bounds.width).index(at: point)
        publishFocus(from: old)
    }
    override func mouseExited(with event: NSEvent) {
        hoverToken.unregister()
        let old = focusIndex; hovered = nil; publishFocus(from: old)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        focus(at: convert(event.locationInWindow, from: nil))
        selected = hovered
    }
    override func keyDown(with event: NSEvent) {
        guard let chart else { return }
        let old = focusIndex
        if event.keyCode == 53 { hovered = nil; selected = nil; publishFocus(from: old); return }
        let step: Int
        switch (chart.style, event.keyCode) {
        case (.hourly, 123): step = -1
        case (.hourly, 124): step = 1
        case (.hourly, 125): step = 24
        case (.hourly, 126): step = -24
        case (.monthCalendar, 123): step = -1
        case (.monthCalendar, 124): step = 1
        case (.monthCalendar, 125): step = 7
        case (.monthCalendar, 126): step = -7
        case (.yearly, 123): step = -7
        case (.yearly, 124): step = 7
        case (.yearly, 125): step = 1
        case (.yearly, 126): step = -1
        default: super.keyDown(with: event); return
        }
        var candidate = focusIndex.map { $0 + step } ?? (chart.cells.firstIndex { $0 != nil } ?? 0)
        while chart.cells.indices.contains(candidate), chart.cells[candidate] == nil { candidate += step > 0 ? 1 : -1 }
        if chart.cells.indices.contains(candidate) { hovered = nil; selected = candidate; publishFocus(from: old) }
    }
}
