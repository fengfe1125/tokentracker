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

    public static func isValid(key: String, value: Any) -> Bool {
        switch key {
        case "menubar_provider":
            guard let v = value as? String else { return false }
            let range = NSRange(v.startIndex..., in: v)
            return providerPattern.firstMatch(in: v, range: range)?.range == range
        case "menubar_compact", "menubar_ring", "launch_at_login", "unit_yi":
            return (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        case "terminal_app":
            return (value as? String).map { terminalApps.contains($0) } ?? false
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

    // 便捷读取
    public func effectiveString(_ key: String) -> String? { effective()[key] as? String }
    public func effectiveBool(_ key: String) -> Bool {
        (effective()[key] as? NSNumber)?.boolValue ?? false
    }
}
