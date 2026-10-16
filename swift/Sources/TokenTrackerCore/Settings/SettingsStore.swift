//
//  SettingsStore.swift
//  TokenTrackerCore
//
//  移植自 tokentracker/prefs.py + server.py 的 _SETTINGS_SCHEMA：
//  ~/.tokentracker/settings.json 的读写、默认值与白名单校验（未列出的键拒绝）。
//  状态栏轮询文件变化热生效，无需重启。
//

import Foundation

public struct SettingsStore {
    public static let terminalApps = ["auto", "terminal", "iterm", "wezterm", "ghostty"]

    public nonisolated(unsafe) static let defaults: [String: Any] = [
        "menubar_provider": "claude",   // 状态栏标题追加显示的平台配额；"off" = 仅今日用量
        "menubar_compact": false,       // 紧凑标题（刘海屏防挤出）
        "menubar_ring": true,           // 圆环显示配额（彩色扇形圆代替 ⚡）
        "launch_at_login": false,       // 开机自动启动（SMAppService）
        "terminal_app": "auto",         // 继续会话用哪个终端
        "unit_yi": false,               // 大数以「亿」显示
        "scan_interval": 60,            // 自动扫描/刷新节奏（秒）
        "price_sync_enabled": true,     // 每 24 小时自动同步官方公开 API 费率

        // 公开统计上报。默认关闭不可协商 —— 这是个把数据发到公网的开关。
        "publish_enabled": false,       // 扫描结束后自动上报
        "publish_endpoint": "",         // 形如 https://tt.example.com（必须 https）
        "publish_handle": "",           // 服务上的用户名
        "publish_days": 365,            // 热力图窗口天数
    ]

    public let path: String

    public init(path: String? = nil) {
        self.path = path
            ?? NSHomeDirectory() + "/.tokentracker/settings.json"
    }

    public func load() -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return [:] }
        return dict
    }

    /// 原子写入（tmp + rename），对齐 Python save_prefs。
    public func save(_ prefs: [String: Any]) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: prefs) else { return }
        let tmp = path + ".tmp"
        FileManager.default.createFile(atPath: tmp, contents: data)
        _ = try? FileManager.default.replaceItemAt(URL(fileURLWithPath: path),
                                                   withItemAt: URL(fileURLWithPath: tmp))
        // replaceItemAt 对已存在目标原子替换；目标不存在时回退 rename
        if FileManager.default.fileExists(atPath: tmp) {
            try? FileManager.default.moveItem(atPath: tmp, toPath: path)
        }
    }

    // ---------------------------------------------------------- 校验 ----

    private static let providerPattern = try! NSRegularExpression(
        pattern: #"off|[a-z0-9][a-z0-9_-]{0,23}"#)
    /// 只接受 https：bearer token 走明文就是凭据泄漏。
    private static let endpointPattern = try! NSRegularExpression(
        pattern: #"https://[a-z0-9.-]{3,64}(:[0-9]{2,5})?(/[A-Za-z0-9._~/-]{0,64})?"#)
    private static let handlePattern = try! NSRegularExpression(
        pattern: #"[a-z0-9][a-z0-9-]{1,30}"#)

    private static func fullMatch(_ regex: NSRegularExpression, _ v: String) -> Bool {
        let range = NSRange(v.startIndex..., in: v)
        return regex.firstMatch(in: v, range: range)?.range == range
    }

    public static func isValid(key: String, value: Any) -> Bool {
        switch key {
        case "menubar_provider":
            guard let v = value as? String else { return false }
            let range = NSRange(v.startIndex..., in: v)
            return providerPattern.firstMatch(in: v, range: range)?.range == range
        case "menubar_compact", "menubar_ring", "launch_at_login", "unit_yi", "publish_enabled",
             "price_sync_enabled":
            return (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        case "publish_endpoint":
            guard let v = value as? String else { return false }
            return v.isEmpty || (v.count <= 200 && fullMatch(endpointPattern, v))
        case "publish_handle":
            guard let v = value as? String else { return false }
            return v.isEmpty || fullMatch(handlePattern, v)
        case "publish_days":
            return [90, 365, 730].contains((value as? NSNumber)?.intValue ?? 0)
        case "terminal_app":
            return (value as? String).map { terminalApps.contains($0) } ?? false
        case "scan_interval":
            return [30, 60, 300, 600].contains((value as? NSNumber)?.intValue ?? 0)
        default:
            return false
        }
    }

    /// 对齐 _settings_payload：默认值 + 通过白名单校验的已存值。
    public func effective() -> [String: Any] {
        var settings = SettingsStore.defaults
        for (key, value) in load() where SettingsStore.isValid(key: key, value: value) {
            settings[key] = value
        }
        return settings
    }

    /// 写入单个键（先校验，与现有偏好合并后原子保存）。
    @discardableResult
    public func set(key: String, value: Any) -> Bool {
        guard SettingsStore.isValid(key: key, value: value) else { return false }
        var prefs = load()
        prefs[key] = value
        save(prefs)
        return true
    }

    /// 一次校验并原子保存多个设置，避免表单保存到一半时被 5 秒轮询读到。
    @discardableResult
    public func set(values: [String: Any]) -> Bool {
        guard values.allSatisfy({ SettingsStore.isValid(key: $0.key, value: $0.value) })
        else { return false }
        var prefs = load()
        for (key, value) in values { prefs[key] = value }
        save(prefs)
        return true
    }

    // 便捷读取
    public func effectiveString(_ key: String) -> String? { effective()[key] as? String }
    public func effectiveBool(_ key: String) -> Bool {
        (effective()[key] as? NSNumber)?.boolValue ?? false
    }
    public func effectiveInt(_ key: String) -> Int? { (effective()[key] as? NSNumber)?.intValue }
}
