//
//  ExpectedExport.swift
//  TokenTrackerCore
//
//  差分测试对照模型：对应 tests/differential/export_python.py 的输出格式
//  （format_version=1）。Phase 1 中 Swift 扫描器将产出同一结构并逐字段比对。
//

import Foundation

/// usage_events 一行的规范化快照（cost 已按 6 位小数舍入）。
public struct ExpectedEvent: Codable, Equatable, Sendable {
    public var tool: String
    public var srcKey: String
    public var sessionID: String
    public var project: String
    public var ts: Int64
    public var model: String
    public var input: Int64
    public var output: Int64
    public var cacheRead: Int64
    public var cacheWrite: Int64
    public var cost: Double?
    public var timeQuality: String
    public var intervalStart: Int64?
    public var costSource: String
    public var sourceKind: String
    public var sourceScope: String

    enum CodingKeys: String, CodingKey {
        case tool, project, ts, model, input, output, cost
        case srcKey = "src_key"
        case sessionID = "session_id"
        case cacheRead = "cache_read"
        case cacheWrite = "cache_write"
        case timeQuality = "time_quality"
        case intervalStart = "interval_start"
        case costSource = "cost_source"
        case sourceKind = "source_kind"
        case sourceScope = "source_scope"
    }
}

public struct ExpectedSessionMeta: Codable, Equatable, Sendable {
    public var tool: String
    public var sessionID: String
    public var title: String

    enum CodingKeys: String, CodingKey {
        case tool, title
        case sessionID = "session_id"
    }
}

public struct ExpectedActivity: Codable, Equatable, Sendable {
    public var agent: String
    public var sessionID: String
    public var turnID: String
    public var rawName: String
    public var canonicalName: String
    public var namespace: String
    public var callID: String
    public var parentCallID: String
    public var startedAt: Int64?
    public var endedAt: Int64?
    public var durationMs: Int64?
    public var status: String
    public var sourceKind: String
    public var confidence: String
    public var skillName: String
    public var skillConfidence: String
    public var srcKey: String

    enum CodingKeys: String, CodingKey {
        case agent, namespace, status, confidence
        case sessionID = "session_id", turnID = "turn_id", rawName = "raw_name"
        case canonicalName = "canonical_name", callID = "call_id"
        case parentCallID = "parent_call_id", startedAt = "started_at", endedAt = "ended_at"
        case durationMs = "duration_ms", sourceKind = "source_kind", skillName = "skill_name"
        case skillConfidence = "skill_confidence", srcKey = "src_key"
    }
}

public struct ScanResultCounts: Codable, Equatable, Sendable {
    public var added: Int
    public var updated: Int
    public var files: Int
    public var counterResets: Int?
    public var activityAdded: Int
    public var activityUpdated: Int
    public var warning: String?
    public var skipped: String?

    enum CodingKeys: String, CodingKey {
        case added, updated, files, warning, skipped
        case activityAdded = "activity_added"
        case activityUpdated = "activity_updated"
        case counterResets = "counter_resets"
    }
}

public struct SnapshotValues: Codable, Equatable, Sendable {
    public var input: Int64?
    public var output: Int64?
    public var cacheRead: Int64?
    public var cacheWrite: Int64?
    public var nativeCost: Double?
    public var nativeSource: String?
    public var accountedCost: Double?
    public var costOffset: Double?
    public var legacyKey: String?

    enum CodingKeys: String, CodingKey {
        case input, output
        case cacheRead = "cache_read"
        case cacheWrite = "cache_write"
        case nativeCost = "native_cost"
        case nativeSource = "native_source"
        case accountedCost = "accounted_cost"
        case costOffset = "cost_offset"
        case legacyKey = "legacy_key"
    }
}

public struct ExpectedSnapshot: Codable, Equatable, Sendable {
    public var tool: String
    public var sourceScope: String
    public var identity: String
    public var observedAt: Int64
    public var revision: Int
    public var values: SnapshotValues

    enum CodingKeys: String, CodingKey {
        case tool, identity, revision, values
        case sourceScope = "source_scope"
        case observedAt = "observed_at"
    }
}

public struct ExpectedExport: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var events: [ExpectedEvent]
    public var activities: [ExpectedActivity]
    public var sessionMeta: [ExpectedSessionMeta]
    public var scanResults: [String: ScanResultCounts]
    public var snapshots: [ExpectedSnapshot]

    enum CodingKeys: String, CodingKey {
        case events, activities, snapshots
        case formatVersion = "format_version"
        case sessionMeta = "session_meta"
        case scanResults = "scan_results"
    }

    public static func load(from url: URL) throws -> ExpectedExport {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ExpectedExport.self, from: data)
    }
}
