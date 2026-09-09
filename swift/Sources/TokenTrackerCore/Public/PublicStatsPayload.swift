//
//  PublicStatsPayload.swift
//  TokenTrackerCore
//
//  公开统计载荷 v1 —— 会被发到公网、进 CDN 缓存、且不可撤销。
//
//  这里的每个字段都是**逐条论证过**才放进来的白名单。全部手写 CodingKeys，
//  绝不对任何含数据库行的类型做反射编码。以下字段明确禁止出现，
//  新增任何字段都会让 PublicStatsTests 的 golden fixture 断言失败：
//
//      model / session_id / project / title / src_key / interval_start
//      会话数 / 事件数 / 主机名 / 账号 id / 配额与套餐 / 任何原始时间戳
//

import Foundation

public struct PublicStatsPayload: Codable, Equatable, Sendable {

    /// 统计窗口。from/to 是 tz 下的自然日，闭区间，days 即 daily.tokens 的长度。
    public struct DayRange: Codable, Equatable, Sendable {
        public var from: String
        public var to: String
        public var days: Int
    }

    /// 全历史总量。三个 token 数满足 dated + undated == tokens，恒等成立。
    public struct Totals: Codable, Equatable, Sendable {
        /// 全量，含无法定位到某一天的历史。
        public var tokens: Int64
        /// 能定位到某一天的部分，等于全历史日序列之和。
        public var tokensDated: Int64
        /// 差额：存量无法还原时间的历史，加上跨日的观察区间。热力图不含这部分。
        public var tokensUndated: Int64
        public var costUsd: Double
        public var costUsdUndated: Double
        public var activeDays: Int

        enum CodingKeys: String, CodingKey {
            case tokens
            case tokensDated = "tokens_dated"
            case tokensUndated = "tokens_undated"
            case costUsd = "cost_usd"
            case costUsdUndated = "cost_usd_undated"
            case activeDays = "active_days"
        }
    }

    /// 热力图数据。整数数组而非对象数组 —— 365 天约 4.5KB，730 天仍远低于 32KB 上限。
    public struct Daily: Codable, Equatable, Sendable {
        public var start: String
        public var tokens: [Int64]
        /// 等于 tokens 之和。冗余，但让校验器能抓出被截断的数组。
        public var windowTokens: Int64

        enum CodingKeys: String, CodingKey {
            case start, tokens
            case windowTokens = "window_tokens"
        }
    }

    public struct Peak: Codable, Equatable, Sendable {
        public var day: String
        public var tokens: Int64
    }

    public struct Streak: Codable, Equatable, Sendable {
        public var current: Int
        public var longest: Int
        public var asOf: String

        enum CodingKeys: String, CodingKey {
            case current, longest
            case asOf = "as_of"
        }
    }

    /// 最长连续聊天段。basis 与 gap_minutes 让这个指标可被证伪。
    public struct LongestBurst: Codable, Equatable, Sendable {
        public var seconds: Int64
        public var day: String
        public var agent: String
        public var gapMinutes: Int
        /// 恒为 "exact"：只有带精确时间戳的工具参与统计。
        public var basis: String

        enum CodingKeys: String, CodingKey {
            case seconds, day, agent, basis
            case gapMinutes = "gap_minutes"
        }
    }

    /// 单个 CLI 工具。id 限定在 ScannerRegistry.all 之内。
    public struct Agent: Codable, Equatable, Sendable {
        public var id: String
        public var tokens: Int64
        public var costUsd: Double

        enum CodingKeys: String, CodingKey {
            case id, tokens
            case costUsd = "cost_usd"
        }
    }

    /// 口径披露。docs/metrics.md 要求界面说明被排除的用量。
    public struct Caveats: Codable, Equatable, Sendable {
        public var undatedShare: Double
        /// 只有累计快照、没有精确时间戳的工具，不参与最长连续段统计。
        public var snapshotOnlyAgents: [String]

        enum CodingKeys: String, CodingKey {
            case undatedShare = "undated_share"
            case snapshotOnlyAgents = "snapshot_only_agents"
        }
    }

    public var v: Int
    /// 取整到小时。分钟级精度连续几个月就是一条「这台机器何时醒着」的作息信号。
    public var generatedAt: String
    public var tz: String
    public var tzOffsetMinutes: Int
    public var appVersion: String
    public var range: DayRange
    public var totals: Totals
    public var daily: Daily
    /// 全零序列时**整个键省略**（Swift 合成编码器对 Optional 走 encodeIfPresent）。
    public var peak: Peak?
    public var streak: Streak
    /// 没有任何多事件会话时**整个键省略**，同 peak。校验器与组件都必须按「键可能不存在」处理。
    public var longestBurst: LongestBurst?
    public var agents: [Agent]
    public var caveats: Caveats

    enum CodingKeys: String, CodingKey {
        case v
        case generatedAt = "generated_at"
        case tz
        case tzOffsetMinutes = "tz_offset_minutes"
        case appVersion = "app_version"
        case range, totals, daily, peak, streak
        case longestBurst = "longest_burst"
        case agents, caveats
    }

    /// 稳定序列化：键排序 + 不转义斜杠。内容去重的哈希与 golden fixture 都依赖它。
    public func encoded(pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty
            ? [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
            : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
