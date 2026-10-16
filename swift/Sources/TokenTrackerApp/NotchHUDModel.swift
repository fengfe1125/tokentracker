import AppKit
import Combine
import TokenTrackerCore

enum NotchHUDQuotaDisplay: String, CaseIterable, Identifiable {
    case used, remaining
    var id: String { rawValue }
    var label: String { L10n.text(self == .used ? "已使用额度" : "剩余额度") }
    var shortLabel: String { L10n.text(self == .used ? "已用" : "剩余") }
    func percentage(used: Double) -> Double { self == .used ? used : 100 - used }
}

/// App-only preferences; never enter the shared settings.json contract.
@MainActor
final class NotchHUDPreferences: ObservableObject {
    static let enabledKey = "tt.app.notchHUD.enabled"
    static let providersKey = "tt.app.notchHUD.providers"
    static let displayKey = "tt.app.notchHUD.quotaDisplay"
    static let shared = NotchHUDPreferences(defaults: {
        if ProcessInfo.processInfo.environment["TT_UI_PREVIEW"] == "1" {
            return UserDefaults(suiteName: "com.tokentracker.notch-preview")!
        }
        return .standard
    }())

    private let defaults: UserDefaults
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Self.enabledKey) }
    }
    @Published private(set) var providers: [String]
    @Published var quotaDisplay: NotchHUDQuotaDisplay {
        didSet { defaults.set(quotaDisplay.rawValue, forKey: Self.displayKey) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        quotaDisplay = defaults.string(forKey: Self.displayKey).flatMap(NotchHUDQuotaDisplay.init(rawValue:)) ?? .remaining
        enabled = defaults.bool(forKey: Self.enabledKey)
        let stored = defaults.stringArray(forKey: Self.providersKey) ?? ["codex", "claude"]
        var seen = Set<String>()
        providers = stored.filter { !$0.isEmpty && seen.insert($0).inserted }
        if providers.isEmpty { providers = ["codex", "claude"] }
    }

    func setProvider(_ provider: String, visible: Bool) {
        if visible, !providers.contains(provider) { providers.append(provider) }
        if !visible, providers.count > 1 { providers.removeAll { $0 == provider } }
        defaults.set(providers, forKey: Self.providersKey)
    }
}

enum NotchHUDLayout {
    static let diameter: CGFloat = 22
    static let spacing: CGFloat = 6
    static let padding: CGFloat = 4
    static let notchGap: CGFloat = 8

    /// All coordinates are AppKit points, including negative multi-display origins.
    static func stripFrame(leftArea: CGRect?, screen: CGRect, topInset: CGFloat,
                           builtIn: Bool, count: Int) -> CGRect? {
        guard builtIn, topInset > 0, let leftArea, count > 0 else { return nil }
        let height = min(diameter + padding * 2, leftArea.height)
        let width = CGFloat(count) * diameter + CGFloat(count - 1) * spacing + padding * 2
        guard height >= diameter, width + notchGap <= leftArea.width else { return nil }
        let frame = CGRect(x: leftArea.maxX - notchGap - width,
                           y: leftArea.midY - height / 2, width: width, height: height)
        return screen.contains(frame) ? frame : nil
    }

    static func cardFrame(strip: CGRect, screen: CGRect, size: CGSize) -> CGRect {
        let x = max(screen.minX + 8, min(strip.maxX - size.width, screen.maxX - size.width - 8))
        let y = max(screen.minY + 8, strip.minY - 6 - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// Window Server uses a top-left origin relative to the primary display.
    static func windowServerFrame(_ frame: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
    }

    static func coversDisplay(window: CGRect, screen: CGRect) -> Bool {
        abs(window.minX - screen.minX) <= 1 && abs(window.minY - screen.minY) <= 1
            && abs(window.width - screen.width) <= 1 && abs(window.height - screen.height) <= 1
    }

    static func needsPlacement(current: CGRect, target: CGRect) -> Bool {
        // AppKit can round a fractional notch edge to the nearest backing pixel.
        abs(current.minX - target.minX) > 1 || abs(current.minY - target.minY) > 1
            || abs(current.width - target.width) > 1 || abs(current.height - target.height) > 1
    }
}

/// A full-screen window is detected from geometry only, without AX or window titles.
enum NotchHUDVisibility {
    static func shouldShow(enabled: Bool, hasAnchor: Bool, sessionActive: Bool,
                           fullScreen: Bool) -> Bool {
        enabled && hasAnchor && sessionActive && !fullScreen
    }
}

enum NotchHUDInteraction {
    static func shouldDismissClick(point: CGPoint, timestamp: TimeInterval, openedAt: TimeInterval,
                                   strip: CGRect?, card: CGRect?) -> Bool {
        timestamp >= openedAt && strip?.contains(point) != true && card?.contains(point) != true
    }
}

struct NotchHUDQuota {
    let provider: String
    let entry: MenuBarQuotaEntry?
    var display: NotchHUDQuotaDisplay = .used
    var name: String { entry?.name ?? ["codex": "Codex", "claude": "Claude"][provider] ?? provider }
    var window: MenuBarQuotaWindow? {
        guard var entry else { return nil }
        entry.windows = windows.filter { $0.pct != nil }
        return MenuBarFmt.bestWindow(entry)
    }
    /// A locally configured Token budget is not an official subscription quota.
    var windows: [MenuBarQuotaWindow] {
        (entry?.windows ?? []).map { window in
            var result = window
            if window.source != "official" || window.pct?.isFinite != true
                || !(0...100).contains(window.pct ?? -1) {
                result.pct = nil
            }
            return result
        }
    }
    var pct: Double? { window?.pct.flatMap { $0.isFinite ? $0 : nil } }
    var displayedPct: Double? { pct.map { display.percentage(used: $0) } }
    var fraction: Double { displayedPct.map { $0 / 100 } ?? 0 }
    var role: String { MenuBarFmt.quotaUrgency(pct) }
    var value: String {
        guard let pct = displayedPct, let window else { return L10n.text("暂无数据") }
        return MenuBarFmt.quotaMarker(window) + String(format: "%.0f%%", pct)
    }
    var summary: String { pct == nil ? value : display.shortLabel + " " + value }
    var windowSummary: String {
        guard let window else { return L10n.text("暂无官方额度") }
        return [UIFormat.quotaLabel(window.label), L10n.text("官方"),
                window.stale ? L10n.text("数据已过期") : nil].compactMap { $0 }.joined(separator: " · ")
    }
    var glyph: String { MenuBarFmt.providerGlyph[provider] ?? String(name.prefix(1)).uppercased() }
}

struct NotchHUDUsage: Equatable, Sendable {
    struct Hour: Equatable, Identifiable, Sendable {
        var id: String { label }
        let label: String
        let tokens: Int64
    }
    let tokens: Int64?
    let estimatedTokens: Int64
    let excludedFromHours: Int64
    let unallocatedTokens: Int64
    let hours: [Hour]
    var tool: String = ""

    static func load(path: String, provider: String, now: Date = Date()) throws -> Self {
        // Independent connection and fixed "day" range: never mutate the main view's filter.
        let store = try UsageStore(path: path)
        store.nowMs = { Int64(now.timeIntervalSince1970 * 1000) }
        _ = try store.conn.execute("BEGIN DEFERRED")
        defer { _ = try? store.conn.execute("ROLLBACK") }
        let stats = try store.stats(rangeKey: "day", tool: provider)
        let hours = try store.daily(rangeKey: "day").filter { $0.tool == provider }.map {
            Hour(label: $0.day, tokens: $0.stats.tokens)
        }
        return Self(tokens: stats.rows.isEmpty ? nil : stats.total.tokens,
                    estimatedTokens: stats.summary.estimatedTokens,
                    excludedFromHours: max(0, stats.total.tokens - hours.reduce(0) { $0 + $1.tokens }),
                    unallocatedTokens: stats.summary.unallocatedTokens, hours: hours, tool: provider)
    }
}

/// Closing or switching invalidates in-flight results as well as subsequent refreshes.
@MainActor
final class NotchHUDDetailModel: ObservableObject {
    @Published private(set) var provider: String?
    @Published private(set) var usage: NotchHUDUsage?
    @Published private(set) var failed = false
    private var generation = 0
    private var task: Task<Void, Never>?
    private let loader: @Sendable (String) async throws -> NotchHUDUsage

    init(loader: @escaping @Sendable (String) async throws -> NotchHUDUsage) {
        self.loader = loader
    }

    @discardableResult
    func open(_ provider: String) -> Task<Void, Never>? {
        self.provider = provider
        usage = nil
        return refresh()
    }

    @discardableResult
    func refresh() -> Task<Void, Never>? {
        guard let provider else { return nil }
        generation += 1
        let request = generation
        task?.cancel()
        failed = false
        let loader = loader
        task = Task { [weak self] in
            do {
                let usage = try await loader(provider)
                guard let self, !Task.isCancelled, self.generation == request else { return }
                self.usage = usage
            } catch {
                guard let self, !Task.isCancelled, self.generation == request else { return }
                self.usage = nil
                self.failed = true
            }
        }
        return task
    }

    func close() {
        generation += 1
        task?.cancel()
        task = nil
        provider = nil
        usage = nil
        failed = false
    }
}
