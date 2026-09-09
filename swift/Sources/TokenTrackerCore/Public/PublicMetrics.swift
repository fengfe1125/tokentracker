//
//  PublicMetrics.swift
//  TokenTrackerCore
//
//  公开统计的纯计算层：连续天数 / 峰值 / 最长连续聊天段。
//  不碰数据库、不联网、不读时钟 —— 全部可用数组 fixture 直接单测。
//
//  规则会演进（比如「只认 exact」就是第一次），所以刻意不写进 SQL 字符串里：
//  写在这里才能被评审、被测试。
//

import Foundation

/// 参与「最长连续段」折算的最小事件。必须按 (tool, session, ts) 有序喂入。
public struct BurstEvent: Equatable, Sendable {
    public var tool: String
    public var session: String
    public var ts: Int64

    public init(tool: String, session: String, ts: Int64) {
        self.tool = tool
        self.session = session
        self.ts = ts
    }
}

/// 一段中间没有超过阈值空闲的连续对话。
public struct Burst: Equatable, Sendable {
    public var tool: String
    public var seconds: Int64
    public var events: Int
    public var startMs: Int64

    public init(tool: String, seconds: Int64, events: Int, startMs: Int64) {
        self.tool = tool
        self.seconds = seconds
        self.events = events
        self.startMs = startMs
    }
}

/// 连续活跃天数。
public struct Streaks: Equatable, Sendable {
    public var current: Int
    public var longest: Int

    public init(current: Int, longest: Int) {
        self.current = current
        self.longest = longest
    }
}

public enum PublicMetrics {
    /// 默认空闲阈值：30 分钟。
    public static let defaultGapMs: Int64 = 1_800_000

    // ------------------------------------------------------ 最长连续段 ----

    /// 把每个 (tool, session) 按空闲切段，取最长的一段。
    ///
    /// 输入**必须**按 (tool, session, ts) 有序 —— 这是折算的前置条件，不要放松。
    /// 空闲「严格大于」gapMs 才切段：正好等于阈值仍算同一段。
    /// 只有单个事件的会话不构成「聊天」，不参与比较；全是单事件时返回 nil。
    /// session_id 只在 tool 内唯一，所以跨 tool 的同名会话绝不合并。
    /// O(n) 时间、O(1) 空间。
    public static func longestBurst(_ events: [BurstEvent],
                                    gapMs: Int64 = defaultGapMs) -> Burst? {
        var best: Burst?
        var runTool = ""
        var runSession: String?
        var runStart: Int64 = 0
        var runEnd: Int64 = 0
        var runCount = 0

        func flush() {
            guard runCount >= 2 else { return }
            let seconds = (runEnd - runStart) / 1000
            if best == nil || seconds > best!.seconds {
                best = Burst(tool: runTool, seconds: seconds, events: runCount, startMs: runStart)
            }
        }

        for event in events {
            let continues = runSession != nil
                && event.tool == runTool
                && event.session == runSession!
                && event.ts - runEnd <= gapMs
            if continues {
                runEnd = event.ts
                runCount += 1
            } else {
                flush()
                runTool = event.tool
                runSession = event.session
                runStart = event.ts
                runEnd = event.ts
                runCount = 1
            }
        }
        flush()
        return best
    }

    // -------------------------------------------------------- 连续天数 ----

    /// 连续活跃天数。activeDays 与 today 都是 timeZone 下的 "yyyy-MM-dd"。
    ///
    /// current 从 today 往回走；今天还没开工时从昨天起算（宽限），昨天也没有才算断 ——
    /// 否则每天零点到第一次调用之间，页面上的连续天数都会显示成 0。
    /// longest 是全历史最长的一段。
    ///
    /// 日期加减一律走 Calendar，绝不用 ts ± 86_400_000：夏令时会让后者少一天或多一天。
    public static func streaks(activeDays: Set<String>, today: String,
                               timeZone: TimeZone) -> Streaks {
        guard !activeDays.isEmpty else { return Streaks(current: 0, longest: 0) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        func shift(_ day: String, _ delta: Int) -> String? {
            guard let date = formatter.date(from: day),
                  let moved = calendar.date(byAdding: .day, value: delta, to: date)
            else { return nil }
            return formatter.string(from: moved)
        }

        var current = 0
        var cursor: String? = activeDays.contains(today) ? today : shift(today, -1)
        while let day = cursor, activeDays.contains(day) {
            current += 1
            cursor = shift(day, -1)
        }

        // 只有「前一天不活跃」的日子才是段首，从段首往后数一次，全程 O(n)。
        var longest = 0
        for day in activeDays {
            if let previous = shift(day, -1), activeDays.contains(previous) { continue }
            var run = 0
            var walker: String? = day
            while let current = walker, activeDays.contains(current) {
                run += 1
                walker = shift(current, 1)
            }
            longest = max(longest, run)
        }
        return Streaks(current: current, longest: longest)
    }

    // ------------------------------------------------------------ 峰值 ----

    /// 峰值日。喂入与热力图同一份分桶序列，保证头条数字一定能在图上指出来。
    /// 并列取较晚的日期。全零序列返回 nil。
    public static func peakDay(_ series: [(day: String, tokens: Int64)])
        -> (day: String, tokens: Int64)? {
        var best: (day: String, tokens: Int64)?
        for point in series where point.tokens > 0 {
            guard let incumbent = best else { best = point; continue }
            if point.tokens > incumbent.tokens
                || (point.tokens == incumbent.tokens && point.day > incumbent.day) {
                best = point
            }
        }
        return best
    }
}
