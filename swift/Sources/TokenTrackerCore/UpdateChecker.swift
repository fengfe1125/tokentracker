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
    /// 查询时是否包含测试版；旧缓存没有这个字段，视为只查了正式版
    public var beta: Bool?

    public init(latest: String, url: String, checkedAt: Double, beta: Bool? = nil) {
        self.latest = latest
        self.url = url
        self.checkedAt = checkedAt
        self.beta = beta
    }

    enum CodingKeys: String, CodingKey {
        case latest, url, beta
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

    /// 正式版只看 GitHub 标为 latest 的发布；测试版通道看最近的发布列表（含预发布）。
    public static func releasesURL(beta: Bool) -> String {
        "https://api.github.com/repos/\(repo)/releases" + (beta ? "?per_page=30" : "/latest")
    }

    /// 从发布列表里挑版本号最高的一条（跳过草稿）。测试版通道里正式版同样参与比较，
    /// 所以开着测试版也不会停在比最新正式版更旧的预发布上。
    public static func newestRelease(inList data: Data) -> [String: Any]? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return list
            .filter { ($0["draft"] as? Bool) != true && !(($0["tag_name"] as? String) ?? "").isEmpty }
            .max { compareVersions($0["tag_name"] as? String ?? "", $1["tag_name"] as? String ?? "") < 0 }
    }

    /// 返回最新发布信息或 nil（离线/无 release 时给过期缓存或 nil）。
    @discardableResult
    public func check(force: Bool = false, beta: Bool = false) -> UpdateInfo? {
        let cached = readCache()
        // 换了通道，旧缓存答的不是同一个问题
        let sameChannel = (cached?.beta ?? false) == beta
        if !force, let cached, sameChannel, clock() - cached.checkedAt < Self.cacheTTL {
            return cached
        }
        do {
            let data = try fetch(Self.releasesURL(beta: beta))
            let obj: [String: Any] = beta
                ? Self.newestRelease(inList: data) ?? [:]
                : try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let info = UpdateInfo(latest: obj["tag_name"] as? String ?? "",
                                  url: obj["html_url"] as? String ?? "",
                                  checkedAt: clock(), beta: beta)
            writeCache(info)
            return info
        } catch {
            return sameChannel ? cached : nil   // 失败静默：用同通道的过期缓存或 nil
        }
    }

    /// 语义化版本比较：<0 表示 a 更旧。"0.6.0-beta.2" < "0.6.0"，"beta.2" < "beta.10"。
    public static func compareVersions(_ a: String, _ b: String) -> Int {
        func split(_ v: String) -> (core: [Int], pre: [Substring]) {
            let trimmed = v.replacingOccurrences(of: "^v", with: "", options: .regularExpression)
            let parts = trimmed.split(separator: "-", maxSplits: 1)
            let core = (parts.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
            let pre = parts.count > 1 ? parts[1].split(separator: ".") : []
            return (core, pre)
        }
        let (coreA, preA) = split(a), (coreB, preB) = split(b)
        for index in 0..<max(coreA.count, coreB.count) {
            let x = index < coreA.count ? coreA[index] : 0
            let y = index < coreB.count ? coreB[index] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        // 核心版本相同：没有预发布标识的是正式版，更新
        if preA.isEmpty || preB.isEmpty { return preA.isEmpty == preB.isEmpty ? 0 : (preA.isEmpty ? 1 : -1) }
        for index in 0..<max(preA.count, preB.count) {
            guard index < preA.count else { return -1 }
            guard index < preB.count else { return 1 }
            let x = preA[index], y = preB[index]
            if x == y { continue }
            if let nx = Int(x), let ny = Int(y) { return nx < ny ? -1 : 1 }
            if Int(x) != nil { return -1 }        // 数字标识排在字母标识之前
            if Int(y) != nil { return 1 }
            return x < y ? -1 : 1
        }
        return 0
    }

    public static func updateAvailable(_ info: UpdateInfo?, current: String) -> Bool {
        guard let info, !info.latest.isEmpty else { return false }
        return compareVersions(info.latest, current) > 0
    }
}
