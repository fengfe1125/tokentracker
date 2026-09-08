//
//  UpdateChecker.swift
//  TokenTrackerCore
//
//  移植 tokentracker/updatecheck.py：GitHub Releases 更新检查，缓存 24h，
//  网络失败静默，绝不阻塞启动。
//

import Foundation

public struct UpdateInfo: Equatable, Sendable {
    public var latest: String
    public var url: String
    public var checkedAt: Double

    public init(latest: String, url: String, checkedAt: Double) {
        self.latest = latest
        self.url = url
        self.checkedAt = checkedAt
    }

    enum CodingKeys: String, CodingKey {
        case latest, url
        case checkedAt = "checked_at"
    }
}

extension UpdateInfo: Codable {}

public struct UpdateChecker: Sendable {
    public static let repo = "fengfe1125/tokentracker"
    public static let cacheTTL: Double = 24 * 3600

    public let cachePath: String
    public var clock: @Sendable () -> Double
    /// 注入缝：网络抓取（测试注入）。输入 URL，返回响应 Data。
    public var fetch: @Sendable (String) throws -> Data

    public init(cachePath: String? = nil, clock: (@Sendable () -> Double)? = nil,
                fetch: (@Sendable (String) throws -> Data)? = nil) {
        self.cachePath = cachePath ?? NSHomeDirectory() + "/.tokentracker/update_check.json"
        self.clock = clock ?? { Date().timeIntervalSince1970 }
        self.fetch = fetch ?? { url in
            var request = URLRequest(url: URL(string: url)!)
            request.setValue("TokenTracker-update-check", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 5
            final class ResultBox: @unchecked Sendable {
                var result: Result<Data, Error> = .failure(SQLiteError(message: "no response"))
            }
            let box = ResultBox()
            let semaphore = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: request) { data, _, error in
                if let data { box.result = .success(data) }
                else { box.result = .failure(error ?? SQLiteError(message: "unknown")) }
                semaphore.signal()
            }.resume()
            _ = semaphore.wait(timeout: .now() + 8)
            return try box.result.get()
        }
    }

    public static func parseVersion(_ v: String) -> [Int] {
        v.replacingOccurrences(of: "^v", with: "", options: .regularExpression)
            .split(separator: ".")
            .compactMap { $0.allSatisfy(\.isNumber) ? Int($0) : nil }
    }

    public func readCache() -> UpdateInfo? {
        guard let data = FileManager.default.contents(atPath: cachePath),
              let info = try? JSONDecoder().decode(UpdateInfo.self, from: data),
              !info.latest.isEmpty else { return nil }
        return info
    }

    private func writeCache(_ info: UpdateInfo) {
        try? FileManager.default.createDirectory(
            atPath: (cachePath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(info) {
            FileManager.default.createFile(atPath: cachePath, contents: data)
        }
    }

    /// 返回最新发布信息或 nil（离线/无 release 时给过期缓存或 nil）。
    @discardableResult
    public func check(force: Bool = false) -> UpdateInfo? {
        let cached = readCache()
        if !force, let cached, clock() - cached.checkedAt < Self.cacheTTL {
            return cached
        }
        do {
            let data = try fetch("https://api.github.com/repos/\(Self.repo)/releases/latest")
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let info = UpdateInfo(latest: obj["tag_name"] as? String ?? "",
                                  url: obj["html_url"] as? String ?? "",
                                  checkedAt: clock())
            writeCache(info)
            return info
        } catch {
            return cached   // 失败静默：用过期缓存或 nil
        }
    }

    public static func updateAvailable(_ info: UpdateInfo?, current: String) -> Bool {
        guard let info, !info.latest.isEmpty else { return false }
        // Python tuple 比较：逐元素，短序列前缀相等时更长者大
        let latest = parseVersion(info.latest)
        let currentParts = parseVersion(current)
        for index in 0..<max(latest.count, currentParts.count) {
            let l = index < latest.count ? latest[index] : 0
            let c = index < currentParts.count ? currentParts[index] : 0
            if l != c { return l > c }
        }
        return false
    }
}
