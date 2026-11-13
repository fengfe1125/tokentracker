import XCTest
@testable import TokenTrackerCore

final class UpdateChannelTests: XCTestCase {
    private func release(_ tag: String, prerelease: Bool = false, draft: Bool = false,
                         dmg: Bool = true) -> [String: Any] {
        ["tag_name": tag, "html_url": "https://example.invalid/\(tag)", "prerelease": prerelease,
         "draft": draft,
         "assets": dmg ? [["name": "TokenTracker-\(tag).dmg",
                           "browser_download_url": "https://example.invalid/\(tag).dmg", "size": 10]] : []]
    }

    private func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }

    func testPrereleaseOrdersBeforeItsReleaseAndNumericIdentifiersCompareAsNumbers() {
        let ascending = ["0.5.9", "0.6.0-alpha", "0.6.0-beta.1", "0.6.0-beta.2", "0.6.0-beta.10",
                         "0.6.0-rc.1", "0.6.0", "v0.6.1-beta.1", "0.10.0"]
        for (index, older) in ascending.enumerated() {
            XCTAssertEqual(UpdateChecker.compareVersions(older, older), 0, older)
            for newer in ascending[(index + 1)...] {
                XCTAssertLessThan(UpdateChecker.compareVersions(older, newer), 0, "\(older) < \(newer)")
                XCTAssertGreaterThan(UpdateChecker.compareVersions(newer, older), 0, "\(newer) > \(older)")
            }
        }
        XCTAssertEqual(UpdateChecker.compareVersions("v0.6", "0.6.0"), 0)
    }

    func testInstalledBetaIsOfferedTheFinalReleaseButNotAnOlderStable() {
        func available(_ latest: String, _ current: String) -> Bool {
            UpdateChecker.updateAvailable(UpdateInfo(latest: latest, url: "", checkedAt: 0), current: current)
        }
        XCTAssertTrue(available("v0.6.0", "0.6.0-beta.2"))
        XCTAssertTrue(available("v0.6.0-beta.3", "0.6.0-beta.2"))
        XCTAssertFalse(available("v0.5.9", "0.6.0-beta.2"))
        XCTAssertFalse(available("v0.6.0-beta.2", "0.6.0"))
    }

    func testBetaChannelPicksHighestVersionSkippingDraftsAndStableChannelIgnoresTheList() throws {
        let list = json([release("v0.6.0-beta.1", prerelease: true), release("v0.7.0-beta.9", draft: true),
                         release("v0.6.0-beta.2", prerelease: true), release("v0.5.9")])
        let tmp = NSTemporaryDirectory() + "tt-update-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        final class Calls: @unchecked Sendable { var urls: [String] = [] }
        let calls = Calls()
        let latest = json(release("v0.5.9"))
        let checker = UpdateChecker(cachePath: tmp, clock: { 1_000 }, fetch: { url in
            calls.urls.append(url)
            return url.hasSuffix("/latest") ? latest : list
        })

        XCTAssertEqual(checker.check(beta: false)?.latest, "v0.5.9")
        XCTAssertEqual(calls.urls.last, UpdateChecker.releasesURL(beta: false))
        // 同一通道 24 小时内走缓存
        XCTAssertEqual(checker.check(beta: false)?.latest, "v0.5.9")
        XCTAssertEqual(calls.urls.count, 1)
        // 打开测试版：正式版的缓存不能拿来回答，必须重新查列表
        let beta = checker.check(beta: true)
        XCTAssertEqual(beta?.latest, "v0.6.0-beta.2")
        XCTAssertEqual(beta?.beta, true)
        XCTAssertEqual(calls.urls.last, UpdateChecker.releasesURL(beta: true))
        XCTAssertEqual(calls.urls.count, 2)
        // 关回正式版同理
        XCTAssertEqual(checker.check(beta: false)?.latest, "v0.5.9")
        XCTAssertEqual(calls.urls.count, 3)
    }

    func testBetaChannelFallsBackToStableWhenItIsNewerAndOtherChannelCacheIsNotUsedOffline() throws {
        let list = json([release("v0.6.0-beta.2", prerelease: true), release("v0.6.0")])
        XCTAssertEqual(UpdateChecker.newestRelease(inList: list)?["tag_name"] as? String, "v0.6.0")
        XCTAssertNil(UpdateChecker.newestRelease(inList: json([release("v1.0.0", draft: true)])))
        XCTAssertNil(UpdateChecker.newestRelease(inList: Data("not json".utf8)))

        let tmp = NSTemporaryDirectory() + "tt-update-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        struct Offline: Error {}
        let latest = json(release("v0.5.9"))
        XCTAssertEqual(UpdateChecker(cachePath: tmp, clock: { 0 }, fetch: { _ in latest }).check()?.latest, "v0.5.9")
        let offline = UpdateChecker(cachePath: tmp, clock: { 0 }, fetch: { _ in throw Offline() })
        XCTAssertNil(offline.check(force: true, beta: true))
        XCTAssertEqual(offline.check(force: true, beta: false)?.latest, "v0.5.9")
    }

    func testInstallerResolvesTheSameReleaseAsTheCheckerOnEachChannel() throws {
        let list = json([release("v0.6.0-beta.1", prerelease: true), release("v0.6.0-beta.2", prerelease: true),
                         release("v0.5.9")])
        let latest = json(release("v0.5.9"))
        let installer = UpdateInstaller(fetch: { $0.hasSuffix("/latest") ? latest : list })
        XCTAssertEqual(try installer.latestRelease().tag, "v0.5.9")
        let beta = try installer.latestRelease(beta: true)
        XCTAssertEqual(beta.tag, "v0.6.0-beta.2")
        XCTAssertEqual(beta.dmg?.name, "TokenTracker-v0.6.0-beta.2.dmg")
        let none = json([])
        let empty = UpdateInstaller(fetch: { _ in none })
        XCTAssertThrowsError(try empty.latestRelease(beta: true)) {
            XCTAssertEqual($0 as? UpdateInstallError, .noRelease)
        }
    }

    func testBetaSettingIsABooleanOffByDefault() {
        XCTAssertEqual(SettingsStore.defaults["update_beta"] as? Bool, false)
        XCTAssertTrue(SettingsStore.isValid(key: "update_beta", value: true))
        XCTAssertFalse(SettingsStore.isValid(key: "update_beta", value: "yes"))
        XCTAssertFalse(SettingsStore.isValid(key: "update_beta", value: 1))
    }
}
