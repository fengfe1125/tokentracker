import XCTest
@testable import TokenTrackerApp
@testable import TokenTrackerCore

final class LocalizationTests: XCTestCase {
    func testSystemAndExplicitLanguageResolution() {
        for preferred in [["zh-CN"], ["zh-Hant-TW"], ["zh-Hans", "en"]] {
            XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: preferred), "zh-Hans")
        }
        for preferred in [["en-US"], ["ja-JP", "zh-CN"], []] {
            XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: preferred), "en")
        }
        XCTAssertEqual(AppLanguage.english.resolved(preferredLanguages: ["zh-CN"]), "en")
        XCTAssertEqual(AppLanguage.simplifiedChinese.resolved(preferredLanguages: ["en"]), "zh-Hans")
    }

    @MainActor
    func testPersistenceAndInvalidPreferenceFallback() {
        let suite = "tt.language.test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let previous = L10n.language
        defer { defaults.removePersistentDomain(forName: suite); L10n.setLanguage(previous) }
        let manager = LanguageManager(defaults: defaults)
        XCTAssertEqual(manager.selection, .system)
        manager.selection = .english
        XCTAssertEqual(LanguageManager(defaults: defaults).selection, .english)
        XCTAssertEqual(manager.locale.identifier, "en")
        manager.selection = .simplifiedChinese
        XCTAssertEqual(manager.locale.identifier, "zh-Hans")
        XCTAssertEqual(defaults.string(forKey: LanguageManager.preferenceKey), "zh-Hans")
        defaults.set("invalid", forKey: LanguageManager.preferenceKey)
        XCTAssertEqual(LanguageManager(defaults: defaults).selection, .system)
    }

    func testResourcesHaveMatchingKeysAndPlaceholders() throws {
        func strings(_ language: String) throws -> [String: String] {
            let url = try XCTUnwrap(L10n.localizedBundle(language).url(forResource: "Localizable", withExtension: "strings"))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
        }
        let en = try strings("en"), zh = try strings("zh-Hans")
        XCTAssertEqual(Set(en.keys), Set(zh.keys))
        XCTAssertGreaterThan(en.count, 450)
        let regex = try NSRegularExpression(pattern: #"\{\d+\}"#)
        func placeholders(_ value: String) -> [String] {
            regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
                (value as NSString).substring(with: $0.range)
            }.sorted()
        }
        for (key, value) in en {
            XCTAssertFalse(value.isEmpty, key)
            XCTAssertEqual(placeholders(key), placeholders(value), key)
            XCTAssertEqual(zh[key], key)
        }
    }

    func testStoredMessagesRerenderAndPreserveUserText() {
        let name = "中文 {1} / English"
        let message: L10n.Template = "已保存账号「\(name)」"
        XCTAssertEqual(L10n.render(message, language: "en"), "Saved account “中文 {1} / English”")
        XCTAssertEqual(L10n.render(message, language: "zh-Hans"), "已保存账号「中文 {1} / English」")
        let error = UIFormat.appError(CodexAccountError.notFound(name))
        let nested: L10n.Template = "保存失败：\(error)"
        XCTAssertEqual(L10n.render(nested, language: "en"), "Could not save: Account not found: " + name)
        XCTAssertEqual(L10n.render(L10n.Template(verbatim: "未知"), language: "en"), "未知")
    }

    func testEnglishUnitsAndEvidenceDoNotChangeMeaning() {
        let previous = L10n.language
        defer { L10n.setLanguage(previous) }
        L10n.setLanguage("en")
        XCTAssertEqual(UIFormat.tokens(100_000_000, yi: true), "100.00M")
        XCTAssertEqual(UIFormat.overviewTokens(4_650_000, yi: true), "≈ 4.65M")
        XCTAssertEqual(L10n.text("未知"), "Unknown")
        XCTAssertEqual(L10n.text("不可用"), "Unavailable")
        XCTAssertEqual(L10n.text("已确认"), "Confirmed")
        XCTAssertEqual(L10n.text("推断"), "Inferred")
        XCTAssertEqual(UIFormat.quotaLabel("自定义窗口"), "自定义窗口")
        L10n.setLanguage("zh-Hans")
        XCTAssertEqual(UIFormat.overviewTokens(4_650_000, yi: true), "≈ 465.00 万")
        XCTAssertEqual(UIFormat.overviewTokens(100_000_000, yi: true), "≈ 1.00 亿")
    }
}
