//
//  ScannerSupport.swift
//  TokenTrackerCore
//
//  移植自 tokentracker/scanners/_util.py：文件指纹、字节游标增量读、
//  JSONL 迭代、zstd 解压、ISO 时间解析、会话标题提取。
//

import Foundation

public func expandPath(_ path: String) -> String {
    NSString(string: path).expandingTildeInPath
}

/// Python os.path.realpath（解析符号链接，如 /tmp → /private/tmp）。
public func realPath(_ path: String) -> String {
    if let resolved = Darwin.realpath(path, nil) {
        defer { free(resolved) }
        return String(cString: resolved)
    }
    return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}

// ------------------------------------------------------------ 文件指纹 ----

/// Python stat_key：{"m": mtime_ns, "s": size, "i": ino, "d": dev}
public struct StatKey: Equatable {
    public var m: Int64  // st_mtime_ns
    public var s: Int64  // size
    public var i: Int64  // ino
    public var d: Int64  // dev

    public init?(path: String) {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        m = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        s = Int64(st.st_size)
        i = Int64(st.st_ino)
        d = Int64(st.st_dev)
    }

    public var asDict: [String: Int64] { ["m": m, "s": s, "i": i, "d": d] }

    public init?(dict: [String: Any]?) {
        guard let dict else { return nil }
        func val(_ k: String) -> Int64? {
            (dict[k] as? Int64) ?? (dict[k] as? NSNumber)?.int64Value
        }
        guard let m = val("m"), let s = val("s"), let i = val("i"), let d = val("d") else { return nil }
        self.m = m; self.s = s; self.i = i; self.d = d
    }
}

/// Python changed()：只比对指纹键（游标可能携带 "o" 等附加字段）。
public func fingerprintChanged(cursor: [String: Any], path: String) -> Bool {
    guard let stored = cursor[path] as? [String: Any],
          let storedKey = StatKey(dict: stored),
          let current = StatKey(path: path) else { return true }
    return storedKey.m != current.m || storedKey.s != current.s
        || storedKey.i != current.i || storedKey.d != current.d
}

// ------------------------------------------------------------ JSONL ----

/// Python json.loads 一行 → [String: Any]（非 dict 返回 nil）。
public func parseJSONLine(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

/// 按 \n 切行并保留行号语义（Python 文件迭代只认 \n；空行计入行号）。
private func splitJSONLines(_ data: Data) -> [String] {
    let text = String(decoding: data, as: UTF8.self) // errors="replace" 对齐
    return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
}

/// iter_jsonl：yield (行号从 1 起, dict)。解析失败的行跳过；行号仍计入。
public func iterJSONL(_ path: String) -> [(Int, [String: Any])] {
    guard let data = FileManager.default.contents(atPath: path) else { return [] }
    var out: [(Int, [String: Any])] = []
    for (index, line) in splitJSONLines(data).enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let obj = parseJSONLine(Data(trimmed.utf8)) else { continue }
        out.append((index + 1, obj))
    }
    return out
}

/// 字节级行读取器：read_jsonl_delta 的底座。
/// 返回 (行起始字节偏移, 行原始字节含 \n)；文件读尽返回 nil。
final class ByteLineReader {
    private let handle: FileHandle
    private var buffer: [UInt8] = []
    private var bufferStart: Int64   // buffer[0] 的文件绝对偏移
    private var index = 0            // buffer 内消费位置
    private var eof = false

    init?(path: String, offset: Int64) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        self.handle = handle
        self.bufferStart = offset
        do { try handle.seek(toOffset: UInt64(offset)) } catch { return nil }
    }

    deinit { try? handle.close() }

    private func fill() {
        guard !eof else { return }
        if index > 0 {
            buffer.removeFirst(index)
            bufferStart += Int64(index)
            index = 0
        }
        let chunk = handle.readData(ofLength: 64 * 1024)
        if chunk.isEmpty { eof = true } else { buffer.append(contentsOf: chunk) }
    }

    /// 返回 (绝对偏移, 行字节, 是否以 \n 结尾)。
    func readLine() -> (offset: Int64, data: Data, terminated: Bool)? {
        while true {
            if index < buffer.count,
               let nl = buffer[index...].firstIndex(of: 0x0A) {
                let start = bufferStart + Int64(index)
                let data = Data(buffer[index...nl])
                index = nl + 1
                return (start, data, true)
            }
            if eof {
                if index < buffer.count {
                    let start = bufferStart + Int64(index)
                    let data = Data(buffer[index...])
                    index = buffer.count
                    return (start, data, false)
                }
                return nil
            }
            fill()
        }
    }
}

/// read_jsonl_delta：从字节偏移（必须是行边界）增量读，只解析新增完整行。
/// 返回 (items, newOffset)；items 为 (行起始偏移, dict)。
/// 偏移失效（截断/轮转/不在行边界）返回 ([], -1)。
public func readJSONLDelta(path: String, offset: Int64) -> ([(Int64, [String: Any])], Int64) {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let size = (attrs[.size] as? NSNumber)?.int64Value else { return ([], -1) }
    if offset < 0 || offset > size { return ([], -1) }
    if offset > 0 {
        // 校验 offset-1 必须是 \n（行边界）
        guard let handle = FileHandle(forReadingAtPath: path) else { return ([], -1) }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: UInt64(offset - 1)) } catch { return ([], -1) }
        guard handle.readData(ofLength: 1) == Data([0x0A]) else { return ([], -1) }
    }
    guard let lineReader = ByteLineReader(path: path, offset: offset) else { return ([], -1) }
    var items: [(Int64, [String: Any])] = []
    var newOffset = offset
    while let (lineOffset, data, terminated) = lineReader.readLine() {
        guard terminated else {
            newOffset = lineOffset   // 写入中的尾行：留给下次
            break
        }
        newOffset = lineOffset + Int64(data.count)
        if let obj = parseJSONLine(Data(data.dropLast())) {
            items.append((lineOffset, obj))
        }
    }
    return (items, newOffset)
}

/// iter_zstd_jsonl：zstd 压缩 JSONL（DSH），通过系统 zstd 二进制解压。
public func iterZstdJSONL(_ path: String) -> [(Int, [String: Any])] {
    let zstd = findTool("zstd")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: zstd)
    process.arguments = ["-d", "-c", path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    var out: [(Int, [String: Any])] = []
    for (index, line) in splitJSONLines(data).enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let obj = parseJSONLine(Data(trimmed.utf8)) else { continue }
        out.append((index + 1, obj))
    }
    return out
}

/// _find_tool：PATH → 常见安装目录（.app 图形化启动时 PATH 极简）。
public func findTool(_ name: String) -> String {
    let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
    for dir in pathEnv.split(separator: ":") {
        let candidate = "\(dir)/\(name)"
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    let home = NSHomeDirectory()
    for dir in ["/opt/homebrew/bin", "/usr/local/bin",
                "\(home)/.local/bin", "\(home)/.npm-global/bin"] {
        let candidate = "\(dir)/\(name)"
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return name
}

// ------------------------------------------------------------ 时间解析 ----

private nonisolated(unsafe) let isoFormatterFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private nonisolated(unsafe) let isoFormatterPlain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

/// Python datetime.fromisoformat(ts.replace("Z","+00:00")).timestamp()*1000。
public func parseISODateMs(_ ts: String) -> Int64? {
    let normalized = ts.replacingOccurrences(of: "Z", with: "+00:00")
    if let date = isoFormatterFractional.date(from: normalized)
        ?? isoFormatterPlain.date(from: normalized) {
        return Int64(date.timeIntervalSince1970 * 1000)
    }
    return nil
}

// ------------------------------------------------------------ 会话标题 ----

private let contextPrefixes = ["# AGENTS.md", "<INSTRUCTIONS>", "<environment_context>",
                               "<system-reminder>", "Caveat:", "<command-", "<local-command",
                               "<recommended_plugins", "<user_instructions",
                               "## Referenced ChatGPT conversation", "<task-notification",
                               "The following is the Codex agent history"]

private func contentText(_ content: Any?) -> String {
    if let s = content as? String { return s }
    if let list = content as? [Any] {
        return list.compactMap { block -> String? in
            guard let b = block as? [String: Any],
                  let type = b["type"] as? String,
                  type == "text" || type == "input_text" else { return nil }
            return b["text"] as? String ?? ""
        }.joined(separator: " ")
    }
    return ""
}

/// user_text：从 JSONL 行提取首个真实用户消息（跳过 AGENTS.md/环境上下文注入）。
/// 覆盖 claude(type=user)、pi(type=message role=user)、codex(response_item role=user)。
public func userText(_ obj: [String: Any]) -> String {
    var text = ""
    let kind = obj["type"] as? String
    if kind == "user" || kind == "message" {
        if let msg = obj["message"] as? [String: Any], msg["role"] as? String == "user" {
            text = contentText(msg["content"])
        }
    } else if kind == "response_item" {
        if let payload = obj["payload"] as? [String: Any], payload["role"] as? String == "user" {
            text = contentText(payload["content"])
        }
    }
    text = collapseWhitespace(text)
    if text.isEmpty || contextPrefixes.contains(where: { text.hasPrefix($0) }) {
        return ""
    }
    return truncate120(text)
}

// ------------------------------------------------------------ JSON 取值 ----

/// Python `obj.get(k) or 0`：None/缺失/0 → 0；Bool 视为 1/0（Python bool 是 int）。
public func jsonInt(_ value: Any?) -> Int64 {
    switch value {
    case let n as NSNumber:
        return n.int64Value
    case let n as Int64: return n
    case let n as Int: return Int64(n)
    case let n as Double: return Int64(n)
    case let b as Bool: return b ? 1 : 0
    default: return 0
    }
}

/// Python isinstance(value, int) and not bool 且 >= 0（codex _counts 严格校验）。
public func jsonStrictNonNegativeInt(_ value: Any?) -> Int64? {
    guard let n = value as? NSNumber else { return nil }
    if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
    if CFNumberIsFloatType(n as CFNumber) { return nil }
    let v = n.int64Value
    return v >= 0 ? v : nil
}

/// Python `a or b`（通用）：a 为 nil/NSNull/空串/0/false 时取 b。
public func jsonOrAny(_ a: Any?, _ b: Any?) -> Any? {
    switch a {
    case nil: return b
    case is NSNull: return b
    case let s as String: return s.isEmpty ? b : a
    case let n as NSNumber:
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? a : b }
        return n.doubleValue == 0 ? b : a
    default: return a
    }
}

public func jsonOrAny(_ a: Any?, _ b: Any?, _ c: Any?) -> Any? {
    jsonOrAny(jsonOrAny(a, b), c)
}

public func jsonString(_ value: Any?) -> String? {
    value as? String
}

/// Python `a or b or 0`：第一个真值（非 0 / 非 nil）胜出。
public func jsonOrInt(_ first: Any?, _ second: Any?) -> Int64 {
    let a = jsonInt(first)
    return a != 0 ? a : jsonInt(second)
}

/// Python `a or b`（字符串）：空串 / 缺失回退。
public func jsonOrString(_ first: Any?, _ second: Any?) -> String {
    if let s = first as? String, !s.isEmpty { return s }
    return (second as? String) ?? ""
}


public func jsonOrString(_ first: Any?, _ second: Any?, _ third: Any?) -> String {
    let value = jsonOrString(first, second)
    return value.isEmpty ? (third as? String ?? "") : value
}

/// Stable identifier extraction for JSON values that may encode ids as either
/// strings or JSON numbers.  Numeric sequence ids must not collapse to one
/// empty call id when they are used as activity identities.
public func jsonIdentifier(_ values: Any?...) -> String {
    for value in values {
        if let string = value as? String, !string.isEmpty { return string }
        if let number = value as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.stringValue
        }
    }
    return ""
}
