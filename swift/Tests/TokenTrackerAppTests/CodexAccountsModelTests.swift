import Combine
import XCTest
@testable import TokenTrackerApp
@testable import TokenTrackerCore

@MainActor
final class CodexAccountsModelTests: XCTestCase {
    func testReloadReportsActiveAccountAndCaptureWithoutLoginExplainsWhy() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        // 虚构的空目录：没有 auth.json，也不会碰真实登录态
        let model = CodexAccountsModel(switcher: CodexAccountSwitcher(
            ctx: BillingContext(home: home, env: ["CODEX_HOME": home + "/.codex"])))
        var reported: [String?] = []
        var switched = 0
        model.onActiveChanged = { reported.append($0) }
        model.onSwitched = { switched += 1 }

        let loaded = expectation(description: "active account reported")
        var subscription = model.$activeID.dropFirst().sink { _ in loaded.fulfill() }
        model.reload()
        await fulfillment(of: [loaded], timeout: 3)
        subscription.cancel()
        XCTAssertTrue(model.accounts.isEmpty)
        XCTAssertEqual(reported.count, 1)
        XCTAssertNil(reported[0])
        XCTAssertNil(model.message)

        let failed = expectation(description: "capture failure surfaced")
        subscription = model.objectWillChange.sink { _ in
            DispatchQueue.main.async { if model.message != nil { failed.fulfill() } }
        }
        model.captureCurrent(name: "")
        await fulfillment(of: [failed], timeout: 3)
        subscription.cancel()
        XCTAssertTrue(model.accounts.isEmpty)
        XCTAssertEqual(switched, 0)
    }
}
