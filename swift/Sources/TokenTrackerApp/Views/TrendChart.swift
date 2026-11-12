//
//  TrendChart.swift
//  TokenTrackerApp
//
//  使用趋势：每个时间桶一根堆叠柱（Token 四类），成本折线走右轴。
//  桶是离散的小时 / 天，柱形不在两个桶之间虚构过渡值。
//  悬停显示该桶的合计、四类明细与成本。
//

import Charts
import SwiftUI

/// 每个时间桶跨工具聚合后的用量点
struct TrendPoint: Identifiable, Equatable {
    let id: String
    let day: String
    let input: Double, output: Double
    let cacheRead: Double, cacheWrite: Double
    let cost: Double

    var tokens: Double { input + output + cacheRead + cacheWrite }

    func value(_ kind: TokenKind) -> Double {
        switch kind {
        case .cacheRead: cacheRead
        case .input: input
        case .cacheWrite: cacheWrite
        case .output: output
        }
    }
}

/// 坐标轴取整与刻度文字（纯函数，便于测试）。
enum TrendScale {
    /// 向上取到 4 等分后仍是整齐数字的上限。
    static func niceCeiling(_ value: Double) -> Double {
        guard value > 0, value.isFinite else { return 1 }
        let magnitude = pow(10, floor(log10(value)))
        let steps: [Double] = [1, 1.2, 1.6, 2, 2.4, 3.2, 4, 6, 8, 10]
        let normalized = value / magnitude
        let step = steps.first { $0 >= normalized - 1e-9 } ?? 10
        return step * magnitude
    }

    static func ticks(top: Double) -> [Double] {
        (0...4).map { top * Double($0) / 4 }
    }

    /// 轴上的 Token 刻度：中文开启「亿」时用 万 / 亿，其余用 K / M / B；去掉多余的 0。
    static func tokenLabel(_ value: Double, yi: Bool) -> String {
        func trimmed(_ x: Double) -> String {
            let text = String(format: "%.1f", x)
            return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
        }
        if value <= 0 { return "0" }
        if yi && !L10n.isEnglish {
            if value >= 1e8 { return trimmed(value / 1e8) + "亿" }
            if value >= 1e4 { return trimmed(value / 1e4) + "万" }
            return trimmed(value)
        }
        if value >= 1e9 { return trimmed(value / 1e9) + "B" }
        if value >= 1e6 { return trimmed(value / 1e6) + "M" }
        if value >= 1e3 { return trimmed(value / 1e3) + "K" }
        return trimmed(value)
    }

    static func costLabel(_ value: Double) -> String {
        value <= 0 ? "$0" : String(format: "$%g", value)
    }
}

struct TrendChart: View {
    @ObservedObject private var language = LanguageManager.shared
    let points: [TrendPoint]
    /// 小时粒度（今天）x 标签保留 "HH:00"；天粒度裁成 "MM-dd"
    let isHourly: Bool
    let yi: Bool

    @State private var hoverID: String?
    @State private var hoverLocation: CGPoint = .zero

    private struct Segment: Identifiable {
        let id: String
        let bucket: String
        let kind: TokenKind
        let value: Double
    }

    private var segments: [Segment] {
        points.flatMap { point in
            TokenKind.allCases.map {
                Segment(id: "\(point.id)|\($0.rawValue)", bucket: point.id,
                        kind: $0, value: point.value($0))
            }
        }
    }

    private var tokenTop: Double { TrendScale.niceCeiling(points.map(\.tokens).max() ?? 0) }
    private var costTop: Double { TrendScale.niceCeiling(points.map(\.cost).max() ?? 0) }
    private var hasCost: Bool { points.contains { $0.cost > 0 } }

    private func label(_ bucket: String) -> String {
        isHourly ? bucket : String(bucket.suffix(5))
    }

    /// x 轴：8 个桶以内全部标注，更多时均分 6 个，避免挤成一片。
    private var axisBuckets: [String] {
        let n = points.count
        guard n > 8 else { return points.map(\.id) }
        return (0..<6).map { points[$0 * (n - 1) / 5].id }
    }

    var body: some View {
        let top = tokenTop, costTop = costTop
        Chart {
            ForEach(segments) { segment in
                BarMark(x: .value("bucket", segment.bucket),
                        y: .value("tokens", segment.value),
                        width: .ratio(0.62))
                    .foregroundStyle(segment.kind.color.opacity(
                        hoverID == nil || hoverID == segment.bucket ? 0.9 : 0.45))
            }
            if hasCost {
                ForEach(points) { point in
                    LineMark(x: .value("bucket", point.id),
                             y: .value("cost", point.cost / costTop * top),
                             series: .value("series", "cost"))
                        .foregroundStyle(Color.costSeries)
                        .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    if points.count <= 31 {
                        PointMark(x: .value("bucket", point.id),
                                  y: .value("cost", point.cost / costTop * top))
                            .foregroundStyle(Color.costSeries)
                            .symbolSize(hoverID == point.id ? 46 : 18)
                    }
                }
            }
        }
        .chartYScale(domain: 0...top)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: axisBuckets) { value in
                AxisValueLabel {
                    if let bucket = value.as(String.self) {
                        Text(label(bucket)).font(.caption2)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: TrendScale.ticks(top: top)) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(TrendScale.tokenLabel(v, yi: yi)).font(.caption2)
                    }
                }
            }
            if hasCost {
                AxisMarks(position: .trailing, values: TrendScale.ticks(top: top)) { value in
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(TrendScale.costLabel(v / top * costTop))
                                .font(.caption2)
                                .foregroundStyle(Color.costSeries)
                        }
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let frame = proxy.plotFrame.map({ geo[$0] }) else { return }
                                hoverLocation = location
                                hoverID = proxy.value(atX: location.x - frame.origin.x,
                                                      as: String.self)
                            case .ended:
                                hoverID = nil
                            }
                        }
                    if let hoverID, let point = points.first(where: { $0.id == hoverID }) {
                        tooltip(for: point, in: geo.size)
                    }
                }
            }
        }
        .frame(height: 220)
        .onChange(of: points) { _, _ in hoverID = nil }
    }

    // ------------------------------------------------------------ 浮卡 ----

    private func tooltip(for point: TrendPoint, in size: CGSize) -> some View {
        let cardWidth: CGFloat = 176
        let cardHeight: CGFloat = 138
        let x = min(max(hoverLocation.x + 14, 4), max(size.width - cardWidth - 4, 4))
        let y = min(max(hoverLocation.y - cardHeight - 10, 4),
                    max(size.height - cardHeight - 4, 4))
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label(point.id))
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 8)
                Text(UIFormat.compact(Int64(point.tokens), yi: yi))
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
            Divider()
            ForEach(TokenKind.allCases) { kind in
                tooltipRow(kind.title, color: kind.color,
                           value: UIFormat.compact(Int64(point.value(kind)), yi: yi))
            }
            tooltipRow(L10n.text("成本"), color: .costSeries,
                       value: UIFormat.costPrecise(point.cost))
        }
        .padding(9)
        .frame(width: cardWidth, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.cardBorder))
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        .offset(x: x, y: y)
        .allowsHitTesting(false)
    }

    private func tooltipRow(_ name: String, color: Color, value: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(name).font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.caption2.monospacedDigit())
        }
    }
}
