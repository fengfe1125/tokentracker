//
//  SQLite.swift
//  TokenTrackerCore
//
//  系统 libsqlite3 的薄封装（零第三方依赖，替代 GRDB）。
//  只覆盖 db.py 用到的语义：参数绑定、行字典、事务、changes 计数、
//  只读打开、备份 API。
//

import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// 行值：Int64 / Double / String / nil（对齐 Python sqlite3.Row 的取值习惯）。
public struct Row {
    public let values: [String: Any?]

    public subscript(_ key: String) -> Any? {
        values[key] ?? nil
    }

    public func int(_ key: String) -> Int64 {
        if let n = values[key] as? Int64 { return n }
        if let n = values[key] as? Double { return Int64(n) }
        if let n = values[key] as? String { return Int64(n) ?? 0 }
        return 0
    }

    public func intOrNil(_ key: String) -> Int64? {
        if let n = values[key] as? Int64 { return n }
        if let n = values[key] as? Double { return Int64(n) }
        if let s = values[key] as? String { return Int64(s) }
        return nil
    }

    public func double(_ key: String) -> Double {
        if let n = values[key] as? Double { return n }
        if let n = values[key] as? Int64 { return Double(n) }
        if let s = values[key] as? String { return Double(s) ?? 0 }
        return 0
    }

    public func doubleOrNil(_ key: String) -> Double? {
        if let n = values[key] as? Double { return n }
        if let n = values[key] as? Int64 { return Double(n) }
        if let s = values[key] as? String { return Double(s) }
        return nil
    }

    public func string(_ key: String) -> String {
        if let s = values[key] as? String { return s }
        if let n = values[key] as? Int64 { return String(n) }
        if let n = values[key] as? Double { return String(n) }
        return ""
    }

    public func stringOrNil(_ key: String) -> String? {
        if let s = values[key] as? String { return s }
        return nil
    }
}

public final class SQLiteConnection {
    private var handle: OpaquePointer?

    /// timeout=30s 对齐 Python sqlite3.connect(..., timeout=30)。
    public init(path: String, readOnly: Bool = false) throws {
        var flags: Int32 = SQLITE_OPEN_FULLMUTEX
        if readOnly {
            flags |= SQLITE_OPEN_READONLY
        } else {
            flags |= SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        }
        let rc: Int32
        if readOnly {
            rc = sqlite3_open_v2(path, &handle, flags, nil)
        } else {
            rc = sqlite3_open_v2(path, &handle, flags, nil)
        }
        guard rc == SQLITE_OK else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw SQLiteError(message: "sqlite open \(path): \(msg)")
        }
        sqlite3_busy_timeout(handle, 30_000)
    }

    deinit { sqlite3_close(handle) }

    public var inTransaction: Bool {
        sqlite3_get_autocommit(handle) == 0
    }

    /// 执行并返回影响行数（对齐 Python cursor.rowcount / sqlite3_changes）。
    @discardableResult
    public func execute(_ sql: String, _ args: [Any?] = []) throws -> Int {
        try withStatement(sql, args) { stmt in
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
                throw SQLiteError(message: "step: \(lastErrorMessage()) [\(sql)]")
            }
            return Int(sqlite3_changes(handle))
        }
    }

    public func query(_ sql: String, _ args: [Any?] = []) throws -> [Row] {
        try withStatement(sql, args) { stmt in
            var rows: [Row] = []
            let count = sqlite3_column_count(stmt)
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else {
                    throw SQLiteError(message: "step: \(lastErrorMessage()) [\(sql)]")
                }
                var values: [String: Any?] = [:]
                values.reserveCapacity(Int(count))
                for i in 0..<count {
                    let name = String(cString: sqlite3_column_name(stmt, i))
                    switch sqlite3_column_type(stmt, i) {
                    case SQLITE_INTEGER:
                        values[name] = sqlite3_column_int64(stmt, i)
                    case SQLITE_FLOAT:
                        values[name] = sqlite3_column_double(stmt, i)
                    case SQLITE_TEXT:
                        values[name] = String(cString: sqlite3_column_text(stmt, i))
                    case SQLITE_BLOB:
                        let n = sqlite3_column_bytes(stmt, i)
                        if let ptr = sqlite3_column_blob(stmt, i), n > 0 {
                            values[name] = String(decoding: Data(bytes: ptr, count: Int(n)), as: UTF8.self)
                        } else {
                            values[name] = ""
                        }
                    default:
                        values[name] = nil
                    }
                }
                rows.append(Row(values: values))
            }
            return rows
        }
    }

    public func queryOne(_ sql: String, _ args: [Any?] = []) throws -> Row? {
        try query(sql, args).first
    }

    public func scalarInt(_ sql: String, _ args: [Any?] = []) throws -> Int64 {
        try queryOne(sql, args).flatMap { $0.values.values.first.flatMap { $0 } }
            .map { value -> Int64 in
                if let n = value as? Int64 { return n }
                if let n = value as? Double { return Int64(n) }
                if let s = value as? String { return Int64(s) ?? 0 }
                return 0
            } ?? 0
    }

    /// Python conn.commit()：无事务时是 no-op。
    public func commit() throws {
        if inTransaction { _ = try execute("COMMIT") }
    }

    public func rollback() throws {
        if inTransaction { _ = try execute("ROLLBACK") }
    }

    public func beginImmediate() throws {
        _ = try execute("BEGIN IMMEDIATE")
    }

    /// sqlite3_backup API（对齐 Python conn.backup）。
    public func backup(to destination: SQLiteConnection) throws {
        guard let backup = sqlite3_backup_init(destination.handle, "main", handle, "main") else {
            throw SQLiteError(message: "backup init: \(destination.lastErrorMessage())")
        }
        var rc = sqlite3_backup_step(backup, -1)
        while rc == SQLITE_OK || rc == SQLITE_BUSY || rc == SQLITE_LOCKED {
            if rc != SQLITE_OK { sqlite3_sleep(50) }
            rc = sqlite3_backup_step(backup, -1)
        }
        sqlite3_backup_finish(backup)
        guard rc == SQLITE_DONE else {
            throw SQLiteError(message: "backup step failed: \(rc)")
        }
    }

    public func lastErrorMessage() -> String {
        handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    }

    private func withStatement<T>(_ sql: String, _ args: [Any?],
                                  _ body: (OpaquePointer) throws -> T) throws -> T {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError(message: "prepare: \(lastErrorMessage()) [\(sql)]")
        }
        defer { sqlite3_finalize(stmt) }
        for (index, arg) in args.enumerated() {
            let i = Int32(index + 1)
            // Any? 槽位里的 Optional<Int64> 等嵌套可选必须先解包
            let unwrapped: Any?
            if let arg {
                let mirror = Mirror(reflecting: arg)
                unwrapped = mirror.displayStyle == .optional
                    ? (mirror.children.first?.value)
                    : arg
            } else {
                unwrapped = nil
            }
            let rc: Int32
            switch unwrapped {
            case nil, is NSNull:
                rc = sqlite3_bind_null(stmt, i)
            case let n as Int64:
                rc = sqlite3_bind_int64(stmt, i, n)
            case let n as Int:
                rc = sqlite3_bind_int64(stmt, i, Int64(n))
            case let n as Double:
                rc = sqlite3_bind_double(stmt, i, n)
            case let n as NSNumber:
                // NSNumber 可能是 Bool（Python True/False → sqlite 1/0）
                if CFGetTypeID(n) == CFBooleanGetTypeID() {
                    rc = sqlite3_bind_int64(stmt, i, n.boolValue ? 1 : 0)
                } else if CFNumberIsFloatType(n as CFNumber) {
                    rc = sqlite3_bind_double(stmt, i, n.doubleValue)
                } else {
                    rc = sqlite3_bind_int64(stmt, i, n.int64Value)
                }
            case let s as String:
                rc = sqlite3_bind_text(stmt, i, (s as NSString).utf8String, -1, SQLITE_TRANSIENT_SWIFT)
            default:
                throw SQLiteError(message: "unsupported bind type: \(type(of: unwrapped!))")
            }
            if rc != SQLITE_OK {
                throw SQLiteError(message: "bind \(i): \(lastErrorMessage()) [\(sql)]")
            }
        }
        return try body(stmt)
    }
}

private let SQLITE_TRANSIENT_SWIFT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension SQLiteConnection: @unchecked Sendable {}

/// 只读打开（工具可能正在写库），对齐 _util.sqlite_ro。
public func sqliteRO(_ path: String) throws -> SQLiteConnection {
    try SQLiteConnection(path: path, readOnly: true)
}
