//
//  ResumeTests.swift
//  TokenTrackerCoreTests
//
//  移植 tests/test_resume.py：命令矩阵、注入防护、cwd 解析、终端打开——
//  不触碰真实终端与剪贴板。
//

import XCTest
@testable import TokenTrackerCore

final class ResumeArgvPortTests: XCTestCase {
    private let resume = Resume(cliResolver: { _ in "/usr/bin/x" })

    /// test_command_matrix
    func testCommandMatrix() {
        XCTAssertEqual(resume.resumeArgv("claude", "abc"), ["claude", "--resume", "abc"])
        XCTAssertEqual(resume.resumeArgv("codex", "abc"), ["codex", "resume", "abc"])
        XCTAssertEqual(resume.resumeArgv("kimi", "abc"), ["kimi", "--session", "session_abc"])
        // kimi CLI 的会话 ID 带 session_ 前缀；已带前缀的幂等
        XCTAssertEqual(resume.resumeArgv("kimi", "session_abc"),
                       ["kimi", "--session", "session_abc"])
        XCTAssertEqual(resume.resumeArgv("opencode", "s1"), ["opencode", "--session", "s1"])
        XCTAssertEqual(resume.resumeArgv("pi", "abc"), ["pi", "--session", "abc"])
        XCTAssertEqual(resume.resumeArgv("hermes", "s1"), ["hermes", "--resume", "s1"])
    }

    /// test_unsupported_tool_and_missing_id
    func testUnsupportedToolAndMissingID() {
        XCTAssertNil(resume.resumeArgv("dsh", "session-x"))
        XCTAssertNil(resume.resumeArgv("nope", "x"))
        XCTAssertNil(resume.resumeArgv("claude", ""))
    }
}

final class ResumeShellLinePortTests: XCTestCase {
    private var resume: Resume { Resume(cliResolver: { _ in "/usr/bin/x" }) }

    /// test_quotes_hostile_values
    func testQuotesHostileValues() {
        let evil = #"$(touch /tmp/pwned)";`id`"#
        let (cmd, reason) = resume.shellLine("claude", evil, "/nonexistent-dir-xyz")
        XCTAssertNil(reason)
        XCTAssertTrue(cmd!.contains(Resume.shlexQuote(evil)))
        XCTAssertFalse(cmd!.contains("cd "))   // 目录不存在时不加 cd
    }

    /// shlex.quote 边界
    func testShlexQuote() {
        XCTAssertEqual(Resume.shlexQuote("abc-DEF_123.txt"), "abc-DEF_123.txt")
        XCTAssertEqual(Resume.shlexQuote(""), "''")
        XCTAssertEqual(Resume.shlexQuote("a'b"), "'a'\"'\"'b'")
        XCTAssertEqual(Resume.shlexQuote("带空格 的路径"), "'带空格 的路径'")
    }

    /// test_cds_into_existing_project
    func testCdsIntoExistingProject() throws {
        let tmp = try TempDir()
        let (cmd, _) = resume.shellLine("codex", "abc", tmp.url.path)
        XCTAssertTrue(cmd!.hasPrefix("cd "))
        XCTAssertTrue(cmd!.hasSuffix("resume abc"))
    }

    /// test_missing_cli_reports_reason
    func testMissingCLIReportsReason() {
        let missing = Resume(cliResolver: { _ in nil })
        let (cmd, reason) = missing.shellLine("claude", "abc", "")
        XCTAssertNil(cmd)
        XCTAssertTrue(reason!.contains("claude"))
    }

    /// test_dsh_is_not_resumable
    func testDshIsNotResumable() {
        let (cmd, reason) = resume.shellLine("dsh", "session-x", "/tmp")
        XCTAssertNil(cmd)
        XCTAssertTrue(reason!.contains("不支持"))
    }

    /// test_cwd_override_wins_when_directory_exists
    func testCwdOverrideWinsWhenDirectoryExists() throws {
        let a = try TempDir()
        let b = try TempDir()
        let (cmd, _) = resume.shellLine("codex", "abc", a.url.path, cwdOverride: b.url.path)
        XCTAssertTrue(cmd!.contains("cd \(b.url.path)"))
    }

    /// test_claude_reads_cwd_from_jsonl
    func testClaudeReadsCwdFromJSONL() throws {
        let root = try TempDir()
        let real = try TempDir()
        writeJSONL(root.path("-Users-x-proj", "sid-1.jsonl"), [["cwd": real.url.path]])
        let withRoot = Resume(cliResolver: { _ in "/usr/bin/x" }, claudeRoot: root.url.path)
        XCTAssertEqual(withRoot.resolveCwd("claude", "sid-1", "-Users-x-proj"), real.url.path)
    }

    /// test_claude_slug_fallback_when_jsonl_absent
    func testClaudeSlugFallbackWhenJSONLAbsent() throws {
        let root = try TempDir()
        let withRoot = Resume(cliResolver: { _ in "/usr/bin/x" }, claudeRoot: root.url.path)
        // slug 还原的 /nonexistent/xyz/abc 不存在 → nil
        XCTAssertNil(withRoot.resolveCwd("claude", "missing-id", "-nonexistent-xyz-abc"))
    }
}

final class ResumeInfoPortTests: XCTestCase {
    /// test_unsupported / test_missing_cli / test_ok_with_cwd_flag
    func testUnsupported() {
        let payload = Resume(cliResolver: { _ in "/usr/bin/x" }).info("dsh", "session-x", "/tmp")
        XCTAssertFalse(payload.ok)
        XCTAssertTrue(payload.reason.contains("不支持"))
    }

    func testMissingCLI() {
        let payload = Resume(cliResolver: { _ in nil }).info("claude", "abc", "")
        XCTAssertFalse(payload.ok)
        XCTAssertTrue(payload.reason.contains("claude"))
    }

    func testOKWithCwdFlag() throws {
        let tmp = try TempDir()
        let resume = Resume(cliResolver: { _ in "/usr/bin/x" })
        var payload = resume.info("codex", "abc", tmp.url.path)
        XCTAssertTrue(payload.ok)
        XCTAssertFalse(payload.cwdMissing)
        payload = resume.info("codex", "abc", "/nonexistent-xyz")
        XCTAssertTrue(payload.ok)
        XCTAssertTrue(payload.cwdMissing)
    }
}

final class ResumeTerminalPortTests: XCTestCase {
    /// test_pick_terminal_fallback
    func testPickTerminalFallback() {
        let noneInstalled = Resume(appInstalled: { _ in false })
        XCTAssertEqual(noneInstalled.pickTerminal("auto"), "terminal")
        XCTAssertEqual(noneInstalled.pickTerminal("iterm"), "terminal")
        let onlyITerm = Resume(appInstalled: { $0 == "iTerm" })
        XCTAssertEqual(onlyITerm.pickTerminal("auto"), "iterm")
        XCTAssertEqual(onlyITerm.pickTerminal("wezterm"), "terminal")
    }

    /// test_applescript_escaping
    func testAppleScriptEscaping() {
        XCTAssertEqual(Resume.applescriptEscape(#"a"b\c"#), #"a\"b\\c"#)
    }

    /// test_open_terminal_uses_osascript
    func testOpenTerminalUsesOsascript() throws {
        var calls: [[String]] = []
        let resume = Resume(runner: { args, _ in calls.append(args) },
                            appInstalled: { $0 == "Terminal" })
        XCTAssertTrue(resume.openTerminal("cd /tmp && claude --resume x", pref: "auto"))
        XCTAssertEqual(Array(calls[0].prefix(2)), ["osascript", "-e"])
        XCTAssertTrue(calls[0][2].contains("do script"))
    }

    /// test_open_terminal_failure_returns_false
    func testOpenTerminalFailureReturnsFalse() {
        struct Boom: Error {}
        let resume = Resume(runner: { _, _ in throw Boom() },
                            appInstalled: { $0 == "Terminal" })
        XCTAssertFalse(resume.openTerminal("cmd"))
    }

    /// test_clipboard
    func testClipboard() {
        var received: Data?
        let ok = Resume(runner: { args, input in
            XCTAssertEqual(args, ["pbcopy"])
            received = input
        })
        XCTAssertTrue(ok.copyToClipboard("hello"))
        XCTAssertEqual(String(data: received ?? Data(), encoding: .utf8), "hello")
        struct Boom: Error {}
        let fail = Resume(runner: { _, _ in throw Boom() })
        XCTAssertFalse(fail.copyToClipboard("hello"))
    }
}

final class UpdateCheckerPortTests: XCTestCase {
    func testParseVersion() {
        XCTAssertEqual(UpdateChecker.parseVersion("v0.2.1"), [0, 2, 1])
        XCTAssertEqual(UpdateChecker.parseVersion("0.10.0"), [0, 10, 0])
        XCTAssertEqual(UpdateChecker.parseVersion(""), [])
    }

    func testUpdateAvailable() throws {
        XCTAssertTrue(UpdateChecker.updateAvailable(
            UpdateInfo(latest: "v0.3.0", url: "", checkedAt: 0), current: "0.2.0"))
        XCTAssertFalse(UpdateChecker.updateAvailable(
            UpdateInfo(latest: "v0.2.0", url: "", checkedAt: 0), current: "0.2.0"))
        XCTAssertFalse(UpdateChecker.updateAvailable(nil, current: "0.2.0"))
    }

    /// 缓存 24h；网络失败静默返回缓存。
    func testCacheAndFailureSilent() throws {
        let tmp = try TempDir()
        let clock = StateBox(1_000_000.0)
        let fetchCalls = StateBox(0)
        let checker = UpdateChecker(cachePath: tmp.path("update_check.json"),
                                    clock: { clock.value },
                                    fetch: { _ in
                                        fetchCalls.value += 1
                                        return Data(#"{"tag_name":"v9.9.9","html_url":"https://x"}"#
                                            .utf8)
                                    })
        let info = checker.check()
        XCTAssertEqual(info?.latest, "v9.9.9")
        _ = checker.check()
        XCTAssertEqual(fetchCalls.value, 1)   // 24h 缓存
        clock.value += UpdateChecker.cacheTTL + 1
        _ = checker.check()
        XCTAssertEqual(fetchCalls.value, 2)

        // 失败静默：用过期缓存
        let failing = UpdateChecker(cachePath: tmp.path("update_check.json"),
                                    clock: { clock.value },
                                    fetch: { _ in throw SQLiteError(message: "offline") })
        clock.value += UpdateChecker.cacheTTL + 1
        XCTAssertEqual(failing.check()?.latest, "v9.9.9")
    }
}
