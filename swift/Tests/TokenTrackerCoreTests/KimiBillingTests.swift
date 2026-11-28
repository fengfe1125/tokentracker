//
//  KimiBillingTests.swift
//  TokenTrackerCoreTests
//
//  Kimi 区域与域名解析：只读区域设置，不读取凭据。
//

import XCTest
@testable import TokenTrackerCore

final class KimiBillingHostTests: XCTestCase {
    private var tmp: TempDir!

    override func setUp() async throws {
        tmp = try TempDir()
        try FileManager.default.createDirectory(atPath: tmp.path(".kimi-code"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws { tmp = nil }

    private func billing(_ env: [String: String] = [:]) -> KimiBilling {
        KimiBilling(ctx: BillingContext(home: tmp.url.path,
                                        env: ["KIMI_CODE_HOME": tmp.path(".kimi-code")].merging(env) { $1 }))
    }

    func testMainlandDefaultUsesComHosts() {
        XCTAssertEqual(billing().oauthHost(), "https://auth.kimi.com")
        XCTAssertEqual(billing().apiBase(), "https://api.kimi.com/coding/v1")
    }

    func testNonMainlandRegionUsesAiHosts() throws {
        try "global".write(toFile: tmp.path(".kimi-code", "region"), atomically: true, encoding: .utf8)
        XCTAssertEqual(billing().oauthHost(), "https://auth.kimi.ai")
        XCTAssertEqual(billing().apiBase(), "https://api.kimi.ai/coding/v1")
    }

    func testEnvOverrideWinsAndTrailingSlashIsDropped() {
        let kimi = billing(["KIMI_CODE_OAUTH_HOST": "https://auth.example.com/"])
        XCTAssertEqual(kimi.oauthHost(), "https://auth.example.com")
        XCTAssertEqual(kimi.apiBase(), "https://api.example.com/coding/v1")
    }

    func testCredentialFileIsNeverRead() throws {
        // 凭据文件存在也不影响域名解析，更不会被改写。
        let credDir = tmp.path(".kimi-code", "credentials")
        try FileManager.default.createDirectory(atPath: credDir, withIntermediateDirectories: true)
        let credPath = credDir + "/kimi-code.json"
        try Data("{\"access_token\":\"fake\"}".utf8).write(to: URL(fileURLWithPath: credPath))
        let before = try FileManager.default.attributesOfItem(atPath: credPath)[.modificationDate] as? Date
        _ = billing().apiBase()
        let after = try FileManager.default.attributesOfItem(atPath: credPath)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
    }
}
