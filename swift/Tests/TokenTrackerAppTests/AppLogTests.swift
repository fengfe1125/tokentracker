import XCTest
@testable import TokenTrackerApp

final class AppLogTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tt_applog_\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func mode(_ path: String) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testLinesUseLocalTimeAndFilesAreOwnerOnly() throws {
        let path = dir.appendingPathComponent("app.log").path
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        AppLog.writeSync("状态栏已安装", to: path, now: date)
        AppLog.writeSync("second", to: path, now: date)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let stamp = formatter.string(from: date)
        XCTAssertEqual(text, "\(stamp) 状态栏已安装\n\(stamp) second\n")
        XCTAssertEqual(try mode(path), 0o600)
        XCTAssertEqual(try mode(dir.path) & 0o077, 0)
    }

    func testRotatesOnceOverLimitAndTightensLegacyMode() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("app.log").path
        FileManager.default.createFile(atPath: path, contents: Data(repeating: 0x61, count: AppLog.maxBytes + 1),
                                       attributes: [.posixPermissions: 0o644])
        AppLog.writeSync("after rotation", to: path)
        XCTAssertTrue(try String(contentsOfFile: path, encoding: .utf8).hasSuffix("after rotation\n"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path + ".1")[.size] as? Int, AppLog.maxBytes + 1)
        XCTAssertEqual(try mode(path), 0o600)

        // 旧版本留下的 0644 日志在下次写入时收紧。
        let legacy = dir.appendingPathComponent("legacy.log").path
        FileManager.default.createFile(atPath: legacy, contents: Data("old\n".utf8), attributes: [.posixPermissions: 0o644])
        AppLog.writeSync("new", to: legacy)
        XCTAssertEqual(try mode(legacy), 0o600)
    }
}
