//
//  TranscriptMarkdown.swift
//  TokenTrackerCore
//
//  对话条目的展示分组（工具调用与结果配对）与 Markdown 导出。
//  文案由调用方注入（App 按界面语言本地化），Core 不依赖 UI 本地化。
//

import Foundation

/// 过滤开关：界面预览与导出共用
public struct TranscriptFilter: Sendable, Equatable {
    public var includeTools: Bool
    public var includeThinking: Bool
    public var includeSystem: Bool

    public init(includeTools: Bool = true, includeThinking: Bool = false, includeSystem: Bool = false) {
        self.includeTools = includeTools
        self.includeThinking = includeThinking
        self.includeSystem = includeSystem
    }
}

/// 展示单元：普通消息，或一次工具调用（调用与结果配对；任一侧可能缺失）
public enum TranscriptItem: Sendable, Equatable, Identifiable {
    case message(TranscriptEntry)
    case tool(call: TranscriptEntry?, result: TranscriptEntry?)

    public var id: Int {
        switch self {
        case .message(let entry): return entry.id
        case .tool(let call, let result): return call?.id ?? result?.id ?? -1
        }
    }

    /// 属于助手一侧（思考、回复、工具）
    public var isAssistantSide: Bool {
        switch self {
        case .message(let entry): return entry.kind == .assistant || entry.kind == .thinking
        case .tool: return true
        }
    }

    public var searchableText: String {
        switch self {
        case .message(let entry): return entry.text
        case .tool(let call, let result):
            return [call?.toolName ?? result?.toolName ?? "", call?.text ?? "", result?.text ?? ""]
                .joined(separator: "\n")
        }
    }

    public static func build(_ entries: [TranscriptEntry], filter: TranscriptFilter) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        var openCalls: [String: Int] = [:]   // callID → items 下标（尚未配上结果）
        for entry in entries {
            switch entry.kind {
            case .user, .assistant:
                items.append(.message(entry))
            case .thinking:
                if filter.includeThinking { items.append(.message(entry)) }
            case .system:
                if filter.includeSystem { items.append(.message(entry)) }
            case .toolCall:
                guard filter.includeTools else { continue }
                if !entry.callID.isEmpty { openCalls[entry.callID] = items.count }
                items.append(.tool(call: entry, result: nil))
            case .toolResult:
                guard filter.includeTools else { continue }
                if !entry.callID.isEmpty, let index = openCalls.removeValue(forKey: entry.callID),
                   case .tool(let call, nil) = items[index] {
                    items[index] = .tool(call: call, result: entry)
                } else {
                    items.append(.tool(call: nil, result: entry))
                }
            }
        }
        return items
    }
}

public enum TranscriptMarkdown {
    public struct Labels: Sendable {
        public var agent = "Agent"
        public var sessionID = "会话 ID"
        public var workspace = "工作目录"
        public var time = "时间"
        public var models = "模型"
        public var source = "源文件"
        public var exportedAt = "导出时间"
        public var user = "用户"
        public var assistant = "助手"
        public var thinking = "思考"
        public var system = "系统 / 上下文注入"
        public var tool = "未命名工具"
        public var arguments = "参数"
        public var result = "结果"
        public var error = "出错"
        public var noResult = "（未记录结果）"
        /// {0} = 截断后保留的字符数
        public var clipped = "（内容过长，已截断，仅保留前 {0} 个字符）"
        /// {0} = 丢弃的较早条目数
        public var dropped = "（对话过长，省略了最早的 {0} 条记录）"
        public var empty = "（没有可显示的对话内容）"

        public init() {}

        /// 英文文案（CLI `--lang en`；App 走本地化资源）
        public static let english: Labels = {
            var l = Labels()
            l.sessionID = "Session ID"
            l.workspace = "Working directory"
            l.time = "Time"
            l.models = "Model"
            l.source = "Source file"
            l.exportedAt = "Exported at"
            l.user = "User"
            l.assistant = "Assistant"
            l.thinking = "Thinking"
            l.system = "System / injected context"
            l.tool = "Unnamed tool"
            l.arguments = "Arguments"
            l.result = "Result"
            l.error = "Error"
            l.noResult = "(no result recorded)"
            l.clipped = "(Too long; truncated to the first {0} characters)"
            l.dropped = "(Conversation too long; the {0} earliest records were omitted)"
            l.empty = "(No conversation to show)"
            return l
        }()
    }

    public struct Metadata: Sendable {
        public var title: String
        public var agentName: String
        public var sessionID: String
        public var workspace: String
        public var timeRange: String
        public var models: [String]
        public var sourcePath: String
        public var exportedAt: Date

        public init(title: String, agentName: String, sessionID: String, workspace: String = "",
                    timeRange: String = "", models: [String] = [], sourcePath: String = "",
                    exportedAt: Date = Date()) {
            self.title = title
            self.agentName = agentName
            self.sessionID = sessionID
            self.workspace = workspace
            self.timeRange = timeRange
            self.models = models
            self.sourcePath = sourcePath
            self.exportedAt = exportedAt
        }
    }

    public static func render(_ transcript: SessionTranscript, metadata: Metadata,
                              filter: TranscriptFilter = TranscriptFilter(),
                              labels: Labels = Labels(),
                              toolOutputLimit: Int = 4_000,
                              formatTime: (Int64) -> String = defaultTime) -> String {
        var out: [String] = []
        let title = metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
        out.append("# " + (title.isEmpty ? metadata.sessionID : singleLine(title)))
        out.append("")
        var meta: [(String, String)] = [(labels.agent, metadata.agentName),
                                        (labels.sessionID, "`\(metadata.sessionID)`")]
        if !metadata.workspace.isEmpty { meta.append((labels.workspace, "`\(metadata.workspace)`")) }
        if !metadata.timeRange.isEmpty { meta.append((labels.time, metadata.timeRange)) }
        if !metadata.models.isEmpty {
            meta.append((labels.models, metadata.models.map { "`\($0)`" }.joined(separator: ", ")))
        }
        if !metadata.sourcePath.isEmpty { meta.append((labels.source, "`\(metadata.sourcePath)`")) }
        meta.append((labels.exportedAt, formatTime(Int64(metadata.exportedAt.timeIntervalSince1970 * 1000))))
        for (key, value) in meta { out.append("- **\(key)**: \(value)") }
        out.append("")
        if transcript.droppedEntries > 0 {
            out.append("> " + labels.dropped.replacingOccurrences(of: "{0}", with: "\(transcript.droppedEntries)"))
            out.append("")
        }
        out.append("---")
        out.append("")

        let items = TranscriptItem.build(transcript.entries, filter: filter)
        if items.isEmpty {
            out.append(labels.empty)
            out.append("")
        }
        var lastSide: Bool?   // true = 助手侧
        for item in items {
            let assistantSide = item.isAssistantSide
            var isSystem = false
            if case .message(let entry) = item, entry.kind == .system { isSystem = true }
            // 说话方切换时出一个小标题；系统注入不打断当前段落
            if !isSystem, lastSide != assistantSide {
                let heading = assistantSide
                    ? "## 🤖 " + labels.assistant + suffix(model: firstModel(item), ts: firstTimestamp(item), formatTime)
                    : "## 👤 " + labels.user + suffix(model: "", ts: firstTimestamp(item), formatTime)
                out.append(heading)
                out.append("")
                lastSide = assistantSide
            }
            switch item {
            case .message(let entry):
                switch entry.kind {
                case .user, .assistant:
                    out.append(entry.text)
                    if entry.clipped { out.append(""); out.append("_" + clippedNote(labels, entry) + "_") }
                case .thinking:
                    out.append(contentsOf: details(summary: "💭 " + labels.thinking, body: [entry.text]))
                case .system:
                    out.append(contentsOf: details(summary: "ℹ️ " + labels.system,
                                                   body: [fenced(entry.text, language: "text")]))
                default:
                    break
                }
            case .tool(let call, let result):
                let name = call?.toolName ?? result?.toolName ?? ""
                var summary = "🔧 <code>\(htmlEscape(name.isEmpty ? labels.tool : name))</code>"
                if let call {
                    let line = call.summary
                    if !line.isEmpty { summary += " — " + htmlEscape(line) }
                }
                if result?.isError == true { summary += " ⚠️ " + htmlEscape(labels.error) }
                var body: [String] = []
                if let call, !call.text.isEmpty {
                    body.append("**\(labels.arguments)**")
                    body.append("")
                    body.append(fenced(call.text, language: call.text.hasPrefix("{") ? "json" : ""))
                }
                if let result {
                    if !body.isEmpty { body.append("") }
                    body.append("**\(labels.result)**")
                    body.append("")
                    var text = result.text
                    var clipped = result.clipped
                    if text.count > toolOutputLimit {
                        text = String(text.prefix(toolOutputLimit))
                        clipped = true
                    }
                    body.append(fenced(text, language: "text"))
                    if clipped {
                        body.append("")
                        body.append("_" + labels.clipped.replacingOccurrences(of: "{0}", with: "\(text.count)") + "_")
                    }
                } else if call != nil {
                    if !body.isEmpty { body.append("") }
                    body.append("_" + labels.noResult + "_")
                }
                out.append(contentsOf: details(summary: summary, body: body))
            }
            out.append("")
        }
        while out.last == "" { out.removeLast() }
        return out.joined(separator: "\n") + "\n"
    }

    /// 适合作为文件名的标题：去掉路径分隔符与控制字符，限制长度
    public static func suggestedFileName(title: String, sessionID: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        var base = title.components(separatedBy: invalid).joined(separator: " ")
        base = base.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        if base.count > 60 { base = String(base.prefix(60)).trimmingCharacters(in: .whitespaces) }
        let shortID = String(sessionID.prefix(8))
        if base.isEmpty { return "session-\(shortID).md" }
        return "\(base)-\(shortID).md"
    }

    public static func defaultTime(_ ms: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    // ------------------------------------------------------------ 内部 ----

    private static func suffix(model: String, ts: Int64?, _ formatTime: (Int64) -> String) -> String {
        var parts: [String] = []
        if !model.isEmpty { parts.append("`\(model)`") }
        if let ts { parts.append(formatTime(ts)) }
        return parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")
    }

    private static func firstModel(_ item: TranscriptItem) -> String {
        switch item {
        case .message(let entry): return entry.model
        case .tool(let call, _): return call?.model ?? ""
        }
    }

    private static func firstTimestamp(_ item: TranscriptItem) -> Int64? {
        switch item {
        case .message(let entry): return entry.timestamp
        case .tool(let call, let result): return call?.timestamp ?? result?.timestamp
        }
    }

    private static func clippedNote(_ labels: Labels, _ entry: TranscriptEntry) -> String {
        labels.clipped.replacingOccurrences(of: "{0}", with: "\(entry.text.count)")
    }

    private static func details(summary: String, body: [String]) -> [String] {
        var lines = ["<details>", "<summary>\(summary)</summary>", ""]
        lines.append(contentsOf: body)
        lines.append("")
        lines.append("</details>")
        return lines
    }

    /// 代码围栏比正文里最长的反引号串还长一位，避免内容里的 ``` 提前闭合
    static func fenced(_ text: String, language: String) -> String {
        var longest = 0, run = 0
        for ch in text {
            if ch == "`" { run += 1; longest = max(longest, run) } else { run = 0 }
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + language + "\n" + text + "\n" + fence
    }

    private static func htmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}
