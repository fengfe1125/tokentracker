//
//  SessionTranscript.swift
//  TokenTrackerCore
//
//  会话对话预览：按需读取各 Agent 的本地原始记录（JSONL / zstd JSONL / SQLite），
//  还原成「用户 / 助手 / 思考 / 工具调用 / 工具结果 / 系统注入」的有序条目。
//  只在内存里给界面预览与用户主动导出 Markdown 使用，不写入用量库或任何缓存，
//  与「扫描持久化只记元数据」的数据边界保持一致。
//

import Foundation

public struct TranscriptEntry: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case user, assistant, thinking, toolCall, toolResult, system
    }

    public var id: Int
    public var kind: Kind
    public var text: String
    public var toolName: String = ""
    public var callID: String = ""
    public var isError: Bool = false
    /// 毫秒时间戳；源记录没有时为 nil（不伪造时间）
    public var timestamp: Int64? = nil
    public var model: String = ""
    /// 文本超过单条上限被截断
    public var clipped: Bool = false

    public init(id: Int, kind: Kind, text: String, toolName: String = "", callID: String = "",
                isError: Bool = false, timestamp: Int64? = nil, model: String = "",
                clipped: Bool = false) {
        self.id = id
        self.kind = kind
        self.text = text
        self.toolName = toolName
        self.callID = callID
        self.isError = isError
        self.timestamp = timestamp
        self.model = model
        self.clipped = clipped
    }

    /// 工具调用的一行摘要：优先命令、路径、查询等关键参数，否则取首个非空行。
    public var summary: String {
        if kind == .toolCall,
           let data = text.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for key in TranscriptEntry.summaryKeys {
                if let value = obj[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return TranscriptEntry.firstLine(value)
                }
                if let list = obj[key] as? [String], !list.isEmpty {
                    return TranscriptEntry.firstLine(list.joined(separator: " "))
                }
            }
            // 没有已知关键参数：取第一个字符串参数（按键名排序保证稳定）
            for key in obj.keys.sorted() {
                if let value = obj[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return TranscriptEntry.firstLine(value)
                }
            }
            return ""
        }
        return TranscriptEntry.firstLine(text)
    }

    static let summaryKeys = ["command", "cmd", "CommandLine", "file_path", "filePath", "path",
                              "AbsolutePath", "TargetFile", "pattern", "query", "Query", "url",
                              "Url", "description", "prompt", "skill", "questions"]

    static func firstLine(_ text: String, limit: Int = 160) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }
}

public struct SessionTranscript: Sendable, Equatable {
    public enum Status: String, Sendable {
        /// 正常读取（条目可能为空）
        case ok
        /// 找不到原始记录文件
        case missingSource
        /// 文件存在但读不出来（权限、zstd 缺失、数据库被锁等）
        case unreadable
        /// 该 Agent 还不支持对话预览
        case unsupported
    }

    public var tool: String
    public var sessionID: String
    public var sourcePath: String
    public var status: Status
    public var entries: [TranscriptEntry]
    /// 因超过条目上限被丢弃的条目数（只保留最新的部分）
    public var droppedEntries: Int = 0

    public init(tool: String, sessionID: String, sourcePath: String, status: Status,
                entries: [TranscriptEntry] = [], droppedEntries: Int = 0) {
        self.tool = tool
        self.sessionID = sessionID
        self.sourcePath = sourcePath
        self.status = status
        self.entries = entries
        self.droppedEntries = droppedEntries
    }

    public func count(_ kind: TranscriptEntry.Kind) -> Int {
        entries.reduce(0) { $0 + ($1.kind == kind ? 1 : 0) }
    }

    /// 首条真正的用户输入，作为导出标题兜底
    public var firstUserText: String? {
        entries.first { $0.kind == .user }.map { TranscriptEntry.firstLine($0.text, limit: 80) }
    }
}

public enum SessionTranscriptReader {
    public struct Limits: Sendable {
        /// 单条消息/思考文本上限（字符）
        public var maxTextChars: Int
        /// 工具参数与结果上限（字符）
        public var maxToolChars: Int
        /// 最多保留的条目数（超过时保留最新的部分）
        public var maxEntries: Int

        public init(maxTextChars: Int = 100_000, maxToolChars: Int = 20_000, maxEntries: Int = 20_000) {
            self.maxTextChars = maxTextChars
            self.maxToolChars = maxToolChars
            self.maxEntries = maxEntries
        }

        public static let standard = Limits()
    }

    public static let supportedTools: Set<String> = [
        "claude", "codex", "kimi", "dsh", "pi", "opencode", "hermes", "antigravity",
    ]

    /// 读取会话原始记录。`filePath` 来自 `SessionSourceResolver`；SQLite 来源按会话 ID 查询。
    public static func load(tool: String, sessionID: String, filePath: String,
                            limits: Limits = .standard,
                            zstdReader: (String) -> [(Int, [String: Any])] = iterZstdJSONL) -> SessionTranscript {
        var result = SessionTranscript(tool: tool, sessionID: sessionID, sourcePath: filePath, status: .ok)
        guard supportedTools.contains(tool) else {
            result.status = .unsupported
            return result
        }
        guard !filePath.isEmpty, FileManager.default.fileExists(atPath: filePath) else {
            result.status = .missingSource
            return result
        }
        var builder = TranscriptBuilder(limits: limits)
        switch tool {
        case "claude":
            guard let records = readJSONL(filePath) else { return unreadable(result) }
            parseClaude(records, into: &builder)
        case "codex":
            guard filePath.hasSuffix(".jsonl") else {
                // logs_2.sqlite 只有遥测级别的用量记录，没有对话正文
                result.status = .unsupported
                return result
            }
            guard let records = readJSONL(filePath) else { return unreadable(result) }
            parseCodex(records, into: &builder)
        case "kimi":
            guard let records = readJSONL(filePath) else { return unreadable(result) }
            parseKimi(records, into: &builder)
        case "pi":
            guard let records = readJSONL(filePath) else { return unreadable(result) }
            parsePi(records, into: &builder)
        case "dsh":
            let records = filePath.hasSuffix(".zstd")
                ? zstdReader(filePath).map(\.1)
                : (readJSONL(filePath) ?? [])
            guard !records.isEmpty else { return unreadable(result) }
            parseDsh(records, into: &builder)
        case "antigravity":
            guard let records = readJSONL(filePath) else { return unreadable(result) }
            parseAntigravity(records, into: &builder)
        case "opencode":
            do { try parseOpencode(dbPath: filePath, sessionID: sessionID, into: &builder) }
            catch { return unreadable(result) }
        case "hermes":
            do { try parseHermes(dbPath: filePath, sessionID: sessionID, into: &builder) }
            catch { return unreadable(result) }
        default:
            result.status = .unsupported
            return result
        }
        let (entries, dropped) = builder.finish()
        result.entries = entries
        result.droppedEntries = dropped
        return result
    }

    private static func unreadable(_ base: SessionTranscript) -> SessionTranscript {
        var copy = base
        copy.status = .unreadable
        return copy
    }

    private static func readJSONL(_ path: String) -> [[String: Any]]? {
        guard FileManager.default.isReadableFile(atPath: path) else { return nil }
        return iterJSONL(path).map(\.1)
    }

    // ------------------------------------------------------------ Claude Code ----

    static func parseClaude(_ records: [[String: Any]], into b: inout TranscriptBuilder) {
        var seen = Set<String>()
        // 主会话文件里的子代理分支跳过；子代理自己的记录文件（全部是 sidechain）照常显示
        let hasMainline = records.contains {
            let type = $0["type"] as? String
            return (type == "user" || type == "assistant") && $0["isSidechain"] as? Bool != true
        }
        for o in records {
            guard let type = o["type"] as? String, type == "user" || type == "assistant" else { continue }
            if hasMainline, o["isSidechain"] as? Bool == true { continue }
            if let uuid = o["uuid"] as? String, !seen.insert(uuid).inserted { continue }
            guard let msg = o["message"] as? [String: Any] else { continue }
            let ts = timestampMs(o["timestamp"])
            let model = (msg["model"] as? String).flatMap { $0 == "<synthetic>" ? nil : $0 } ?? ""
            let injected = o["isMeta"] as? Bool == true || o["isCompactSummary"] as? Bool == true
            if let text = msg["content"] as? String {
                if type == "user" { addClaudeUserText(text, injected: injected, ts: ts, into: &b) }
                else { b.add(.assistant, text, ts: ts, model: model) }
                continue
            }
            guard let blocks = msg["content"] as? [Any] else { continue }
            var imageCount = 0
            for case let block as [String: Any] in blocks {
                switch block["type"] as? String ?? "" {
                case "text":
                    let text = block["text"] as? String ?? ""
                    if type == "user" { addClaudeUserText(text, injected: injected, ts: ts, into: &b) }
                    else { b.add(.assistant, text, ts: ts, model: model) }
                case "thinking":
                    b.add(.thinking, block["thinking"] as? String ?? "", ts: ts, model: model)
                case "tool_use", "server_tool_use":
                    b.add(.toolCall, jsonText(block["input"]), toolName: block["name"] as? String ?? "",
                          callID: block["id"] as? String ?? "", ts: ts, model: model)
                case "tool_result", "web_search_tool_result":
                    b.add(.toolResult, jsonText(block["content"]),
                          callID: block["tool_use_id"] as? String ?? "",
                          isError: block["is_error"] as? Bool == true, ts: ts)
                case "image":
                    imageCount += 1
                default:
                    continue
                }
            }
            if imageCount > 0, type == "user" {
                b.add(.user, String(repeating: "[image] ", count: imageCount)
                        .trimmingCharacters(in: .whitespaces), ts: ts)
            }
        }
    }

    private static let systemReminderRegex = try! NSRegularExpression(
        pattern: #"(?s)<system-reminder>.*?</system-reminder>"#)
    private static let commandNameRegex = try! NSRegularExpression(
        pattern: #"(?s)<command-name>(.*?)</command-name>"#)
    private static let commandArgsRegex = try! NSRegularExpression(
        pattern: #"(?s)<command-args>(.*?)</command-args>"#)
    private static let localStdoutRegex = try! NSRegularExpression(
        pattern: #"(?s)<local-command-(?:stdout|stderr)>(.*?)</local-command-(?:stdout|stderr)>"#)

    static func addClaudeUserText(_ raw: String, injected: Bool, ts: Int64?, into b: inout TranscriptBuilder) {
        let text = replace(systemReminderRegex, in: raw, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // 斜杠命令：<command-name>/foo</command-name> … <command-args>bar</command-args> → "/foo bar"
        if let name = firstCapture(commandNameRegex, in: text) {
            let args = firstCapture(commandArgsRegex, in: text) ?? ""
            let line = [name, args].filter { !$0.isEmpty }.joined(separator: " ")
            b.add(injected ? .system : .user, line, ts: ts)
            return
        }
        if let stdout = firstCapture(localStdoutRegex, in: text) {
            b.add(.system, stdout, ts: ts)
            return
        }
        b.add(injected || sessionTitle(fromUserText: text) == nil ? .system : .user, text, ts: ts)
    }

    // ------------------------------------------------------------ Codex ----

    static func parseCodex(_ records: [[String: Any]], into b: inout TranscriptBuilder) {
        var model = ""
        for o in records {
            let type = o["type"] as? String ?? ""
            let payload = o["payload"] as? [String: Any] ?? [:]
            if type == "turn_context" {
                if let m = payload["model"] as? String, !m.isEmpty { model = m }
                continue
            }
            guard type == "response_item" else { continue }
            let ts = timestampMs(o["timestamp"])
            switch payload["type"] as? String ?? "" {
            case "message":
                let role = payload["role"] as? String ?? ""
                let text = blocksText(payload["content"])
                if role == "user" {
                    // 带附件的提问以「# Files mentioned by the user」开头，标记行各版本不同，整条算用户输入
                    let attachedFiles = text.hasPrefix("# Files mentioned by the user")
                    b.add(attachedFiles || sessionTitle(fromUserText: text) != nil ? .user : .system, text, ts: ts)
                } else if role == "assistant" {
                    b.add(.assistant, text, ts: ts, model: model)
                }
                // developer / system：系统提示词，不进入对话预览
            case "reasoning":
                let summary = (payload["summary"] as? [Any] ?? []).compactMap {
                    ($0 as? [String: Any])?["text"] as? String
                }.joined(separator: "\n\n")
                let content = blocksText(payload["content"])
                b.add(.thinking, summary.isEmpty ? content : summary, ts: ts, model: model)
            case "function_call":
                b.add(.toolCall, jsonText(payload["arguments"]), toolName: payload["name"] as? String ?? "",
                      callID: payload["call_id"] as? String ?? "", ts: ts, model: model)
            case "custom_tool_call":
                b.add(.toolCall, jsonText(payload["input"]), toolName: payload["name"] as? String ?? "",
                      callID: payload["call_id"] as? String ?? "", ts: ts, model: model)
            case "local_shell_call":
                let action = payload["action"] as? [String: Any] ?? [:]
                b.add(.toolCall, jsonText(action), toolName: "shell",
                      callID: payload["call_id"] as? String ?? "", ts: ts, model: model)
            case "web_search_call":
                // 搜索结果不落盘，只有状态；把状态记作结果，避免显示成「未记录结果」
                let action = payload["action"] as? [String: Any] ?? [:]
                let callID = payload["id"] as? String ?? ""
                b.add(.toolCall, jsonText(action), toolName: "web_search", callID: callID, ts: ts, model: model)
                if let status = payload["status"] as? String, !status.isEmpty {
                    b.add(.toolResult, status, callID: callID, isError: status == "failed", ts: ts)
                }
            case "function_call_output", "custom_tool_call_output", "local_shell_call_output":
                var output = payload["output"]
                var isError = false
                // 旧版 output 是 JSON 字符串 {"output": "...", "metadata": {"exit_code": 1}}
                if let s = output as? String, s.hasPrefix("{"),
                   let obj = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any],
                   let inner = obj["output"] {
                    output = inner
                    if let meta = obj["metadata"] as? [String: Any],
                       let code = meta["exit_code"] as? NSNumber, code.intValue != 0 { isError = true }
                }
                b.add(.toolResult, jsonText(output), callID: payload["call_id"] as? String ?? "",
                      isError: isError, ts: ts)
            default:
                continue
            }
        }
    }

    // ------------------------------------------------------------ Kimi ----

    static func parseKimi(_ records: [[String: Any]], into b: inout TranscriptBuilder) {
        for o in records {
            if o["kind"] != nil || o["envelope"] != nil {
                parseKimiJournalEvent(o, into: &b)
            } else {
                parseChatMessage(o, ts: timestampMs(o["timestamp"] ?? o["time"]), into: &b)
            }
        }
    }

    private static func parseKimiJournalEvent(_ o: [String: Any], into b: inout TranscriptBuilder) {
        guard o["kind"] as? String == "event", let envelope = o["envelope"] as? [String: Any] else { return }
        let type = envelope["type"] as? String ?? ""
        let payload = envelope["payload"] as? [String: Any] ?? [:]
        let ts = timestampMs(envelope["timestamp"] ?? o["time"])
        var model = ""
        if let m = payload["model"] as? [String: Any] { model = m["id"] as? String ?? "" }
        else if let m = payload["model"] as? String { model = m }
        switch type {
        case "turn.started":
            let prompt = payload["prompt"] as? String ?? blocksText(payload["input"])
            b.add(.user, prompt, ts: ts)
        case "tool.call.started":
            let call = payload["toolCall"] as? [String: Any] ?? payload
            let name = firstString(call["name"], call["toolName"], call["tool"])
            b.add(.toolCall, jsonText(call["args"] ?? call["arguments"] ?? call["input"]), toolName: name,
                  callID: firstString(call["id"], call["toolCallId"], payload["toolCallId"]), ts: ts, model: model)
        case "tool.result":
            let output = payload["output"] ?? payload["result"] ?? payload["content"] ?? payload["error"]
            let status = (payload["status"] as? String ?? "").lowercased()
            b.add(.toolResult, jsonText(output),
                  callID: firstString(payload["toolCallId"], payload["callId"], payload["id"]),
                  isError: payload["error"] != nil || status == "error" || status == "failed", ts: ts)
        default:
            // 助手正文事件（message.completed / assistant.message 等）：取完整文本，跳过增量
            guard !type.contains("delta"), type.contains("message") || type.contains("assistant") else { return }
            let message = payload["message"] as? [String: Any] ?? payload
            let role = message["role"] as? String ?? "assistant"
            let text = message["text"] as? String ?? blocksText(message["content"])
            if role == "assistant" {
                b.add(.assistant, text, ts: ts, model: model)
            } else if role == "user" {
                b.add(.user, text, ts: ts)
            }
        }
    }

    /// OpenAI 风格消息：{"role": "...", "content": ..., "tool_calls": [...], "tool_call_id": ...}
    static func parseChatMessage(_ o: [String: Any], ts: Int64?, into b: inout TranscriptBuilder) {
        let role = o["role"] as? String ?? ""
        switch role {
        case "user":
            let text = blocksText(o["content"])
            b.add(sessionTitle(fromUserText: text) == nil ? .system : .user, text, ts: ts)
        case "assistant":
            let model = o["model"] as? String ?? ""
            if let reasoning = o["reasoning_content"] as? String ?? o["reasoning"] as? String {
                b.add(.thinking, reasoning, ts: ts, model: model)
            }
            b.add(.assistant, blocksText(o["content"]), ts: ts, model: model)
            addOpenAIToolCalls(o["tool_calls"], ts: ts, model: model, into: &b)
        case "tool":
            b.add(.toolResult, blocksText(o["content"]), toolName: o["name"] as? String ?? "",
                  callID: o["tool_call_id"] as? String ?? "", ts: ts)
        default:
            return
        }
    }

    static func addOpenAIToolCalls(_ raw: Any?, ts: Int64?, model: String, into b: inout TranscriptBuilder) {
        var calls = raw as? [Any]
        if calls == nil, let s = raw as? String, !s.isEmpty {
            calls = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [Any]
        }
        for case let call as [String: Any] in calls ?? [] {
            let function = call["function"] as? [String: Any] ?? call
            b.add(.toolCall, jsonText(function["arguments"] ?? function["input"]),
                  toolName: function["name"] as? String ?? "",
                  callID: firstString(call["id"], call["call_id"]), ts: ts, model: model)
        }
    }

    // ------------------------------------------------------------ Pi ----

    static func parsePi(_ records: [[String: Any]], into b: inout TranscriptBuilder) {
        for o in records {
            let type = o["type"] as? String ?? ""
            let ts = timestampMs(o["timestamp"])
            if type == "compaction" {
                b.add(.system, o["summary"] as? String ?? "", ts: ts)
                continue
            }
            guard type == "message", let msg = o["message"] as? [String: Any] else { continue }
            let model = msg["model"] as? String ?? ""
            switch msg["role"] as? String ?? "" {
            case "user":
                let text = blocksText(msg["content"])
                b.add(sessionTitle(fromUserText: text) == nil ? .system : .user, text, ts: ts)
            case "assistant":
                for case let block as [String: Any] in msg["content"] as? [Any] ?? [] {
                    switch block["type"] as? String ?? "" {
                    case "text": b.add(.assistant, block["text"] as? String ?? "", ts: ts, model: model)
                    case "thinking": b.add(.thinking, block["thinking"] as? String ?? "", ts: ts, model: model)
                    case "toolCall":
                        b.add(.toolCall, jsonText(block["arguments"]), toolName: block["name"] as? String ?? "",
                              callID: block["id"] as? String ?? "", ts: ts, model: model)
                    default: continue
                    }
                }
            case "toolResult":
                b.add(.toolResult, blocksText(msg["content"]), toolName: msg["toolName"] as? String ?? "",
                      callID: msg["toolCallId"] as? String ?? "", isError: msg["isError"] as? Bool == true, ts: ts)
            case "system":
                b.add(.system, blocksText(msg["content"]), ts: ts)
            default:
                continue
            }
        }
    }

    // ------------------------------------------------------------ DSH ----

    static func parseDsh(_ records: [[String: Any]], into b: inout TranscriptBuilder) {
        for o in records {
            let type = o["type"] as? String ?? ""
            let data = o["data"] as? [String: Any] ?? [:]
            let ts = timestampMs(o["time"])
            switch type {
            case "user/message":
                // agent/inbox/spliced 与 user/message 是同一条消息的两次记录，只取后者
                let kind = (data["source"] as? [String: Any])?["kind"] as? String ?? "user"
                let text = blocksText(data["content"])
                b.add(kind == "user" && sessionTitle(fromUserText: text) != nil ? .user : .system, text, ts: ts)
            case "assistant/message":
                let message = data["message"] as? [String: Any] ?? [:]
                let model = (message["source"] as? [String: Any])?["model"] as? String ?? ""
                for case let block as [String: Any] in message["content"] as? [Any] ?? [] {
                    switch block["type"] as? String ?? "" {
                    case "text": b.add(.assistant, block["text"] as? String ?? "", ts: ts, model: model)
                    case "reasoning": b.add(.thinking, block["text"] as? String ?? "", ts: ts, model: model)
                    case "tool-call":
                        b.add(.toolCall, jsonText(block["arguments"]), toolName: block["name"] as? String ?? "",
                              callID: block["id"] as? String ?? "", ts: ts, model: model)
                    default: continue
                    }
                }
            case "tool/result":
                let message = data["message"] as? [String: Any] ?? [:]
                // v4：结果直接挂在 message 上（role=tool, toolCallId, content=[text]）
                if let callID = message["toolCallId"] as? String {
                    var text = blocksText(message["content"])
                    if text.isEmpty { text = jsonText(data["error"]) }
                    b.add(.toolResult, text, callID: callID,
                          isError: message["isError"] as? Bool == true || data["error"] != nil, ts: ts)
                    continue
                }
                for case let block as [String: Any] in message["content"] as? [Any] ?? [] {
                    guard block["type"] as? String == "tool-result" else { continue }
                    b.add(.toolResult, blocksText(block["content"]),
                          callID: block["toolCallId"] as? String ?? "",
                          isError: block["isError"] as? Bool == true, ts: ts)
                }
            default:
                continue
            }
        }
    }

    // ------------------------------------------------------------ Antigravity ----

    private static let agRequestRegex = try! NSRegularExpression(
        pattern: #"(?s)<USER_REQUEST>\s*(.*?)\s*</USER_REQUEST>"#)
    private static let agMetaRegex = try! NSRegularExpression(
        pattern: #"(?s)<(ADDITIONAL_METADATA|USER_SETTINGS_CHANGE)>.*?</\1>"#)

    static func parseAntigravity(_ records: [[String: Any]], into b: inout TranscriptBuilder) {
        // GENERIC 步骤是上一批工具调用的结果，按顺序配对
        var pending: [(name: String, id: String)] = []
        for (index, o) in records.enumerated() {
            let ts = timestampMs(o["created_at"])
            let model = o["model"] as? String ?? ""
            let content = o["content"] as? String ?? ""
            switch o["type"] as? String ?? "" {
            case "USER_INPUT":
                var text = firstCapture(agRequestRegex, in: content) ?? content
                text = replace(agMetaRegex, in: text, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                b.add(.user, text, ts: ts)
            case "PLANNER_RESPONSE":
                b.add(.thinking, o["thinking"] as? String ?? "", ts: ts, model: model)
                b.add(.assistant, content, ts: ts, model: model)
                for (callIndex, item) in (o["tool_calls"] as? [Any] ?? []).enumerated() {
                    guard let call = item as? [String: Any] else { continue }
                    var args = call["args"] as? [String: Any] ?? [:]
                    args.removeValue(forKey: "toolSummary")
                    let id = "ag-\(index)-\(callIndex)"
                    let name = call["name"] as? String ?? ""
                    b.add(.toolCall, jsonText(args), toolName: name, callID: id, ts: ts, model: model)
                    pending.append((name, id))
                }
            case "GENERIC":
                let next = pending.isEmpty ? nil : pending.removeFirst()
                b.add(.toolResult, content, toolName: next?.name ?? "", callID: next?.id ?? "",
                      isError: o["error"] != nil, ts: ts)
            case "SYSTEM_MESSAGE", "CHECKPOINT":
                b.add(.system, content, ts: ts)
            default:
                continue
            }
        }
    }

    // ------------------------------------------------------------ opencode ----

    static func parseOpencode(dbPath: String, sessionID: String, into b: inout TranscriptBuilder) throws {
        let db = try sqliteRO(dbPath)
        let messages = try db.query(
            "SELECT id, time_created, data FROM message WHERE session_id=? ORDER BY time_created, id", [sessionID])
        let parts = try db.query(
            "SELECT message_id, time_created, data FROM part WHERE session_id=? ORDER BY time_created, id", [sessionID])
        var partsByMessage: [String: [[String: Any]]] = [:]
        var partTimes: [String: [Int64]] = [:]
        for row in parts {
            guard let obj = parseJSONObject(row.string("data")) else { continue }
            partsByMessage[row.string("message_id"), default: []].append(obj)
            partTimes[row.string("message_id"), default: []].append(row.int("time_created"))
        }
        for row in messages {
            guard let data = parseJSONObject(row.string("data")) else { continue }
            let id = row.string("id")
            let role = data["role"] as? String ?? ""
            var model = data["modelID"] as? String ?? ""
            if model.isEmpty, let m = data["model"] as? [String: Any] { model = m["modelID"] as? String ?? "" }
            let messageTs = timestampMs(row.int("time_created"))
            for (i, part) in (partsByMessage[id] ?? []).enumerated() {
                let ts = partTimes[id].flatMap { $0.indices.contains(i) ? timestampMs($0[i]) : nil } ?? messageTs
                switch part["type"] as? String ?? "" {
                case "text":
                    let text = part["text"] as? String ?? ""
                    if role == "user" {
                        let injected = part["synthetic"] as? Bool == true || sessionTitle(fromUserText: text) == nil
                        b.add(injected ? .system : .user, text, ts: ts)
                    } else {
                        b.add(.assistant, text, ts: ts, model: model)
                    }
                case "reasoning":
                    b.add(.thinking, part["text"] as? String ?? "", ts: ts, model: model)
                case "tool":
                    let state = part["state"] as? [String: Any] ?? [:]
                    let name = part["tool"] as? String ?? ""
                    let callID = part["callID"] as? String ?? ""
                    b.add(.toolCall, jsonText(state["input"]), toolName: name, callID: callID, ts: ts, model: model)
                    let status = state["status"] as? String ?? ""
                    if status == "error" {
                        b.add(.toolResult, jsonText(state["error"] ?? state["output"]), toolName: name,
                              callID: callID, isError: true, ts: ts)
                    } else if let output = state["output"] {
                        b.add(.toolResult, jsonText(output), toolName: name, callID: callID, ts: ts)
                    }
                case "file":
                    let name = part["filename"] as? String ?? part["url"] as? String ?? ""
                    b.add(role == "user" ? .user : .system, "[file] \(name)", ts: ts)
                default:
                    continue
                }
            }
        }
    }

    // ------------------------------------------------------------ Hermes ----

    static func parseHermes(dbPath: String, sessionID: String, into b: inout TranscriptBuilder) throws {
        let db = try sqliteRO(dbPath)
        let columns = Set(try db.query("PRAGMA table_info(messages)").map { $0.string("name") })
        guard columns.contains("session_id"), columns.contains("role") else { return }
        let activeFilter = columns.contains("active") ? " AND COALESCE(active,1)!=0" : ""
        let rows = try db.query(
            "SELECT * FROM messages WHERE session_id=?\(activeFilter) ORDER BY id", [sessionID])
        for row in rows {
            let ts = timestampMs(row.doubleOrNil("timestamp").map { NSNumber(value: $0) })
            var obj: [String: Any] = ["role": row.string("role"), "content": row.string("content")]
            if let calls = row.stringOrNil("tool_calls") { obj["tool_calls"] = calls }
            if let id = row.stringOrNil("tool_call_id") { obj["tool_call_id"] = id }
            if let name = row.stringOrNil("tool_name") { obj["name"] = name }
            if let reasoning = row.stringOrNil("reasoning_content") ?? row.stringOrNil("reasoning"),
               !reasoning.isEmpty { obj["reasoning_content"] = reasoning }
            if obj["role"] as? String == "system" {
                b.add(.system, row.string("content"), ts: ts)
            } else {
                parseChatMessage(obj, ts: ts, into: &b)
            }
        }
    }

    // ------------------------------------------------------------ 工具函数 ----

    /// 数字（秒或毫秒）或 ISO 字符串 → 毫秒
    static func timestampMs(_ raw: Any?) -> Int64? {
        if let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            let d = n.doubleValue
            guard d > 0 else { return nil }
            return Int64(d < 1e12 ? d * 1000 : d)
        }
        if let n = raw as? Int64 { return timestampMs(NSNumber(value: n)) }
        if let s = raw as? String, !s.isEmpty { return parseISODateMs(s) }
        return nil
    }

    /// 内容块数组 / 字符串 → 纯文本；图片与文件以占位符表示。
    static func blocksText(_ raw: Any?) -> String {
        if let s = raw as? String { return s }
        guard let list = raw as? [Any] else {
            if let dict = raw as? [String: Any], let text = dict["text"] as? String { return text }
            return ""
        }
        var pieces: [String] = []
        for item in list {
            if let s = item as? String { pieces.append(s); continue }
            guard let block = item as? [String: Any] else { continue }
            let type = block["type"] as? String ?? ""
            if let text = block["text"] as? String {
                pieces.append(text)
            } else if type.contains("image") {
                pieces.append("[image]")
            } else if let content = block["content"] {
                pieces.append(blocksText(content))
            }
        }
        return pieces.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// 工具参数/结果 → 文本：字符串原样（JSON 字符串会格式化），其余转成格式化 JSON。
    static func jsonText(_ raw: Any?) -> String {
        guard let raw, !(raw is NSNull) else { return "" }
        if let s = raw as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{"), let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
               let pretty = prettyJSON(obj) {
                return pretty
            }
            return s
        }
        if let list = raw as? [Any], list.allSatisfy({ $0 is [String: Any] || $0 is String }),
           list.contains(where: { ($0 as? [String: Any])?["text"] != nil || $0 is String }) {
            return blocksText(list)
        }
        if let n = raw as? NSNumber { return n.stringValue }
        return prettyJSON(raw) ?? String(describing: raw)
    }

    private static func prettyJSON(_ obj: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func parseJSONObject(_ s: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
    }

    private static func firstString(_ values: Any?...) -> String {
        for value in values {
            if let s = value as? String, !s.isEmpty { return s }
            if let n = value as? NSNumber { return n.stringValue }
        }
        return ""
    }

    private static func firstCapture(_ regex: NSRegularExpression, in text: String) -> String? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

/// 条目累加器：跳过空文本、按上限截断、为工具结果补上调用名。
struct TranscriptBuilder {
    let limits: SessionTranscriptReader.Limits
    private(set) var entries: [TranscriptEntry] = []
    private var callNames: [String: String] = [:]
    private var nextID = 0

    init(limits: SessionTranscriptReader.Limits) {
        self.limits = limits
    }

    mutating func add(_ kind: TranscriptEntry.Kind, _ rawText: String, toolName: String = "",
                      callID: String = "", isError: Bool = false, ts: Int64? = nil, model: String = "") {
        var text = rawText
        if kind != .toolCall && kind != .toolResult {
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
        } else {
            // 工具调用即使没有参数也保留（只显示工具名）；没有内容也没有 ID 的结果丢弃
            text = text.trimmingCharacters(in: .newlines)
            if kind == .toolResult && text.isEmpty && callID.isEmpty { return }
            if kind == .toolCall && toolName.isEmpty && text.isEmpty { return }
        }
        let limit = (kind == .toolCall || kind == .toolResult) ? limits.maxToolChars : limits.maxTextChars
        var clipped = false
        if text.count > limit {
            text = String(text.prefix(limit))
            clipped = true
        }
        var name = toolName
        if kind == .toolCall, !callID.isEmpty, !toolName.isEmpty { callNames[callID] = toolName }
        if kind == .toolResult, name.isEmpty, !callID.isEmpty { name = callNames[callID] ?? "" }
        entries.append(TranscriptEntry(id: nextID, kind: kind, text: text, toolName: name, callID: callID,
                                       isError: isError, timestamp: ts, model: model, clipped: clipped))
        nextID += 1
    }

    func finish() -> ([TranscriptEntry], Int) {
        guard entries.count > limits.maxEntries else { return (entries, 0) }
        let dropped = entries.count - limits.maxEntries
        return (Array(entries.suffix(limits.maxEntries)), dropped)
    }
}
