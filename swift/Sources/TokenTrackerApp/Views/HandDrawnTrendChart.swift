//
//  HandDrawnTrendChart.swift
//  TokenTrackerApp
//
//  使用趋势：Canvas 使用保形单调插值绘制平滑曲线，
//  双轴极简坐标（左 tokens / 右成本，无网格线），
//  鼠标悬停画竖向参考线 + 各曲线圆点并浮出数值卡。
//

import SwiftUI

/// 每个时间桶跨工具聚合后的用量点
struct TrendPoint: Identifiable, Equatable {
    let id: String
    let day: String
    let input: Double, output: Double
    let cacheRead: Double, cacheWrite: Double
    let cost: Double
}

struct HandDrawnTrendChart: View {
    @ObservedObject private var language = LanguageManager.shared
    let points: [TrendPoint]
    /// 小时粒度（今天）x 标签保留 "HH:00"；天粒度裁成 "MM-dd"
    let isHourly: Bool

    @State private var hoverIndex: Int?
    @State private var hoverLocation: CGPoint = .zero

    /// 系列定义：名称 / 颜色 / 线宽 / 虚线 / 取值
    fileprivate struct Series {
        let title: L10n.Template
        var name: String { L10n.text(title) }
        var isCost: Bool { title.key == "成本" }
        let color: Color
        let width: CGFloat
        let dashed: Bool
        let value: (TrendPoint) -> Double
    }

    fileprivate static let seriesList: [Series] = [
        Series(title: "缓存命中", color: .purple, width: 2.0, dashed: false, value: \.cacheRead),
        Series(title: "非缓存输入", color: .blue, width: 1.6, dashed: false, value: \.input),
        Series(title: "输出", color: .green, width: 1.6, dashed: false, value: \.output),
        Series(title: "缓存创建", color: .orange, width: 1.6, dashed: false, value: \.cacheWrite),
        Series(title: "成本", color: .red, width: 1.4, dashed: true, value: \.cost),
    ]

    private var maxTokens: Double {
        max(points.flatMap { [$0.input, $0.output, $0.cacheRead, $0.cacheWrite] }.max() ?? 0, 1)
    }
    private var maxCost: Double {
        max(points.map(\.cost).max() ?? 0, 0.0001)
    }

    var body: some View {
        GeometryReader { geo in
            let plot = plotRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    drawAxes(ctx: &ctx, plot: plot)
                    drawSeries(ctx: &ctx, plot: plot)
                    drawHover(ctx: &ctx, plot: plot)
                }
                if let hoverIndex, points.indices.contains(hoverIndex) {
                    tooltip(for: points[hoverIndex], in: geo.size)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let loc):
                    hoverLocation = loc
                    hoverIndex = nearestIndex(x: loc.x, plot: plot)
                case .ended:
                    hoverIndex = nil
                }
            }
        }
        .frame(height: 220)
        .onChange(of: points) { _, _ in hoverIndex = nil }
    }

    // ------------------------------------------------------------ 布局 ----

    /// plot 区：leading 40（tokens 刻度）/ trailing 44（成本刻度）/ bottom 18（x 标签）
    private func plotRect(in size: CGSize) -> CGRect {
        CGRect(x: 40, y: 8,
               width: max(size.width - 40 - 44, 10),
               height: max(size.height - 8 - 18, 10))
    }

    private func xPosition(_ index: Int, plot: CGRect) -> CGFloat {
        guard points.count > 1 else { return plot.midX }
        return plot.minX + plot.width * CGFloat(index) / CGFloat(points.count - 1)
    }

    private func yPosition(_ v: Double, max: Double, plot: CGRect) -> CGFloat {
        plot.maxY - plot.height * CGFloat(v / max)
    }

    private func nearestIndex(x: CGFloat, plot: CGRect) -> Int? {
        guard !points.isEmpty, x >= plot.minX - 12, x <= plot.maxX + 12 else { return nil }
        guard points.count > 1 else { return 0 }
        let frac = (x - plot.minX) / plot.width
        return max(0, min(points.count - 1, Int((frac * CGFloat(points.count - 1)).rounded())))
    }

    // ------------------------------------------------------------ 绘制 ----

    private func drawAxes(ctx: inout GraphicsContext, plot: CGRect) {
        // 极简：仅底部一条淡基线，无网格
        var base = Path()
        base.move(to: CGPoint(x: plot.minX, y: plot.maxY))
        base.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        ctx.stroke(base, with: .color(.primary.opacity(0.12)), lineWidth: 1)

        // 左轴 3 档 tokens 刻度
        for (i, frac) in [0.0, 0.5, 1.0].enumerated() {
            let y = plot.maxY - plot.height * CGFloat(frac)
            let label = i == 0 ? "0" : compactTokens(maxTokens * frac)
            ctx.draw(Text(label).font(.caption2).foregroundStyle(.secondary),
                     at: CGPoint(x: plot.minX - 6, y: y), anchor: .trailing)
        }
        // 右轴 3 档成本刻度
        for (i, frac) in [0.0, 0.5, 1.0].enumerated() {
            let y = plot.maxY - plot.height * CGFloat(frac)
            let label = i == 0 ? "$0" : UIFormat.cost(maxCost * frac)
            ctx.draw(Text(label).font(.caption2).foregroundStyle(.secondary),
                     at: CGPoint(x: plot.maxX + 6, y: y), anchor: .leading)
        }
        // x 轴均分最多 5 个桶标签
        for index in xLabelIndices {
            let raw = points[index].day
            let label = isHourly ? raw : String(raw.suffix(5))
            ctx.draw(Text(label).font(.caption2).foregroundStyle(.secondary),
                     at: CGPoint(x: xPosition(index, plot: plot), y: plot.maxY + 10),
                     anchor: .center)
        }
    }

    private var xLabelIndices: [Int] {
        let n = points.count
        guard n > 5 else { return Array(0..<n) }
        return (0..<5).map { $0 * (n - 1) / 4 }
    }

    private func drawSeries(ctx: inout GraphicsContext, plot: CGRect) {
        // 缓存命中：先铺渐变面积，再描主线
        let hitPts = pointPixels(\.cacheRead, max: maxTokens, plot: plot)
        if hitPts.count > 1 {
            var area = Self.smoothPath(hitPts)
            area.addLine(to: CGPoint(x: hitPts.last!.x, y: plot.maxY))
            area.addLine(to: CGPoint(x: hitPts.first!.x, y: plot.maxY))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(
                Gradient(colors: [Color.purple.opacity(0.16), Color.purple.opacity(0.02)]),
                startPoint: CGPoint(x: plot.midX, y: plot.minY),
                endPoint: CGPoint(x: plot.midX, y: plot.maxY)))
        }
        for series in Self.seriesList {
            let max = series.isCost ? maxCost : maxTokens
            let pts = pointPixels(series.value, max: max, plot: plot)
            guard pts.count > 1 else { continue }
            let path = Self.smoothPath(pts)
            let style = StrokeStyle(lineWidth: series.width, lineCap: .round,
                                    lineJoin: .round, dash: series.dashed ? [5, 4] : [])
            ctx.stroke(path, with: .color(series.color.opacity(series.dashed ? 0.85 : 0.9)),
                       style: style)
        }
    }

    private func pointPixels(_ value: (TrendPoint) -> Double, max: Double,
                             plot: CGRect) -> [CGPoint] {
        points.enumerated().map { index, point in
            CGPoint(x: xPosition(index, plot: plot),
                    y: yPosition(value(point), max: max, plot: plot))
        }
    }

    /// 悬停：竖向虚线参考线 + 各曲线圆点
    private func drawHover(ctx: inout GraphicsContext, plot: CGRect) {
        guard let hoverIndex, points.indices.contains(hoverIndex) else { return }
        let x = xPosition(hoverIndex, plot: plot)
        var guide = Path()
        guide.move(to: CGPoint(x: x, y: plot.minY))
        guide.addLine(to: CGPoint(x: x, y: plot.maxY))
        ctx.stroke(guide, with: .color(.secondary.opacity(0.45)),
                   style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        for series in Self.seriesList {
            let max = series.isCost ? maxCost : maxTokens
            let y = yPosition(series.value(points[hoverIndex]), max: max, plot: plot)
            let dot = Path(ellipseIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6))
            ctx.fill(dot, with: .color(series.color))
            ctx.stroke(dot, with: .color(Color(nsColor: .windowBackgroundColor)), lineWidth: 1.2)
        }
    }

    /// 保形三次 Hermite 插值：相邻斜率反向或为零时，切线置零；
    /// 其余取加权调和平均，避免峰值过冲和在零值附近产生负用量。
    nonisolated static func smoothPath(_ pts: [CGPoint]) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: first)
        guard pts.count > 1 else { return path }
        let widths = zip(pts, pts.dropFirst()).map { $1.x - $0.x }
        let slopes = zip(pts, pts.dropFirst()).enumerated().map { index, pair in
            (pair.1.y - pair.0.y) / widths[index]
        }
        var tangents = [CGFloat](repeating: 0, count: pts.count)
        tangents[0] = slopes[0]
        tangents[pts.count - 1] = slopes[slopes.count - 1]
        if pts.count > 2 {
            for i in 1..<(pts.count - 1) {
                let before = slopes[i - 1], after = slopes[i]
                guard (before > 0 && after > 0) || (before < 0 && after < 0) else { continue }
                let w1 = 2 * widths[i] + widths[i - 1]
                let w2 = widths[i] + 2 * widths[i - 1]
                tangents[i] = (w1 + w2) / (w1 / before + w2 / after)
            }
        }
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1], third = widths[i] / 3
            path.addCurve(to: b,
                          control1: CGPoint(x: a.x + third, y: a.y + tangents[i] * third),
                          control2: CGPoint(x: b.x - third, y: b.y - tangents[i + 1] * third))
        }
        return path
    }

    // ------------------------------------------------------------ 浮卡 ----

    private func tooltip(for point: TrendPoint, in size: CGSize) -> some View {
        let cardWidth: CGFloat = 158
        let cardHeight: CGFloat = 118
        let tx = min(max(hoverLocation.x + 14, 4), max(size.width - cardWidth - 4, 4))
        let ty = min(max(hoverLocation.y - cardHeight - 10, 4),
                     max(size.height - cardHeight - 4, 4))
        return VStack(alignment: .leading, spacing: 4) {
            Text(isHourly ? point.day : String(point.day.suffix(5)))
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(Self.seriesList, id: \.name) { series in
                HStack(spacing: 5) {
                    Circle().fill(series.color).frame(width: 6, height: 6)
                    Text(series.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(series.isCost
                         ? UIFormat.costPrecise(series.value(point))
                         : UIFormat.tokens(Int64(series.value(point)), yi: false))
                        .font(.caption2.monospacedDigit())
                }
            }
        }
        .padding(8)
        .frame(width: cardWidth, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .offset(x: tx, y: ty)
        .allowsHitTesting(false)
    }

    /// 坐标轴 tokens 紧凑格式：1.2M / 650K / 800
    private func compactTokens(_ v: Double) -> String {
        if v >= 1e6 { return String(format: "%.1fM", v / 1e6) }
        if v >= 1e3 { return String(format: "%.0fK", v / 1e3) }
        return String(Int(v.rounded()))
    }
}
