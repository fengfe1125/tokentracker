//
//  LiveQuotaTests.swift
//  TokenTrackerCoreTests
//
//  真机验收（默认跳过）：TT_LIVE=1 时用 TokenTracker 账号库真实查询官方配额，
//  并经 SubscriptionQuotaBridge 转成配额窗口打印。
//
//  运行：TT_LIVE=1 swift test --filter LiveQuotaTests
//

import XCTest
@testable import TokenTrackerCore

final class LiveQuotaTests: XCTestCase {
    func testLiveOfficialQuotas() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TT_LIVE"] == "1",
                          "真机验收：TT_LIVE=1 时才访问真实凭据与官方接口")
        let service = SubscriptionService(cachePath: nil)
        service.discover()
        service.refresh(force: true)
        let cards = service.cards()
        for name in ["claude-oauth", "kimi", "codex", "go"] {
            let result = SubscriptionQuotaBridge.officialResult(name, cards: cards)
            // 只打印结果形态（错误/窗口百分比），不打印任何凭据相关内容
            let pcts = (result?.windows ?? [:]).mapValues { $0.pct }
            print("LIVE \(name): error=\(result?.error ?? "无") stale=\(result?.staleMin.map(String.init) ?? "-") windows=\(pcts)")
        }
    }
}
