//
//  LiveQuotaTests.swift
//  TokenTrackerCoreTests
//
//  真机验收（默认跳过）：TT_LIVE=1 时真实抓取四家官方配额并打印，
//  用于与 Python 版 `./tt quotas` 对比（Phase 3 验收项）。
//
//  运行：TT_LIVE=1 swift test --filter LiveQuotaTests
//

import XCTest
@testable import TokenTrackerCore

final class LiveQuotaTests: XCTestCase {
    func testLiveOfficialQuotas() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TT_LIVE"] == "1",
                          "真机验收：TT_LIVE=1 时才访问真实凭据与官方接口")
        let service = OfficialQuotaService()
        for name in ["claude-oauth", "kimi", "codex", "go"] {
            let result = service.cached(name, force: true)
            // 只打印结果形态（错误/窗口数/百分比），不打印任何凭据相关内容
            let windows = result["windows"] as? [String: Any] ?? [:]
            let pcts = windows.mapValues { ($0 as? [String: Any])?["pct"] }
            print("LIVE \(name): error=\(result["error"] ?? "无") via=\(result["_via"] ?? "-") "
                  + "stale=\(result["_stale_min"] ?? "-") windows=\(pcts)")
        }
    }
}
