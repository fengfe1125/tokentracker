//
//  CliFindTests.swift
//  TokenTrackerCoreTests
//
//  登录 shell 探测：超时必须生效（rc 卡住不拖住调用方），命令名不进 shell 解释。
//

import XCTest
@testable import TokenTrackerCore

final class CliFindTests: XCTestCase {
    private var tmp: TempDir!

    override func setUp() async throws { tmp = try TempDir() }
    override func tearDown() async throws { tmp = nil }

    private func fakeShell(_ body: String) throws -> String {
        let path = tmp.path("fake-shell")
        try ("#!/bin/sh\n" + body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
        return path
    }

    func testProbeReturnsLastAbsoluteExecutableLine() throws {
        let shell = try fakeShell("echo 'welcome banner'\necho /bin/ls")
        XCTAssertEqual(CliFind.probeLoginShell("ls", shell: shell, timeout: 5), "/bin/ls")
    }

    func testSilentHangingShellTimesOut() throws {
        // 不输出也不退出：旧实现阻塞在 availableData 上，超时永远不生效。
        let shell = try fakeShell("exec sleep 30")
        let started = Date()
        XCTAssertNil(CliFind.probeLoginShell("claude", shell: shell, timeout: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testBackgroundChildHoldingPipeDoesNotBlock() throws {
        // shell 已退出，但后台子进程仍持有 stdout 写端。
        let shell = try fakeShell("(sleep 30) &\necho /bin/ls")
        let started = Date()
        XCTAssertEqual(CliFind.probeLoginShell("ls", shell: shell, timeout: 5), "/bin/ls")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testOnlyPlainCommandNamesAreProbed() throws {
        let marker = tmp.path("ran")
        let shell = try fakeShell("touch '\(marker)'\necho /bin/ls")
        XCTAssertNil(CliFind.probeLoginShell("ls; rm -rf ~", shell: shell, timeout: 5))
        XCTAssertNil(CliFind.probeLoginShell("$(id)", shell: shell, timeout: 5))
        XCTAssertNil(CliFind.probeLoginShell("", shell: shell, timeout: 5))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "非法命令名不应启动 shell")
        XCTAssertTrue(CliFind.isPlainCommandName("codex-cli_2.0"))
    }
}
