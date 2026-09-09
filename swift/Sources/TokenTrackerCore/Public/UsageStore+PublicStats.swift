//
//  UsageStore+PublicStats.swift
//  TokenTrackerCore
//
//  公开统计需要的两条查询。日序列、总量和未定位量全部复用既有的
//  daily(rangeKey:) / stats(rangeKey:)，这里只补它们给不出的东西。
//

import Foundation

extension UsageStore {
    /// 「最长连续段」的事件流，已按折算所需顺序排好。
    ///
    /// 只取 time_quality='exact'。这不是保守起见，是必须：opencode 与 hermes
    /// 全部走累计快照，它们的 ts 是**扫描时刻**而非事件时刻，观测点约 18 分钟一个，
    /// 会被 30 分钟阈值全部串成一段，得出「连续聊了 42 小时」这种数字。
    ///
    /// 不为此加索引 —— 三万多行的临时排序只要个位数毫秒，
    /// 而加索引要动 schema 版本和迁移。
    public func burstEvents() throws -> [BurstEvent] {
        try conn.query("""
            SELECT tool, session_id, ts FROM usage_events
             WHERE time_quality='exact' AND session_id!=''
             ORDER BY tool, session_id, ts
            """).map {
            BurstEvent(tool: $0.string("tool"),
                       session: $0.string("session_id"),
                       ts: $0.int("ts"))
        }
    }

    /// 每个工具的事件总数与其中 exact 的条数。
    /// exact 为 0 的工具只有累计快照，必须在公开页面上标注它不参与时长统计。
    public func eventQualityByTool() throws -> [(tool: String, events: Int64, exact: Int64)] {
        try conn.query("""
            SELECT tool, COUNT(*) AS events,
                   COALESCE(SUM(CASE WHEN time_quality='exact' THEN 1 ELSE 0 END),0) AS exact_events
              FROM usage_events GROUP BY tool ORDER BY tool
            """).map {
            (tool: $0.string("tool"), events: $0.int("events"), exact: $0.int("exact_events"))
        }
    }
}
