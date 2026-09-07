//
//  PriceTable.swift
//  TokenTrackerCore
//
//  价格表移植自 tokentracker/pricing.py：
//  prices.json，单位 美元 / 百万 token；模型名先精确、再最长子串（不区分
//  大小写），最后回退 default；未匹配返回 nil（只统计 token、不计费）。
//

import Foundation

/// 单档费率（字段缺失按 0 计，与 Python `rate.get(..., 0)` 一致）。
public struct PriceRate: Codable, Equatable, Sendable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double

    enum CodingKeys: String, CodingKey {
        case input, output
        case cacheRead = "cache_read"
        case cacheWrite = "cache_write"
    }

    public init(input: Double = 0, output: Double = 0,
                cacheRead: Double = 0, cacheWrite: Double = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(input: try c.decodeIfPresent(Double.self, forKey: .input) ?? 0,
                  output: try c.decodeIfPresent(Double.self, forKey: .output) ?? 0,
                  cacheRead: try c.decodeIfPresent(Double.self, forKey: .cacheRead) ?? 0,
                  cacheWrite: try c.decodeIfPresent(Double.self, forKey: .cacheWrite) ?? 0)
    }
}

public struct PriceTable: Sendable {
    /// 顶层 "default" 回退档（平铺格式下为 nil，与 Python 一致）。
    public var fallback: PriceRate?
    public var models: [String: PriceRate]

    public init(fallback: PriceRate?, models: [String: PriceRate]) {
        self.fallback = fallback
        self.models = models
    }

    /// 与 Python `DEFAULT_PRICES` 保持一致的兜底表（文件缺失/损坏时使用）。
    public static let `default` = PriceTable(
        fallback: PriceRate(input: 2.0, output: 10.0, cacheRead: 0.4, cacheWrite: 2.0),
        models: [
            "claude-opus-4-5": PriceRate(input: 5.0, output: 25.0, cacheRead: 0.5, cacheWrite: 1.25),
            "claude-sonnet-4-5": PriceRate(input: 3.0, output: 15.0, cacheRead: 0.3, cacheWrite: 0.75),
            "claude-haiku": PriceRate(input: 1.0, output: 5.0, cacheRead: 0.1, cacheWrite: 0.25),
            "gpt-5": PriceRate(input: 1.25, output: 10.0, cacheRead: 0.125, cacheWrite: 1.25),
            "gpt-5.6-luna": PriceRate(input: 2.0, output: 12.0, cacheRead: 0.2, cacheWrite: 2.0),
            "deepseek-v4-flash": PriceRate(input: 0.22, output: 0.66, cacheRead: 0.007, cacheWrite: 0.22),
            "deepseek-v4-pro": PriceRate(input: 0.66, output: 1.98, cacheRead: 0.022, cacheWrite: 0.66),
            "kimi-k2": PriceRate(input: 0.6, output: 2.5, cacheRead: 0.1, cacheWrite: 0.6),
            "kimi-k3": PriceRate(input: 0.6, output: 2.5, cacheRead: 0.1, cacheWrite: 0.6),
            "grok-4.6": PriceRate(input: 3.0, output: 15.0, cacheRead: 0.3, cacheWrite: 3.0),
        ])

    /// 解析 prices.json。含 "models" 键 → {models: 它, fallback: 顶层 default}；
    /// 否则整表视为 models、无 fallback（对齐 Python `load_prices`）。
    public static func load(from path: String) -> PriceTable {
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any]
        else { return .default }

        func rate(_ value: Any) -> PriceRate? {
            guard let d = value as? [String: Any] else { return nil }
            func num(_ key: String) -> Double { (d[key] as? NSNumber)?.doubleValue ?? 0 }
            return PriceRate(input: num("input"), output: num("output"),
                             cacheRead: num("cache_read"), cacheWrite: num("cache_write"))
        }

        if let nested = dict["models"] as? [String: Any] {
            return PriceTable(fallback: rate(dict["default"] as Any),
                              models: nested.compactMapValues(rate))
        }
        return PriceTable(fallback: nil, models: dict.compactMapValues(rate))
    }

    /// 返回成本（美元）；模型为空或无任何费率可匹配时返回 nil。
    public func cost(for model: String, input: Int64, output: Int64,
                     cacheRead: Int64 = 0, cacheWrite: Int64 = 0) -> Double? {
        guard !model.isEmpty else { return nil }
        let m = model.lowercased()
        var rate = models[m]
        if rate == nil {
            // 子串匹配取最长命中键，避免 "gpt-5" 抢先命中 "gpt-5.6-luna"
            var best = -1
            for (key, value) in models where m.contains(key.lowercased()) {
                let k = key.count
                if k > best {
                    best = k
                    rate = value
                }
            }
        }
        guard let resolved = rate ?? fallback else { return nil }
        let cost = (Double(input) * resolved.input
                    + Double(output) * resolved.output
                    + Double(cacheRead) * resolved.cacheRead
                    + Double(cacheWrite) * resolved.cacheWrite) / 1e6
        // Python round(x, 8) 是 half-even；不能用默认的 half-away。
        return (cost * 1e8).rounded(.toNearestOrEven) / 1e8
    }
}
