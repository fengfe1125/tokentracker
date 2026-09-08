//
//  HandDrawnTrendChart.swift
//  TokenTrackerApp
//
//  手绘风使用趋势：Canvas 自绘 Catmull-Rom 平滑曲线 + 确定性抖动笔触
//  （钢笔手绘感），双轴极简坐标（左 tokens / 右成本，无网格线），
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
    let points: [TrendPoint]
    /// 小时粒度（今天）x 标签保留 "HH:00"；天粒度裁成 "MM-dd"
    let isHourly: Bool

    @State private var hoverIndex: Int?
    @State private var hoverLocation: CGPoint = .zero

    /// 系列定义：名称 / 颜色 / 线宽 / 虚线 / 取值
    fileprivate struct Series {
        let name: String
        let color: Color
        let width: CGFloat
        let dashed: Bool
        let value: (TrendPoint) -> Double
    }

    fileprivate static let seriesList: [Series] = [
        Series(name: "缓存命中", color: .purple, width: 2.0, dashed: false, value: \.cacheRead),
        Series(name: "输入", color: .blue, width: 1.6, dashed: false, value: \.input),
        Series(name: "输出", color: .green, width: 1.6, dashed: false, value: \.output),
        Series(name: "缓存创建", color: .orange, width: 1.6, dashed: false, value: \.cacheWrite),
        Series(name: "成本", color: .red, width: 1.4, dashed: true, value: \.cost),
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
                if let hoverIndex {
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
            var area = sketchPath(hitPts, seed: 0xC0FFEE)
            area.addLine(to: CGPoint(x: hitPts.last!.x, y: plot.maxY))
            area.addLine(to: CGPoint(x: hitPts.first!.x, y: plot.maxY))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(
                Gradient(colors: [Color.purple.opacity(0.16), Color.purple.opacity(0.02)]),
                startPoint: CGPoint(x: plot.midX, y: plot.minY),
                endPoint: CGPoint(x: plot.midX, y: plot.maxY)))
        }
        for (i, series) in Self.seriesList.enumerated() {
            let max = series.name == "成本" ? maxCost : maxTokens
            let pts = pointPixels(series.value, max: max, plot: plot)
            guard pts.count > 1 else { continue }
            let path = sketchPath(pts, seed: UInt64(0x5EED) &+ UInt64(i) &* 7919)
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
        guard let hoverIndex else { return }
        let x = xPosition(hoverIndex, plot: plot)
        var guide = Path()
        guide.move(to: CGPoint(x: x, y: plot.minY))
        guide.addLine(to: CGPoint(x: x, y: plot.maxY))
        ctx.stroke(guide, with: .color(.secondary.opacity(0.45)),
                   style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        for series in Self.seriesList {
            let max = series.name == "成本" ? maxCost : maxTokens
            let y = yPosition(series.value(points[hoverIndex]), max: max, plot: plot)
            let dot = Path(ellipseIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6))
            ctx.fill(dot, with: .color(series.color))
            ctx.stroke(dot, with: .color(Color(nsColor: .windowBackgroundColor)), lineWidth: 1.2)
        }
    }

    // -------------------------------------------------------- 手绘笔触 ----

    /// Catmull-Rom 每段采样 8 点 + 确定性双 sin 抖动（振幅约 1.2pt），
    /// 同一条线每次渲染抖动一致（seed 固定），不会闪烁。
    private func sketchPath(_ pts: [CGPoint], seed: UInt64) -> Path {
        var path = Path()
        guard let first = pts.first, pts.count > 1 else { return path }
        var samples: [CGPoint] = []
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = pts[min(i + 2, pts.count - 1)]
            for s in 0..<8 {
                samples.append(catmullRom(p0, p1, p2, p3, Double(s) / 8))
            }
        }
        samples.append(pts[pts.count - 1])

        let phase1 = hash01(seed, 1) * 2 * .pi
        let phase2 = hash01(seed, 2) * 2 * .pi
        let total = Double(max(samples.count - 1, 1))
        path.move(to: samples[0])
        for (index, p) in samples.enumerated() {
            let t = Double(index) / total * 6 * .pi   // 全图约 3 个抖动周期
            let wobble = sin(t * 1.0 + phase1) * 0.7 + sin(t * 2.3 + phase2) * 0.5
            path.addLine(to: CGPoint(x: p.x, y: p.y + CGFloat(wobble)))
        }
        _ = first
        return path
    }

    private func catmullRom(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint,
                            _ t: Double) -> CGPoint {
        let t2 = t * t, t3 = t2 * t
        func cr(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
            0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2
                   + (-a + 3 * b - 3 * c + d) * t3)
        }
        return CGPoint(x: cr(Double(p0.x), Double(p1.x), Double(p2.x), Double(p3.x)),
                       y: cr(Double(p0.y), Double(p1.y), Double(p2.y), Double(p3.y)))
    }

    /// splitmix64 尾混合 → [0,1)；给抖动取相位用
    private func hash01(_ seed: UInt64, _ salt: UInt64) -> Double {
        var z = seed &+ 0x9E37_79B9_7F4A_7C15 &* (salt &+ 1)
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
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
                    Text(series.name == "成本"
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
