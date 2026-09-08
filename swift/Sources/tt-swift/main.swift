//
//  main.swift
//  tt-swift — TokenTracker 原生 CLI（替代 Python tt 的 scan/stats/detect/quotas）
//
//  复用 TokenTrackerCore；与 App/浏览器模式共用 ~/.tokentracker/usage.db。
//

import Foundation
import TokenTrackerCore

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"

let env = ProcessInfo.processInfo.environment
let dbPath = env["TOKENTRACKER_DB"] ?? NSHomeDirectory() + "/.tokentracker/usage.db"

func openStore() throws -> UsageStore {
    let store = try UsageStore(path: dbPath)
    if let pricesPath = env["TOKENTRACKER_PRICES"] {
        store.priceTableForMigration = PriceTable.load(from: pricesPath)
    }
    return store
}

func prices() -> PriceTable {
    env["TOKENTRACKER_PRICES"].map { PriceTable.load(from: $0) } ?? .default
}

func fmt(_ n: Int64) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    return f.string(from: NSNumber(value: n)) ?? "\(n)"
}

func fmtCost(_ v: Double) -> String { String(format: "$%.2f", v) }

switch command {
case "detect":
    let store = try openStore()
    let runner = ScanRunner(store: store, prices: prices(), roots: ScanRoots())
    for (name, info) in runner.detectAll().sorted(by: { $0.key < $1.key }) {
        print("\(info.installed ? "✅" : "—") \(name.padding(toLength: 10, withPad: " ", startingAt: 0)) \(info.detail)")
    }

case "scan":
    let store = try openStore()
    let full = args.contains("--full")
    let runner = ScanRunner(store: store, prices: prices(), roots: ScanRoots())
    let results = runner.runAll(full: full)
    let repriced = try store.reprice(prices())
    for tool in ScannerRegistry.all {
        guard let r = results[tool] else { continue }
        if let error = r.error {
            print("✗ \(tool.padding(toLength: 10, withPad: " ", startingAt: 0)) 出错: \(error)")
        } else if let skipped = r.skipped {
            print("— \(tool.padding(toLength: 10, withPad: " ", startingAt: 0)) \(skipped)")
        } else {
            print("✓ \(tool.padding(toLength: 10, withPad: " ", startingAt: 0)) 新增 \(r.added) 条 / 更新 \(r.updated) 条 / 文件 \(r.files) 个")
            if r.activityAdded > 0 || r.activityUpdated > 0 {
                print("  活动: 新增 \(r.activityAdded) 条 / 补全 \(r.activityUpdated) 条")
            }
        }
        if r.counterResets > 0 {
            print("⚠ \(tool): \(r.counterResets) 个累计计数器重置，已更新基线并保留历史")
        }
        if let warning = r.warning {
            print("⚠ \(tool): \(warning)")
        }
    }
    if repriced > 0 { print("✓ reprice 按价格表回填 \(repriced) 条成本") }

case "stats":
    let store = try openStore()
    let range: String = args.dropFirst().first == "--range"
        ? args.dropFirst(2).first ?? "all" : "all"
    let (rows, total, summary) = try store.stats(rangeKey: range)
    print("范围: \(range)")
    print("工具        会话    tokens          成本")
    for row in rows {
        print("\(row.tool.padding(toLength: 11, withPad: " ", startingAt: 0)) "
              + "\(row.sessions)\t\(fmt(row.tokens))\t\(fmtCost(row.cost))")
    }
    print("合计        \(total.sessions)\t\(fmt(total.tokens))\t\(fmtCost(total.cost))")
    if summary.unallocatedTokens > 0 {
        print("（另有未分配时间的历史: \(fmt(summary.unallocatedTokens)) tokens，"
              + "估算: \(fmt(summary.estimatedTokens))）")
    }

case "activity":
    let store = try openStore()
    func option(_ name: String, default fallback: String) -> String {
        guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else {
            return fallback
        }
        return args[index + 1]
    }
    let range = option("--range", default: "all")
    let group = option("--group", default: "tool")
    let confidence = option("--confidence", default: "exact")
    let agent: String? = {
        guard let index = args.firstIndex(of: "--agent"), args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }()
    let rows = try store.activitySummary(
        rangeKey: range, agent: agent, group: group, confidence: confidence)
    if args.contains("--json") {
        let encodedRows: [[String: Any]] = rows.map {
            ["name": $0.name, "calls": $0.calls, "sessions": $0.sessions,
             "success": $0.success, "error": $0.errors, "denied": $0.denied,
             "unknown": $0.unknown, "exact": $0.exact, "derived": $0.derived,
             "last_used": $0.lastUsed]
        }
        let payload: [String: Any] = [
            "range": range, "group": group, "confidence": confidence,
            "rows": encodedRows, "capabilities": activityCapabilities,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8) ?? "{}")
    } else {
        print("范围: \(range)  分组: \(group)  证据: \(confidence)")
        print("名称\t调用\t会话\t成功\t失败\t拒绝\t未知\t推断")
        for row in rows {
            print("\(row.name)\t\(row.calls)\t\(row.sessions)\t\(row.success)\t"
                  + "\(row.errors)\t\(row.denied)\t\(row.unknown)\t\(row.derived)")
        }
    }
case "quotas":
    let store = try openStore()
    let config = QuotasConfig.load(from: env["TOKENTRACKER_QUOTAS"] ?? "")
    let service = OfficialQuotaService()
    let entries = try QuotaEstimator.compute(store: store, config: config,
                                             nowMs: store.nowMs()) { name in
        service.providerResult(name)
    }
    for entry in entries {
        let official = entry.source == "official" ? "[官方]" : "[本地]"
        print("\(entry.name)  \(official)  \(entry.plan)")
        for w in entry.windows {
            let pct = w.pct.map { String(format: "%.1f%%", $0) } ?? "—"
            let marker = w.source == "official" ? (w.stale ? "~官方(旧)" : "官方") : "≈本地"
            print("  \(w.label.padding(toLength: 10, withPad: " ", startingAt: 0)) \(pct)  \(marker)")
        }
        if !entry.note.isEmpty { print("  ⚠ \(entry.note)") }
    }

default:
    print("""
    tt-swift — TokenTracker 原生 CLI
      tt-swift detect            查看各工具数据源是否被识别
      tt-swift scan [--full]     扫描日志入库（增量，可重复执行）
      tt-swift stats [--range day|week|month|all]
      tt-swift activity [--range day|week|month|all] [--group agent|tool|skill]
                        [--agent NAME] [--confidence exact|derived|all] [--json]
      tt-swift quotas            终端查看全部配额窗口
    环境变量: TOKENTRACKER_DB / TOKENTRACKER_PRICES / TOKENTRACKER_QUOTAS 等
    """)
}
