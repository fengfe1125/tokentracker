import Foundation
import TokenTrackerCore

/// Adapts Core-owned display values without changing stored records or CLI output.
extension UIFormat {
    static func explanation(_ value: ConsumptionExplanation) -> String {
        L10n.text("与过去 14 天相同时刻比较，有效样本 \(value.samples) 天；中位数 \(Int64(value.baseline)) Token，今天 \(value.current) Token。高消耗不代表浪费。")
    }

    static func riskDetail(_ risk: RiskNotice) -> String {
        guard L10n.isEnglish else { return risk.detail }
        // Legacy snapshots contain rendered details. These replacements are scoped to
        // Core's generated risk text, which never contains user titles or paths.
        var detail = risk.detail
        for (zh, en) in [
            ("自然日", "Calendar day"), ("自然周", "Calendar week"), ("自然月", "Calendar month"),
            ("估算美元，非订阅账单", "Estimated USD, not subscription charges"),
            ("统计不完整", "Incomplete coverage"), ("官方用量", "Official usage"),
            ("按近期速度估算，约 ", "At the recent rate, about "), (" 分钟后耗尽", " min until exhausted")
        ] { detail = detail.replacingOccurrences(of: zh, with: en) }
        return detail
    }

    static func appError(_ error: Error) -> L10n.Template {
        if let error = error as? AccountPersistenceError {
            return L10n.Template(stringLiteral: error.description)
        }
        if let error = error as? CodexAccountError {
            switch error {
            case .noLiveCredentials: return "未找到 Codex 登录态（~/.codex/auth.json 缺失或无 tokens.account_id）"
            case .notFound(let id): return "账号不存在：\(id)"
            }
        }
        if let error = error as? UpdateInstallError {
            switch error {
            case .noRelease: return "没有查到发布版本"
            case .noAsset: return "这个版本没有提供 .dmg 安装包"
            case .badJSON: return "GitHub 返回的内容无法解析"
            case .checksumMismatch(let expected, let actual):
                return "下载校验失败（期望 \(expected.prefix(12))…，实际 \(actual.prefix(12))…）"
            case .notAnAppBundle(let path): return "当前不是以 .app 方式运行（\(path)），无法自我更新"
            case .appNotFoundInDMG: return "安装包里找不到 TokenTracker.app"
            case .bundleIDMismatch(let expected, let actual): return "安装包的标识不匹配（期望 \(expected)，实际 \(actual)）"
            case .commandFailed(let command, let code): return "\(command) 失败（退出码 \(code)）"
            }
        }
        return L10n.Template(verbatim: (error as? LocalizedError)?.errorDescription ?? String(describing: error))
    }
}
