import XCTest
import SwiftUI
import AppKit
import TokenTrackerCore
@testable import TokenTrackerApp

final class TrendChartTests: XCTestCase {
    @MainActor
    func testSubscriptionCardsHandleUnboundedHostMeasurement() async {
        let view = NSHostingView(rootView: SubscriptionSection(
            cards: SubscriptionCard.previewCards(), refreshing: false, showsHeading: false))
        let size = view.fittingSize
        XCTAssertTrue(size.width.isFinite)
        XCTAssertTrue(size.height.isFinite)
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }

    func testSmoothTrendStaysBetweenAdjacentSamples() {
        // A sharp peak followed by flat zero used to overshoot both the peak and baseline.
        for values: [CGFloat] in [[15, 60, 65, 0, 0, 1], [0, 0, 100, 0, 0], [0, 20], [5, 5, 5]] {
            let points = values.enumerated().map { CGPoint(x: CGFloat($0.offset) * 50, y: $0.element) }
            var segment = 0
            HandDrawnTrendChart.smoothPath(points).forEach { element in
                guard case let .curve(to: end, control1: c1, control2: c2) = element else { return }
                let start = points[segment]
                XCTAssertEqual(end, points[segment + 1])
                let low = min(start.y, end.y), high = max(start.y, end.y)
                for sample in 0...100 {
                    let t = CGFloat(sample) / 100, u = 1 - t
                    let y = u*u*u*start.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*end.y
                    XCTAssertGreaterThanOrEqual(y, low - 0.000001)
                    XCTAssertLessThanOrEqual(y, high + 0.000001)
                }
                segment += 1
            }
            XCTAssertEqual(segment, points.count - 1)
        }
    }
}
