//
//  AppLog.swift
//  TokenTrackerApp
//
//  App 诊断日志的唯一入口：本地时间、串行写入、超过上限轮转为 .1（只留一份旧档），
//  文件只给本人读写。开发副本写 app.dev.log，与生产副本互不混写；
//  UI 预览写到临时目录，不碰真实数据目录。
//

import Foundation

enum AppLog {
    static let maxBytes = 512 * 1024

    static var defaultPath: String {
        let env = ProcessInfo.processInfo.environment
        if env["TT_UI_PREVIEW"] == "1" { return NSTemporaryDirectory() + "tokentracker-preview.log" }
        let name = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true ? "app.dev.log" : "app.log"
        return NSHomeDirectory() + "/.tokentracker/" + name
    }

    private static let queue = DispatchQueue(label: "tt.app-log", qos: .utility)

    /// 异步追加一行（不阻塞调用方，通常是主线程）。
    static func write(_ message: String, to path: String = defaultPath, now: Date = Date()) {
        queue.async { append(line(message, at: now), to: path) }
    }

    /// 同步版本，供测试确定落盘时机。
    static func writeSync(_ message: String, to path: String, now: Date = Date()) {
        queue.sync { append(line(message, at: now), to: path) }
    }

    static func line(_ message: String, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date) + " " + message + "\n"
    }

    private static func append(_ text: String, to path: String) {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        }
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size > maxBytes {
            let rotated = path + ".1"
            try? fm.removeItem(atPath: rotated)
            try? fm.moveItem(atPath: path, toPath: rotated)
        }
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        // 旧版本创建的日志是 0644：顺手收紧。
        var info = stat()
        if fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 != 0 {
            _ = fchmod(fd, info.st_mode & 0o700)
        }
        let data = Data(text.utf8)
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = Darwin.write(fd, base, buffer.count)
        }
    }
}
