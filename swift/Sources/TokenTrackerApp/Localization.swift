import AppKit
import Combine
import SwiftUI

/// App-only preference. Shared usage settings and persisted records are unaffected.
enum AppLanguage: String, CaseIterable, Sendable {
    case system, simplifiedChinese = "zh-Hans", english = "en"

    func resolved(preferredLanguages: [String]) -> String {
        if self != .system { return rawValue }
        return preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? "zh-Hans" : "en"
    }
}

@MainActor
final class LanguageManager: ObservableObject {
    static let shared = LanguageManager(defaults: appDefaults)
    nonisolated static var appDefaults: UserDefaults {
        if ProcessInfo.processInfo.environment["TT_UI_PREVIEW"] == "1" {
            return UserDefaults(suiteName: "com.tokentracker.language-preview")!
        }
        return .standard
    }
    nonisolated static let preferenceKey = "tt.app.language"
    private let defaults: UserDefaults
    @Published var selection: AppLanguage {
        didSet {
            defaults.set(selection.rawValue, forKey: Self.preferenceKey)
            refresh()
        }
    }
    @Published private(set) var locale: Locale
    private var systemObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let initial = AppLanguage(rawValue: defaults.string(forKey: Self.preferenceKey) ?? "") ?? .system
        selection = initial
        locale = Locale(identifier: initial.resolved(preferredLanguages: Locale.preferredLanguages))
        L10n.setLanguage(locale.identifier)
        systemObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }

    private func refresh() {
        locale = Locale(identifier: selection.resolved(preferredLanguages: Locale.preferredLanguages))
        L10n.setLanguage(locale.identifier)
        NotificationCenter.default.post(name: .appLanguageChanged, object: nil)
    }
}

extension Notification.Name {
    static let appLanguageChanged = Notification.Name("TokenTracker.appLanguageChanged")
}

/// Thread-safe lookup for formatting performed by background operations as well as views.
enum L10n {
    indirect enum Argument: Sendable, Equatable {
        case literal(String), template(Template)
        func rendered(language: String) -> String {
            switch self {
            case .literal(let value): return value
            case .template(let value): return L10n.render(value, language: language)
            }
        }
    }
    struct Template: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Sendable, Equatable {
        var key: String
        var arguments: [Argument] = []
        var verbatim = false
        init(verbatim value: String) { key = value; verbatim = true }
        init(stringLiteral value: String) { key = value }
        init(stringInterpolation: StringInterpolation) {
            key = stringInterpolation.key
            arguments = stringInterpolation.arguments
        }
        struct StringInterpolation: StringInterpolationProtocol {
            var key = ""
            var arguments: [Argument] = []
            init(literalCapacity: Int, interpolationCount: Int) {}
            mutating func appendLiteral(_ literal: String) { key += literal }
            mutating func appendInterpolation(_ value: Template) {
                key += "{\(arguments.count)}"
                arguments.append(.template(value))
            }
            mutating func appendInterpolation<T>(_ value: T) {
                key += "{\(arguments.count)}"
                arguments.append(.literal(String(describing: value)))
            }
        }
    }
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var language = AppLanguage(rawValue: LanguageManager.appDefaults.string(forKey: LanguageManager.preferenceKey) ?? "")?
            .resolved(preferredLanguages: Locale.preferredLanguages)
            ?? AppLanguage.system.resolved(preferredLanguages: Locale.preferredLanguages)
    }
    private static let storage = Storage()
    static var language: String {
        storage.lock.lock(); defer { storage.lock.unlock() }
        return storage.language
    }
    static var isEnglish: Bool { language == "en" }
    static var locale: Locale { Locale(identifier: language) }
    static func setLanguage(_ value: String) {
        storage.lock.lock(); defer { storage.lock.unlock() }
        storage.language = value
    }
    // SwiftPM executables look beside the binary; packaged apps carry resources in
    // Contents/Resources. Prefer that location so deployment never depends on .build.
    static let resources: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("TokenTracker_TokenTrackerApp.bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()
    private static let bundles = ["en", "zh-Hans"].reduce(into: [String: Bundle]()) {
        $0[$1] = Bundle(path: resources.path(forResource: $1.lowercased(), ofType: "lproj")!)!
    }
    private static let placeholders = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
    static func localizedBundle(_ language: String) -> Bundle { bundles[language] ?? bundles["en"]! }
    static func message(_ template: Template) -> Template { template }

    static func text(_ template: Template) -> String { render(template, language: language) }
    static func render(_ template: Template, language: String) -> String {
        if template.verbatim { return template.key }
        let translated = localizedBundle(language).localizedString(forKey: template.key, value: template.key, table: nil)
        // Replace placeholders in a single pass: user text containing {1} stays literal.
        let regex = placeholders
        var result = translated
        for match in regex.matches(in: translated, range: NSRange(translated.startIndex..., in: translated)).reversed() {
            let index = Int((translated as NSString).substring(with: match.range(at: 1)))!
            if template.arguments.indices.contains(index), let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: template.arguments[index].rendered(language: language))
            }
        }
        return result
    }
    /// Use only for built-in labels, never for user names, titles, paths, or external errors.
    static func label(_ key: String) -> String { text(Template(stringLiteral: key)) }
}

private struct AppLanguageModifier: ViewModifier {
    @ObservedObject private var language = LanguageManager.shared
    func body(content: Content) -> some View {
        content.environment(\.locale, language.locale)
    }
}
extension View {
    func appLanguage() -> some View { modifier(AppLanguageModifier()) }
}

/// Keeps labels inside SwiftUI's cached ForEach/Picker content reactive as well.
struct LocalizedText: View {
    @ObservedObject private var language = LanguageManager.shared
    let template: L10n.Template
    init(_ template: L10n.Template) { self.template = template }
    var body: some View { Text(L10n.render(template, language: language.locale.identifier)) }
}
