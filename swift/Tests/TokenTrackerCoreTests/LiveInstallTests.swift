//
//  LiveInstallTests.swift
//  TokenTrackerCoreTests
//
//  真实跑一遍安装流程（hdiutil 挂载 / codesign 校验 / cp / xattr / mv），
//  目标是临时目录里的假 .app，绝不碰 /Applications。默认跳过。
//
//  跑法：TT_DMG=dist/TokenTracker-0.2.3.dmg swift test --filter LiveInstall
//

import XCTest
@testable import TokenTrackerCore

final class LiveInstallTests: XCTestCase {
    private var dmgPath: String? {
        ProcessInfo.processInfo.environment["TT_DMG"]
    }

    func testInstallsRealDMGIntoTempApp() throws {
        try XCTSkipIf(dmgPath == nil, "设 TT_DMG=<路径> 才跑")
        let dmg = URL(fileURLWithPath: dmgPath!)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dmg.path), "找不到 \(dmg.path)")

        let dir = try TempDir()
        let target = dir.path("TokenTracker.app")
        // 造一个占位 bundle，install 要先把它挪走
        try FileManager.default.createDirectory(atPath: target + "/Contents",
                                                withIntermediateDirectories: true)
        try "placeholder".write(toFile: target + "/Contents/marker",
                                atomically: true, encoding: .utf8)

        let installer = UpdateInstaller()
        let sha = try UpdateInstaller.sha256Hex(of: dmg)
        try installer.install(dmg: dmg, into: target, expectedSHA256: sha)

        // 占位内容被换掉了
        XCTAssertFalse(FileManager.default.fileExists(atPath: target + "/Contents/marker"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: target + "/Contents/MacOS/TokenTracker"))
        // 中间产物清干净
        XCTAssertFalse(FileManager.default.fileExists(atPath: target + ".old"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target + ".incoming"))

        // 身份对得上
        let plist = try run(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleIdentifier",
                             target + "/Contents/Info.plist"])
        XCTAssertEqual(plist.trimmingCharacters(in: .whitespacesAndNewlines),
                       UpdateInstaller.bundleID)
        // 签名仍然有效（cp / xattr 没破坏它）
        XCTAssertNoThrow(try run(["/usr/bin/codesign", "--verify", "--strict", target]))
        // quarantine 已清（否则换完起不来）
        let attrs = (try? run(["/usr/bin/xattr", "-l", target])) ?? ""
        XCTAssertFalse(attrs.contains("com.apple.quarantine"))
    }

    /// 校验和不对时必须整个中止，占位 bundle 原封不动。
    func testChecksumMismatchLeavesTargetUntouched() throws {
        try XCTSkipIf(dmgPath == nil, "设 TT_DMG=<路径> 才跑")
        let dmg = URL(fileURLWithPath: dmgPath!)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dmg.path), "找不到 \(dmg.path)")

        let dir = try TempDir()
        let target = dir.path("TokenTracker.app")
        try FileManager.default.createDirectory(atPath: target + "/Contents",
                                                withIntermediateDirectories: true)
        try "placeholder".write(toFile: target + "/Contents/marker",
                                atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try UpdateInstaller().install(dmg: dmg, into: target, expectedSHA256: "deadbeef"))
        XCTAssertEqual(try String(contentsOfFile: target + "/Contents/marker", encoding: .utf8),
                       "placeholder")
    }

    @discardableResult
    private func run(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateInstallError.commandFailed(args[0], process.terminationStatus)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
