//
//  TestSupport.swift
//  TokenTrackerCoreTests
//
//  共享 fixture 工具（对齐 tests/test_scanners.py 的 PRICES / TS / write_jsonl）。
//

import Foundation
import XCTest
@testable import TokenTrackerCore

/// tests/test_scanners.py 的 PRICES
let testPrices = PriceTable(
    fallback: nil,
    models: ["test-model": PriceRate(input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2)])

let fixtureTS = "2026-08-25T01:00:00Z"
let fixtureTSMs: Int64 = 1_787_619_600_000

/// usage(inp=100, out=10, cached=20, written=0)
func fixtureUsage(_ inp: Int64 = 100, _ out: Int64 = 10,
                  _ cached: Int64 = 20, _ written: Int64 = 0) -> [String: Any] {
    ["input_tokens": inp, "output_tokens": out,
     "cached_input_tokens": cached, "cache_write_input_tokens": written,
     "total_tokens": inp + out]
}

func writeJSONL(_ path: String, _ objects: [[String: Any]]) {
    let dir = (path as NSString).deletingLastPathComponent
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var text = ""
    for obj in objects {
        let data = try! JSONSerialization.data(withJSONObject: obj)
        text += String(data: data, encoding: .utf8)! + "\n"
    }
    try! text.write(toFile: path, atomically: true, encoding: .utf8)
}

final class TempDir {
    let url: URL
    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tt_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: url.path, withIntermediateDirectories: true)
    }
    func path(_ components: String...) -> String {
        components.reduce(url.path) { ($0 as NSString).appendingPathComponent($1) }
    }
    func store() throws -> UsageStore {
        try UsageStore(path: path("usage.db"))
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}


/// @Sendable 闭包里的可变状态盒。
final class StateBox<T>: @unchecked Sendable {
    var value: T
    init(_ v: T) { value = v }
}
