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

func UIDate(_ epoch: Double) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: Date(timeIntervalSince1970: epoch))
}

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
case "export-public":
    // 只写 stdout，全程不联网 —— 先亲眼读完自己的载荷，再谈发布。
    let store = try openStore()
    var days = 365
    if let index = args.firstIndex(of: "--days"), index + 1 < args.count,
       let value = Int(args[index + 1]) { days = value }
    let payload = try PublicStatsBuilder.build(store: store, days: days)
    let data = try payload.encoded(pretty: args.contains("--pretty"))
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))

case "publish":
    let settings = SettingsStore()
    let statePath = NSHomeDirectory() + "/.tokentracker/publish_state.json"

    if args.contains("--set-token") {
        // token 从 stdin 读，不走命令行参数 —— argv 里的密钥 ps 就能看见。
        let handle = settings.effectiveString("publish_handle") ?? ""
        guard !handle.isEmpty else {
            print("✗ 先设置 publish_handle：tt-swift publish --config handle=<你的用户名>")
            exit(1)
        }
        FileHandle.standardError.write(Data("请粘贴 token 后回车（不回显在日志里）: ".utf8))
        guard let line = readLine(strippingNewline: true), !line.isEmpty else {
            print("✗ 未读到 token"); exit(1)
        }
        let store = KeychainPublishTokenStore()
        switch store.writeReportingLocation(handle: handle, token: line) {
        case .keychain:
            print("✓ token 已写入钥匙串（服务 \(KeychainPublishTokenStore.service)，账号 \(handle)）")
        case .file:
            print("✓ 钥匙串不可用，已写入 \(store.fallbackPath)（权限 0600）")
        case nil:
            print("✗ token 写入失败"); exit(1)
        }
        exit(0)
    }

    if args.contains("--config") {
        // 形如 --config handle=sakura endpoint=https://tt.example.com enabled=true
        for pair in args where pair.contains("=") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let (name, raw) = (parts[0], parts[1])
            let key = "publish_" + name
            let ok: Bool
            switch name {
            case "enabled": ok = settings.set(key: key, value: NSNumber(value: raw == "true"))
            case "days":    ok = settings.set(key: key, value: NSNumber(value: Int(raw) ?? 0))
            default:        ok = settings.set(key: key, value: raw)
            }
            print(ok ? "✓ \(key) = \(raw)" : "✗ \(key) 校验未通过：\(raw)")
        }
        exit(0)
    }

    if args.contains("--status") {
        let state = PublishState.load(path: statePath)
        let config = settings.effective()
        print("启用      \((config["publish_enabled"] as? NSNumber)?.boolValue ?? false)")
        print("端点      \(config["publish_endpoint"] as? String ?? "（未设置）")")
        print("用户名    \(config["publish_handle"] as? String ?? "（未设置）")")
        print("窗口      \((config["publish_days"] as? NSNumber)?.intValue ?? 365) 天")
        print("上次成功  \(state.lastOkAt > 0 ? UIDate(state.lastOkAt) : "从未")")
        print("连续失败  \(state.consecutiveFailures)")
        if !state.lastError.isEmpty { print("上次错误  \(state.lastError)") }
        exit(0)
    }

    let store = try openStore()
    if args.contains("--dry-run") {
        let days = settings.effectiveInt("publish_days") ?? 365
        let payload = try PublicStatsBuilder.build(store: store, days: days)
        let body = try payload.encoded()
        let state = PublishState.load(path: statePath)
        let hash = PublicStatsPublisher.contentHash(payload)
        let config = settings.effective()
        let decision = publishDecision(
            enabled: (config["publish_enabled"] as? NSNumber)?.boolValue ?? false,
            configured: !(config["publish_endpoint"] as? String ?? "").isEmpty
                     && !(config["publish_handle"] as? String ?? "").isEmpty,
            lastHash: state.lastHash, newHash: hash,
            lastOkAt: state.lastOkAt, failures: state.consecutiveFailures,
            now: Date().timeIntervalSince1970)
        print("载荷 \(body.count) 字节 / \(payload.range.days) 天 / 内容哈希 \(hash.prefix(16))")
        print("决策 \(decision)")
        exit(0)
    }

    let outcome = PublicStatsPublisher(settings: settings, statePath: statePath)
        .publishIfNeeded(store: store, force: args.contains("--force"))
    switch outcome.decision {
    case .publish:
        if outcome.error.isEmpty {
            print("✓ 已上报 \(outcome.bytes) 字节")
        } else {
            print("✗ 上报失败：\(outcome.error)"); exit(1)
        }
    case .skipDisabled:      print("— 未启用（publish_enabled=false）")
    case .skipUnconfigured:  print("— 未配置 endpoint / handle")
    case .skipUnchanged:     print("— 内容未变化，跳过")
    case .skipThrottled:     print("— 距上次上报不足 \(Int(PublishThrottle.minInterval)) 秒，跳过")
    case .skipBackoff:       print("— 处于失败退避窗口，跳过")
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
      tt-swift export-public [--days 365] [--pretty]
                                 生成公开统计载荷到 stdout（不联网）
      tt-swift publish [--dry-run|--force|--status]
                                 上报公开统计到配置的服务
      tt-swift publish --config handle=<名> endpoint=<https://…> enabled=true
      tt-swift publish --set-token   从 stdin 读 token 写入钥匙串
    环境变量: TOKENTRACKER_DB / TOKENTRACKER_PRICES / TOKENTRACKER_QUOTAS 等
    """)
}
