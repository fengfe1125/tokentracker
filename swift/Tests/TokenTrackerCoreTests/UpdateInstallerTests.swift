//
//  UpdateInstallerTests.swift
//  TokenTrackerCoreTests
//
//  应用内更新：release 解析 / 校验和 / 挂载点解析 / 安装命令序列与回滚。
//  全程注入 run，不真的挂载磁盘镜像，也不动任何 .app。
//

import XCTest
@testable import TokenTrackerCore

private let releaseJSON = """
{"tag_name":"v0.3.0","html_url":"https://example.invalid/r/v0.3.0",
 "assets":[{"name":"notes.txt","browser_download_url":"https://x/n.txt","size":10},
           {"name":"TokenTracker-0.3.0.dmg",
            "browser_download_url":"https://x/TokenTracker-0.3.0.dmg",
            "size":1263195,"digest":"sha256:abc123"}]}
"""

final class ReleaseParseTests: XCTestCase {
    func testPicksDMGAssetAndStripsDigestPrefix() throws {
        let info = try UpdateInstaller.parseRelease(Data(releaseJSON.utf8))
        XCTAssertEqual(info.tag, "v0.3.0")
        XCTAssertEqual(info.dmg?.name, "TokenTracker-0.3.0.dmg")
        XCTAssertEqual(info.dmg?.sha256, "abc123")     // "sha256:" 前缀要剥掉
        XCTAssertEqual(info.dmg?.size, 1263195)
    }

    func testNoDMGAsset() throws {
        let info = try UpdateInstaller.parseRelease(
            Data(#"{"tag_name":"v1","assets":[{"name":"a.zip"}]}"#.utf8))
        XCTAssertNil(info.dmg)
    }

    func testMissingTagThrows() {
        XCTAssertThrowsError(try UpdateInstaller.parseRelease(Data("{}".utf8))) { error in
            XCTAssertEqual(error as? UpdateInstallError, .noRelease)
        }
    }

    func testBadJSONThrows() {
        XCTAssertThrowsError(try UpdateInstaller.parseRelease(Data("not json".utf8)))
    }
}

final class ChecksumTests: XCTestCase {
    func testVerifyChecksum() throws {
        let dir = try TempDir()
        let file = URL(fileURLWithPath: dir.path("a.bin"))
        try Data("hello".utf8).write(to: file)
        // echo -n hello | shasum -a 256
        let want = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        XCTAssertEqual(try UpdateInstaller.sha256Hex(of: file), want)
        XCTAssertNoThrow(try UpdateInstaller.verifyChecksum(file, expected: want))
        XCTAssertNoThrow(try UpdateInstaller.verifyChecksum(file, expected: nil))  // 老 release 无 digest
        XCTAssertThrowsError(try UpdateInstaller.verifyChecksum(file, expected: "deadbeef"))
    }
}

final class MountPointTests: XCTestCase {
    func testParsesHdiutilOutput() {
        let out = """
        /dev/disk4          \tGUID_partition_scheme          \t
        /dev/disk4s1        \tApple_HFS                      \t/tmp/dmg.XXhK2j
        """
        XCTAssertEqual(UpdateInstaller.mountPoint(fromAttachOutput: out), "/tmp/dmg.XXhK2j")
    }

    func testNoMountPoint() {
        XCTAssertNil(UpdateInstaller.mountPoint(fromAttachOutput: "/dev/disk4\tscheme\t"))
    }
}

/// 记录注入 run 收到的命令，并按需伪造输出。
private final class Recorder: @unchecked Sendable {
    let lock = NSLock()
    var calls: [[String]] = []
    var outputs: [String: String] = [:]
    var failOn: String?
    /// 第几次调用 failOn 才失败（1 起算）
    var failOnOccurrence = 1
    private var seen: [String: Int] = [:]

    func run(_ args: [String]) throws -> String {
        let key = (args[0] as NSString).lastPathComponent
        lock.lock()
        calls.append(args)
        seen[key, default: 0] += 1
        let count = seen[key]!
        lock.unlock()
        if key == failOn, count == failOnOccurrence {
            throw UpdateInstallError.commandFailed(key, 1)
        }
        return outputs[key] ?? ""
    }
    var names: [String] { calls.map { ($0[0] as NSString).lastPathComponent } }
}

final class InstallTests: XCTestCase {
    /// 造一个「已挂载的 dmg」：目录里放一个 TokenTracker.app
    private func mountedDMG() throws -> (TempDir, String) {
        let mount = try TempDir()
        try FileManager.default.createDirectory(
            atPath: mount.path("TokenTracker.app", "Contents"), withIntermediateDirectories: true)
        return (mount, mount.url.path)
    }

    private func recorder(mount: String, bundleID: String = UpdateInstaller.bundleID) -> Recorder {
        let rec = Recorder()
        rec.outputs["hdiutil"] = "/dev/disk4s1\tApple_HFS\t\(mount)"
        rec.outputs["PlistBuddy"] = bundleID + "\n"
        return rec
    }

    func testHappyPathCommandOrder() throws {
        let (mount, mountPath) = try mountedDMG()
        _ = mount
        let rec = recorder(mount: mountPath)
        let installer = UpdateInstaller(run: rec.run)
        let dmg = URL(fileURLWithPath: "/tmp/x.dmg")

        let path = try installer.install(dmg: dmg, into: "/Applications/TokenTracker.app")
        XCTAssertEqual(path, "/Applications/TokenTracker.app")

        // 先校验签名与 bundle id，再拷贝，最后才动原来的 bundle
        let names = rec.names
        XCTAssertEqual(names.first, "hdiutil")                       // attach
        XCTAssertEqual(names.last, "hdiutil")                        // detach
        let codesign = names.firstIndex(of: "codesign")!
        let plist = names.firstIndex(of: "PlistBuddy")!
        let cp = names.firstIndex(of: "cp")!
        let firstMv = names.firstIndex(of: "mv")!
        XCTAssertTrue(codesign < cp && plist < cp, "校验必须在拷贝之前")
        XCTAssertTrue(cp < firstMv, "换掉原 bundle 必须在拷贝成功之后")

        // quarantine 只在校验都过之后清（见 UpdateInstaller 文件头说明）
        let xattr = rec.calls.first { $0[0].hasSuffix("xattr") }
        XCTAssertEqual(xattr.map { Array($0[1...2]) }, ["-dr", "com.apple.quarantine"])
        XCTAssertTrue(names.firstIndex(of: "xattr")! < firstMv)
    }

    func testBundleIDMismatchAbortsBeforeTouchingApp() throws {
        let (mount, mountPath) = try mountedDMG()
        _ = mount
        let rec = recorder(mount: mountPath, bundleID: "com.evil.app")
        let installer = UpdateInstaller(run: rec.run)

        XCTAssertThrowsError(
            try installer.install(dmg: URL(fileURLWithPath: "/tmp/x.dmg"),
                                  into: "/Applications/TokenTracker.app")) { error in
            XCTAssertEqual(error as? UpdateInstallError,
                           .bundleIDMismatch(expected: UpdateInstaller.bundleIDRoot + ".*",
                                             actual: "com.evil.app"))
        }
        XCTAssertFalse(rec.names.contains("mv"), "校验没过就不该动原来的 bundle")
        XCTAssertFalse(rec.names.contains("cp"))
        XCTAssertEqual(rec.names.last, "hdiutil", "失败也要卸载镜像")
    }

    /// 精确单值匹配会让每次 Bundle ID 迁移切断升级链（v0.2.11 迁 .v2 时就是如此）。
    /// 命名空间校验必须同时做到：认自家的历史与未来变体，且挡住近似冒名。
    func testAcceptedBundleIDSpansProjectNamespace() {
        for accepted in ["com.tokentracker.desktop",        // v0.2.10 及更早
                         "com.tokentracker.desktop.v2",     // 当前
                         "com.tokentracker.desktop.v3",     // 将来再迁也不断链
                         "com.tokentracker.desktop.beta"] {
            XCTAssertTrue(UpdateInstaller.isAcceptedBundleID(accepted), accepted)
        }
        for rejected in ["com.evil.app",
                         "com.tokentracker.desktopEVIL",    // 前缀后必须紧跟 "."
                         "com.tokentracker.desktop2",
                         "com.tokentracker",                // 更短的前缀不算
                         "xcom.tokentracker.desktop",       // 不能只做子串匹配
                         ""] {
            XCTAssertFalse(UpdateInstaller.isAcceptedBundleID(rejected), rejected)
        }
        XCTAssertTrue(UpdateInstaller.isAcceptedBundleID(UpdateInstaller.bundleID),
                      "当前构建自身必须被接受")
    }

    /// 老版本装新包（迁移方向）不再被拒。
    func testLegacyBundleIDInstallsWithoutMismatch() throws {
        let (mount, mountPath) = try mountedDMG()
        _ = mount
        let rec = recorder(mount: mountPath, bundleID: "com.tokentracker.desktop")
        let installer = UpdateInstaller(run: rec.run)
        XCTAssertNoThrow(
            try installer.install(dmg: URL(fileURLWithPath: "/tmp/x.dmg"),
                                  into: "/Applications/TokenTracker.app"))
    }

    func testRollsBackWhenSwapFails() throws {
        let (mount, mountPath) = try mountedDMG()
        _ = mount
        let rec = recorder(mount: mountPath)
        rec.failOn = "mv"
        rec.failOnOccurrence = 2      // 第 1 次是把旧包搬走，第 2 次才是搬入新包
        let installer = UpdateInstaller(run: rec.run)

        XCTAssertThrowsError(
            try installer.install(dmg: URL(fileURLWithPath: "/tmp/x.dmg"),
                                  into: "/Applications/TokenTracker.app"))
        // mv 三次：搬走 → 搬入（失败）→ 回滚
        let mvs = rec.calls.filter { $0[0].hasSuffix("/mv") }
        XCTAssertEqual(mvs.count, 3)
        XCTAssertEqual(mvs.last.map { Array($0[1...]) },
                       ["/Applications/TokenTracker.app.old", "/Applications/TokenTracker.app"])
        // 回滚后不能再把备份删掉
        XCTAssertFalse(rec.calls.contains { $0 == ["/bin/rm", "-rf",
                                                   "/Applications/TokenTracker.app.old"] &&
                                            rec.calls.firstIndex(of: $0)! > 6 })
    }

    /// 把旧包搬走这一步就失败 → 原 bundle 原封不动，也没有可回滚的东西
    func testFailureBeforeSwapLeavesAppUntouched() throws {
        let (mount, mountPath) = try mountedDMG()
        _ = mount
        let rec = recorder(mount: mountPath)
        rec.failOn = "mv"             // 默认第 1 次
        let installer = UpdateInstaller(run: rec.run)

        XCTAssertThrowsError(
            try installer.install(dmg: URL(fileURLWithPath: "/tmp/x.dmg"),
                                  into: "/Applications/TokenTracker.app"))
        let mvs = rec.calls.filter { $0[0].hasSuffix("/mv") }
        XCTAssertEqual(mvs.count, 1)
        XCTAssertEqual(mvs.first.map { Array($0[1...]) },
                       ["/Applications/TokenTracker.app", "/Applications/TokenTracker.app.old"])
    }

    func testRejectsNonAppPath() {
        let installer = UpdateInstaller(run: { _ in "" })
        XCTAssertThrowsError(
            try installer.install(dmg: URL(fileURLWithPath: "/tmp/x.dmg"),
                                  into: "/usr/local/bin/tt")) { error in
            XCTAssertEqual(error as? UpdateInstallError, .notAnAppBundle("/usr/local/bin/tt"))
        }
    }

    func testChecksumMismatchNeverMounts() throws {
        let dir = try TempDir()
        let dmg = URL(fileURLWithPath: dir.path("x.dmg"))
        try Data("payload".utf8).write(to: dmg)
        let rec = Recorder()
        let installer = UpdateInstaller(run: rec.run)
        XCTAssertThrowsError(try installer.install(dmg: dmg, into: "/Applications/TokenTracker.app",
                                                   expectedSHA256: "deadbeef"))
        XCTAssertTrue(rec.calls.isEmpty, "校验和不对就不该挂载")
    }
}
