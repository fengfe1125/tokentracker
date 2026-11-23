//
//  AntigravityScanner.swift
//  TokenTrackerCore
//
//  扫描 Google Antigravity 本地会话日志：
//    ~/.gemini/antigravity/brain/<conversation-id>/.system_generated/logs/transcript.jsonl
//    ~/.gemini/antigravity-cli/brain/<conversation-id>/.system_generated/logs/transcript.jsonl
//    ~/.gemini/antigravity-ide/brain/<conversation-id>/.system_generated/logs/transcript.jsonl
//
//  - 只扫 transcript.jsonl，不扫 transcript_full.jsonl（防止重复计数且体积更小）。
//  - input_tokens 已扣除 cache_read_tokens，四列与 TokenTracker 互斥口径直接对齐。
//  - 以 <conversation-id>|step_<step_index> 为幂等键，支持字节游标增量扫描与单调更新。
//  - 会话工作区取自 Antigravity 自带的 conversation_summaries.db（只读 conversation_id / workspace_uris），
//    启用可选的 hooks.json 工作区映射时以 Hook 记录为准，据此把会话自动归属到对应工作区目录。
//

import Foundation

public struct AntigravityScanner: ScannerAdapter {
    public let name = "antigravity"
    public let detail = "~/.gemini/antigravity*/brain/*/.system_generated/logs/transcript.jsonl"
    public let roots: [String]
    public let workspaceMapPath: String
    static let parserVersion = 1

    public init(roots: [String], workspaceMapPath: String = AntigravityWorkspaceMap.defaultPath) {
        self.roots = roots.map(expandPath)
        self.workspaceMapPath = expandPath(workspaceMapPath)
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    public func detect() -> Bool {
        roots.contains(where: isDirectory)
    }

    public static func inferredProvider(for model: String) -> String {
        let value = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("gemini-") || value.hasPrefix("gemma-") { return "google" }
        if value.hasPrefix("claude-") { return "anthropic" }
        if value.hasPrefix("gpt-") || value.hasPrefix("o1") || value.hasPrefix("o3")
            || value.hasPrefix("o4") || value.hasPrefix("codex-") { return "openai" }
        if value.hasPrefix("deepseek-") { return "deepseek" }
        if value.hasPrefix("kimi-") { return "moonshot" }
        if value.hasPrefix("grok-") { return "xai" }
        if value.hasPrefix("minimax-") { return "minimax" }
        return ""
    }

    private func ms(from obj: [String: Any], fallback: Int64) -> Int64 {
        for key in ["created_at", "timestamp"] {
            if let ts = obj[key] as? String, let parsed = parseISODateMs(ts) { return parsed }
            if let num = obj[key] as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID() {
                let d = num.doubleValue
                if d > 0 { return Int64(d < 1e12 ? d * 1000 : d) }
            }
        }
        return fallback
    }

    private func discoverTranscripts() -> [(sessionID: String, path: String)] {
        let fm = FileManager.default
        var seen: Set<String> = []
        var found: [(sessionID: String, path: String)] = []
        for root in roots where isDirectory(root) {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries.sorted() {
                guard !entry.hasPrefix(".") else { continue }
                let transcript = (((root as NSString)
                    .appendingPathComponent(entry) as NSString)
                    .appendingPathComponent(".system_generated/logs/transcript.jsonl"))
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: transcript, isDirectory: &isDir), !isDir.boolValue else { continue }
                let resolved = realPath(transcript)
                guard seen.insert(resolved).inserted else { continue }
                found.append((sessionID: entry, path: transcript))
            }
        }
        found.sort { $0.path < $1.path }
        return found
    }

    private func isSubagentTool(_ rawName: String, args: Any?) -> Bool {
        let low = rawName.lowercased()
        if low == "invoke_subagent" { return true }
        if low == "swarm", let dict = args as? [String: Any],
           let action = dict["action"] as? String {
            return action.lowercased().contains("add")
        }
        return false
    }

    private func flattenedArgText(_ args: Any?) -> Any? {
        guard let dict = args as? [String: Any] else { return args }
        let pieces = dict.values.compactMap { value -> String? in
            guard let raw = value as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
                return String(trimmed.dropFirst().dropLast())
            }
            return trimmed
        }
        return pieces.isEmpty ? args : pieces.joined(separator: " ")
    }

    private func recordDerivedSkill(_ store: UsageStore, sessionID: String, stepTag: String,
                                    toolIndex: Int, startedAt: Int64, rawName: String,
                                    args: Any?) throws -> (added: Int, updated: Int) {
        let low = rawName.lowercased()
        guard ["read_file", "view_file"].contains(low) else { return (0, 0) }
        let skill = ActivityNormalizer.skill(rawName: rawName,
                                             arguments: flattenedArgText(args),
                                             allowPath: true)
        guard skill.confidence == "derived", !skill.name.isEmpty else { return (0, 0) }
        return try store.putActivityEvent(ActivityEvent(
            agent: name,
            sessionID: sessionID,
            turnID: stepTag,
            rawName: "skill_file",
            canonicalName: "skill.activate",
            namespace: "built-in",
            callID: "",
            parentCallID: "\(sessionID)|tool|\(stepTag)|\(toolIndex)",
            startedAt: startedAt,
            endedAt: startedAt,
            durationMs: 0,
            status: "unknown",
            sourceKind: "antigravity_skill_file",
            confidence: "derived",
            skillName: skill.name,
            skillConfidence: "derived",
            srcKey: "\(sessionID)|skill|\(stepTag)|\(toolIndex)",
            eventKind: .skill,
            eventLayer: .execution))
    }

    private func resultStatus(_ obj: [String: Any]) -> String {
        let raw = (obj["status"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch raw {
        case "DONE", "SUCCESS", "COMPLETED", "OK": return "success"
        case "ERROR", "INVALID", "FAILED", "FAILURE": return "error"
        case "DENIED", "REJECTED", "BLOCKED": return "denied"
        default: return "unknown"
        }
    }

    private func scanLine(_ obj: [String: Any], fallbackKey: String, sessionID: String,
                          workspace: String, mtimeMs: Int64, prices: PriceTable,
                          store: UsageStore,
                          pendingCalls: inout [(srcKey: String, startedAt: Int64)]) throws -> (Int, Int, Int, Int, String?) {
        let kind = obj["type"] as? String ?? ""
        if kind == "USER_INPUT" {
            pendingCalls.removeAll()
            let title = userText(obj)
            return (0, 0, 0, 0, title.isEmpty ? nil : title)
        }
        if kind == "GENERIC", (obj["source"] as? String) != "USER_EXPLICIT", !pendingCalls.isEmpty {
            let current = pendingCalls.removeFirst()
            let status = resultStatus(obj)
            guard status != "unknown" else {
                // 仍在 RUNNING：放回队首等待后续增量扫描拿到终态
                pendingCalls.insert(current, at: 0)
                return (0, 0, 0, 0, nil)
            }
            let endedAt = ms(from: obj, fallback: mtimeMs)
            let duration: Int64? = endedAt >= current.startedAt ? endedAt - current.startedAt : nil
            let updated = try store.completeActivityBySrcKey(
                agent: name, srcKey: current.srcKey, status: status,
                endedAt: endedAt, durationMs: duration)
            return (0, 0, 0, updated, nil)
        }
        guard kind == "PLANNER_RESPONSE" else {
            return (0, 0, 0, 0, nil)
        }

        pendingCalls.removeAll()
        let ts = ms(from: obj, fallback: mtimeMs)
        let stepID = jsonIdentifier(obj["step_index"])
        let stepTag = stepID.isEmpty ? fallbackKey : "step_\(stepID)"
        var activityAdded = 0
        var activityUpdated = 0

        for (index, rawCall) in (obj["tool_calls"] as? [Any] ?? []).enumerated() {
            guard let call = rawCall as? [String: Any],
                  let rawName = call["name"] as? String, !rawName.isEmpty else { continue }
            let callID = jsonIdentifier(call["id"], call["toolCallId"])
            let args = jsonOrAny(call["args"], call["arguments"], call["input"])
            let isAgent = isSubagentTool(rawName, args: args)
            let key = "\(sessionID)|\(isAgent ? "agent" : "tool")|\(callID.isEmpty ? "\(stepTag)|\(index)" : callID)"
            let change = try store.recordActivity(
                agent: name,
                srcKey: key,
                rawName: rawName,
                sessionID: sessionID,
                turnID: stepTag,
                callID: callID,
                startedAt: ts,
                status: "unknown",
                sourceKind: isAgent ? "antigravity_subagent" : "antigravity_jsonl",
                confidence: "exact",
                arguments: args,
                eventKind: isAgent ? .agent : nil,
                eventLayer: isAgent ? .lifecycle : .execution)
            activityAdded += change.added
            activityUpdated += change.updated
            pendingCalls.append((srcKey: key, startedAt: ts))

            let derived = try recordDerivedSkill(store, sessionID: sessionID, stepTag: stepTag,
                                                 toolIndex: index, startedAt: ts,
                                                 rawName: rawName, args: args)
            activityAdded += derived.added
            activityUpdated += derived.updated
        }

        let usage = (obj["usage"] as? [String: Any]) ?? obj
        var inp = jsonInt(usage["input_tokens"])
        var outp = jsonInt(usage["output_tokens"])
        var cr = jsonOrInt(usage["cache_read_tokens"], usage["cache_read_input_tokens"])
        var cw = jsonOrInt(usage["cache_write_tokens"],
                           jsonOrAny(usage["cache_creation_tokens"], usage["cache_creation_input_tokens"]))
        if inp + outp + cr + cw == 0 {
            return (0, 0, activityAdded, activityUpdated, nil)
        }

        let model = jsonOrString(obj["model"], obj["model_name"])
        let sourceKey = "\(sessionID)|\(stepTag)"
        let old = try store.conn.queryOne(
            "SELECT input,output,cache_read,cache_write,project FROM usage_events WHERE tool=? AND src_key=?",
            [name, sourceKey])
        let effectiveProject: String
        if let old {
            inp = max(inp, old.int("input"))
            outp = max(outp, old.int("output"))
            cr = max(cr, old.int("cache_read"))
            cw = max(cw, old.int("cache_write"))
            let existingProject = old.string("project")
            effectiveProject = !workspace.isEmpty ? workspace : existingProject
            if (inp, outp, cr, cw) == (old.int("input"), old.int("output"),
                                       old.int("cache_read"), old.int("cache_write"))
                && effectiveProject == existingProject {
                if effectiveProject.hasPrefix("/") {
                    try store.recordProjectPath(tool: name, srcKey: sourceKey, path: effectiveProject)
                }
                return (0, 0, activityAdded, activityUpdated, nil)
            }
        } else {
            effectiveProject = workspace
        }

        let inferred = Self.inferredProvider(for: model)
        let quote = prices.quote(provider: inferred.isEmpty ? nil : inferred,
                                 model: model, input: inp, output: outp,
                                 cacheRead: cr, cacheWrite: cw, eventAtMs: ts)
        let added = try store.putEvent(
            tool: name,
            srcKey: sourceKey,
            sessionID: sessionID,
            project: effectiveProject,
            ts: ts,
            model: model,
            input: inp,
            output: outp,
            cacheRead: cr,
            cacheWrite: cw,
            cost: quote?.cost,
            replace: old != nil,
            sourceKind: "antigravity_jsonl",
            provider: quote?.provider ?? inferred,
            priceVersionID: quote?.priceVersionID)
        return old == nil
            ? (added, 0, activityAdded, activityUpdated, nil)
            : (0, 1, activityAdded, activityUpdated, nil)
    }

    private func backfillWorkspace(_ workspace: String, sessionID: String, store: UsageStore) throws {
        guard workspace.hasPrefix("/") else { return }
        _ = try store.conn.execute(
            "UPDATE usage_events SET project=? WHERE tool=? AND session_id=? AND project=''",
            [workspace, name, sessionID])
        let rows = try store.conn.query(
            "SELECT src_key FROM usage_events WHERE tool=? AND session_id=?",
            [name, sessionID])
        for row in rows {
            try store.recordProjectPath(tool: name, srcKey: row.string("src_key"), path: workspace)
        }
    }

    public func scan(_ store: UsageStore, _ prices: PriceTable, full: Bool) throws -> ScanOutcome {
        var cursor = try store.getScanCursor(tool: name)
        let effectiveFull = full
            || (cursor["parser_version"] as? NSNumber)?.intValue != Self.parserVersion
            || activityNeedsBackfill(cursor)
        var outcome = ScanOutcome()
        // Hook 映射 + Antigravity 自带会话索引；内容摘要变化（含首次升级）时回填已扫会话的项目归属。
        let workspaceMap = AntigravityWorkspaceMap.load(path: workspaceMapPath, roots: roots)
        let digestCursorKey = "workspace_digest"
        let workspaceDigest = AntigravityWorkspaceMap.digest(workspaceMap)
        let workspaceMapChanged = !workspaceMap.isEmpty
            && (effectiveFull || (cursor[digestCursorKey] as? String) != workspaceDigest)

        let transcripts = discoverTranscripts()
        var backfilledSessions: Set<String> = []

        for (sessionID, path) in transcripts {
            let workspace = workspaceMap[sessionID] ?? ""
            if !effectiveFull && !fingerprintChanged(cursor: cursor, path: path) {
                if workspaceMapChanged, !workspace.isEmpty, backfilledSessions.insert(sessionID).inserted {
                    try backfillWorkspace(workspace, sessionID: sessionID, store: store)
                }
                continue
            }
            guard let statKey = StatKey(path: path) else { continue }
            outcome.files += 1

            var title: String?
            let mtimeMs = statKey.m / 1_000_000
            let prevOffset: Int64 = effectiveFull ? 0 : ((cursor[path] as? [String: Any])
                .flatMap { ($0["o"] as? NSNumber)?.int64Value } ?? 0)
            var newOffset: Int64 = 0
            var delta: [(Int64, [String: Any])]?
            if prevOffset > 0 {
                let (items, offset) = readJSONLDelta(path: path, offset: prevOffset)
                if offset < 0 {
                    delta = nil
                } else {
                    delta = items
                    newOffset = offset
                }
            }

            var pendingCalls: [(srcKey: String, startedAt: Int64)] = []
            if delta == nil {
                for (lineno, obj) in iterJSONL(path) {
                    let (a, u, aa, au, t) = try scanLine(
                        obj, fallbackKey: String(lineno), sessionID: sessionID,
                        workspace: workspace, mtimeMs: mtimeMs, prices: prices, store: store,
                        pendingCalls: &pendingCalls)
                    outcome.added += a; outcome.updated += u
                    outcome.activityAdded += aa; outcome.activityUpdated += au
                    if let t, title == nil { title = t }
                }
                newOffset = statKey.s
            } else if let delta {
                if let saved = (cursor[path] as? [String: Any])?["pending"] as? [[String: Any]] {
                    pendingCalls = saved.compactMap { item in
                        guard let key = item["k"] as? String, !key.isEmpty else { return nil }
                        return (srcKey: key, startedAt: jsonInt(item["t"]))
                    }
                }
                for (lineOffset, obj) in delta {
                    let (a, u, aa, au, t) = try scanLine(
                        obj, fallbackKey: "b\(lineOffset)", sessionID: sessionID,
                        workspace: workspace, mtimeMs: mtimeMs, prices: prices, store: store,
                        pendingCalls: &pendingCalls)
                    outcome.added += a; outcome.updated += u
                    outcome.activityAdded += aa; outcome.activityUpdated += au
                    if let t, title == nil { title = t }
                }
            }

            var snapshot: [String: Any] = statKey.asDict
            snapshot["o"] = newOffset
            if !pendingCalls.isEmpty {
                snapshot["pending"] = pendingCalls.map { ["k": $0.srcKey, "t": $0.startedAt] }
            }
            cursor[path] = snapshot
            if let title {
                try store.setSessionTitle(tool: name, sessionID: sessionID, title: title,
                                          onlyIfMissing: delta != nil)
            }
            if !workspace.isEmpty, backfilledSessions.insert(sessionID).inserted {
                try backfillWorkspace(workspace, sessionID: sessionID, store: store)
            }
        }

        if workspaceMapChanged {
            for (sessionID, workspace) in workspaceMap where !backfilledSessions.contains(sessionID) {
                try backfillWorkspace(workspace, sessionID: sessionID, store: store)
            }
            cursor[digestCursorKey] = workspaceDigest
        }

        cursor["parser_version"] = Self.parserVersion
        markActivityCurrent(&cursor)
        try store.setScanCursor(tool: name, cursor: cursor)
        return outcome
    }
}
