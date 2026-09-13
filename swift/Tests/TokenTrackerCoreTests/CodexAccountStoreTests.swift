//
//  CodexAccountStoreTests.swift
//  TokenTrackerCoreTests
//
//  账号库持久化：save/load round-trip、按 account_id upsert 去重（保留首次
//  addedAt）、rename/remove/touchUsed、0600 权限、坏文件容错。
//

import XCTest
@testable import TokenTrackerCore

final class CodexAccountStoreTests: XCTestCase {
    private var tmp: TempDir!
    private var storePath: String!
    private var store: CodexAccountStore!

    override func setUp() async throws {
        tmp = try TempDir()
        storePath = tmp.path("codex_accounts.json")
        store = CodexAccountStore(path: storePath)
    }

    override func tearDown() async throws {
        tmp = nil; store = nil; storePath = nil
    }

    private func account(_ id: String, name: String, rt: String,
                         addedAt: Date = Date(timeIntervalSince1970: 1000)) -> CodexAccount {
        CodexAccount(id: id, name: name,
                     bundle: ["auth_mode": "chatgpt",
                              "tokens": ["account_id": id, "refresh_token": rt]],
                     addedAt: addedAt)
    }

    private func refreshToken(_ acc: CodexAccount?) -> String? {
        (acc?.bundle["tokens"] as? [String: Any])?["refresh_token"] as? String
    }

    func testEmptyWhenFileMissing() throws {
        XCTAssertEqual(store.load().count, 0)
        XCTAssertNil(store.get("nope"))
    }

    func testSaveLoadRoundTrip() throws {
        try store.upsert(account("A", name: "甲", rt: "R-A"))
        try store.upsert(account("B", name: "乙", rt: "R-B"))
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.map(\.id).sorted(), ["A", "B"])
        XCTAssertEqual(store.get("A")?.name, "甲")
        XCTAssertEqual(refreshToken(store.get("A")), "R-A")
        XCTAssertEqual(store.get("A")?.addedAt, Date(timeIntervalSince1970: 1000))
    }

    /// 同 id 二次 upsert：更新 bundle/name，但保留首次 addedAt。
    func testUpsertDedupByIDPreservesAddedAt() throws {
        try store.upsert(account("A", name: "甲", rt: "R1"))
        try store.upsert(account("A", name: "甲改", rt: "R1-rotated",
                             addedAt: Date(timeIntervalSince1970: 9999)))
        let all = store.load()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].name, "甲改")
        XCTAssertEqual(refreshToken(all[0]), "R1-rotated")
        XCTAssertEqual(all[0].addedAt, Date(timeIntervalSince1970: 1000))   // 保留首次
    }

    func testRenameRemoveTouchUsed() throws {
        try store.upsert(account("A", name: "甲", rt: "R-A"))
        try store.upsert(account("B", name: "乙", rt: "R-B"))

        let afterRename = try store.rename("A", name: "甲PLUS")
        XCTAssertEqual(afterRename.first { $0.id == "A" }?.name, "甲PLUS")
        XCTAssertEqual(store.get("A")?.name, "甲PLUS")

        XCTAssertNil(store.get("A")?.lastUsedAt)
        let touchDate = Date(timeIntervalSince1970: 5000)
        try store.touchUsed("A", at: touchDate)
        XCTAssertEqual(store.get("A")?.lastUsedAt, touchDate)

        let afterRemove = try store.remove("A")
        XCTAssertEqual(afterRemove.count, 1)
        XCTAssertEqual(afterRemove[0].id, "B")
        XCTAssertNil(store.get("A"))
    }

    /// 密钥类数据：落盘必须 0600。
    func testFilePermissions0600() throws {
        try store.upsert(account("A", name: "甲", rt: "R-A"))
        let attrs = try FileManager.default.attributesOfItem(atPath: storePath)
        XCTAssertEqual((attrs[.posixPermissions] as? Int) ?? 0, 0o600)
    }

    func testCorruptFileReadsEmpty() throws {
        try "{ not json".write(toFile: storePath, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.load().count, 0)
    }

    /// email/plan/lastUsedAt 等可选字段 round-trip 不丢。
    func testOptionalFieldsRoundTrip() throws {
        var acc = account("A", name: "甲", rt: "R-A")
        acc.email = "a@b.com"
        acc.plan = "plus"
        acc.lastUsedAt = Date(timeIntervalSince1970: 7000)
        try store.upsert(acc)
        let loaded = store.get("A")
        XCTAssertEqual(loaded?.email, "a@b.com")
        XCTAssertEqual(loaded?.plan, "plus")
        XCTAssertEqual(loaded?.lastUsedAt, Date(timeIntervalSince1970: 7000))
    }
}
