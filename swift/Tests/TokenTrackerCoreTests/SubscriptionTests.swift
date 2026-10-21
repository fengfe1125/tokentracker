import XCTest
@testable import TokenTrackerCore

final class SubscriptionTests: XCTestCase {
    func testDeepSeekBalanceParsesStringAmountsAndKeepsZero() {
        let service = DeepSeekBalance { _,_,_,_ in
            (200, ["is_available": true, "balance_infos": [["currency":"CNY", "total_balance":"0.00", "granted_balance":"0", "topped_up_balance":"0.00"]]])
        }
        let result = service.fetch(key: "test")
        XCTAssertEqual(result.status, .current)
        XCTAssertEqual(result.balances.first?.total, Decimal(string: "0.00"))
    }

    func testDeepSeekRejectsMalformedAmountInsteadOfZero() {
        let service = DeepSeekBalance { _,_,_,_ in
            (200, ["balance_infos": [["currency":"USD", "total_balance":"unknown"]]])
        }
        let result = service.fetch(key: "test")
        XCTAssertNil(result.balances.first?.total)
    }

    func testDiscoveryUsesExplicitEnvironmentAndDoesNotExecuteConfig() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = ["DEEPSEEK_API_KEY": "sk-test"]
        let accounts = SubscriptionDiscovery(home: dir.path, env: env, keychainRead: { nil }).discover()
        XCTAssertEqual(accounts.filter { $0.provider == "deepseek" }.count, 1)
        XCTAssertEqual(accounts.first?.credential["key"], "sk-test")
    }

    func testDiscoveryDeduplicatesSameCredentialAcrossKnownSources() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".local/share/opencode"), withIntermediateDirectories: true)
        let data: [String:Any] = ["opencode-go": ["key":"same-key"]]
        try JSONSerialization.data(withJSONObject: data).write(to: dir.appendingPathComponent(".local/share/opencode/auth.json"))
        defer { try? FileManager.default.removeItem(at: dir) }
        let accounts = SubscriptionDiscovery(home: dir.path, env: [:], keychainRead: { nil }).discover()
        XCTAssertEqual(accounts.filter { $0.provider == "go" }.count, 1)
    }
}
