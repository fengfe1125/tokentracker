//
//  BillingHTTP.swift
//  TokenTrackerCore
//
//  移植 billing.py 的 _http_json / _pct / _iso_ms：同步 JSON HTTP 调用
//  （URLSession + 信号量，仅后台线程调用），Retry-After 支持秒数与
//  HTTP-date 两种格式。
//

import Foundation

public typealias BillingHTTP = (String, [String: String], Data?, String) -> (Int, [String: Any])

public enum BillingNet {
    /// 默认实现：URLSession 同步化（timeout=8s，对齐 urllib.request.urlopen）。
    public static func httpJSON(url: String, headers: [String: String],
                                body: Data? = nil, method: String = "GET")
        -> (Int, [String: Any]) {
        guard let endpoint = URL(string: url) else {
            return (0, ["error": "bad url"])
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 8
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Int, [String: Any]) = (0, ["error": "no response"])
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = (0, ["error": error.localizedDescription])
                return
            }
            guard let http = response as? HTTPURLResponse else {
                result = (0, ["error": "not http"])
                return
            }
            var obj: [String: Any] = [:]
            if let data, !data.isEmpty,
               let parsed = try? JSONSerialization.jsonObject(with: data),
               let dict = parsed as? [String: Any] {
                obj = dict
            }
            if let retryAfter = http.value(forHTTPHeaderField: "Retry-After") {
                var seconds = Int(retryAfter)
                if seconds == nil {
                    // HTTP-date 形式
                    let fmt = DateFormatter()
                    fmt.locale = Locale(identifier: "en_US_POSIX")
                    fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                    if let date = fmt.date(from: retryAfter) {
                        seconds = Int(ceil(date.timeIntervalSince1970
                                           - Date().timeIntervalSince1970))
                    }
                }
                if let seconds, seconds > 0 {
                    obj["_retry_after"] = seconds
                }
            }
            result = (http.statusCode, obj)
        }
        task.resume()
        if semaphore.wait(timeout: .now() + 12) == .timedOut {
            task.cancel()
            return (0, ["error": "timeout"])
        }
        return result
    }

    /// ISO 时间串 → epoch 毫秒（对齐 billing._iso_ms）。
    public static func isoMs(_ value: Any?) -> Int64? {
        guard let value else { return nil }
        let s = String(describing: value)
        guard !s.isEmpty else { return nil }
        return parseISODateMs(s)
    }

    /// 官方 utilization 字段是百分比（含 <1% 的值）；无效/非有限数返回 nil。
    public static func pct(_ value: Any?) -> Double? {
        guard let value else { return nil }
        let p: Double
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            p = n.doubleValue
        } else if let s = value as? String, let parsed = Double(s) {
            p = parsed
        } else {
            return nil
        }
        return p.isFinite ? p : nil
    }
}
