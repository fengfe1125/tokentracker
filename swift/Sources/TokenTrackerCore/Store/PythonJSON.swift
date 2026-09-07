//
//  PythonJSON.swift
//  TokenTrackerCore
//
//  复刻 Python json.dumps 的字符串转义与分隔符（ensure_ascii=True、
//  分隔符 ", " / ": "）。aggregate 快照的 src_key 摘要（sha256）和
//  hermes 的 identity 字符串必须与 Python 逐字节一致，否则两版共用
//  同一个 usage.db 时会生成不同的键。
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// json.dumps(str) with ensure_ascii=True：控制字符短转义、其余 <0x20 与非 ASCII
/// 逐 UTF-16 码元 \uXXXX（小写十六进制，与 CPython 一致）。
public func pythonJSONString(_ s: String) -> String {
    var out = "\""
    out.reserveCapacity(s.utf16.count + 2)
    for unit in s.utf16 {
        switch unit {
        case 0x22: out += "\\\""       // "
        case 0x5C: out += "\\\\"       // \
        case 0x08: out += "\\b"
        case 0x09: out += "\\t"
        case 0x0A: out += "\\n"
        case 0x0C: out += "\\f"
        case 0x0D: out += "\\r"
        case 0x00...0x1F:              // 其余控制字符
            out += String(format: "\\u%04x", unit)
        case _ where unit > 0x7E:      // 非 ASCII（含代理项码元）
            out += String(format: "\\u%04x", unit)
        default:
            out.append(Character(UnicodeScalar(unit)!))
        }
    }
    out += "\""
    return out
}

/// json.dumps(value)：仅支持本仓库快照用到的类型（String / NSNull / Int / Double / 数组）。
public func pythonJSONDumps(_ value: Any?) -> String {
    switch value {
    case nil:
        return "null"
    case let s as String:
        return pythonJSONString(s)
    case let n as Int64:
        return String(n)
    case let n as Int:
        return String(n)
    case let n as Double:
        // Python repr(float)：近似最短表示；本仓库只序列化成本小数。
        if n == n.rounded() && abs(n) < 1e15 {
            return String(format: "%.1f", n)
        }
        var text = String(n)
        if !text.contains(".") && !text.contains("e") { text += ".0" }
        return text
    case let arr as [Any?]:
        return "[" + arr.map { pythonJSONDumps($0) }.joined(separator: ", ") + "]"
    default:
        return "null"
    }
}

/// sha256 十六进制（对齐 Python hashlib.sha256(...).hexdigest()）。
public func sha256Hex(_ text: String) -> String {
    #if canImport(CryptoKit)
    let digest = SHA256.hash(data: Data(text.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
    #else
    fatalError("CryptoKit unavailable")
    #endif
}

/// Python round(x, ndigits)：half-even 舍入。
public func roundHalfEven(_ value: Double, _ digits: Int) -> Double {
    let factor = pow(10.0, Double(digits))
    return (value * factor).rounded(.toNearestOrEven) / factor
}
