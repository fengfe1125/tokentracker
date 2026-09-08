//
//  CodexAccount.swift
//  TokenTrackerCore
//
//  Codex 多账号切换的账号模型：一份 auth.json 快照 + 展示用元数据。
//  bundle 存整份 auth.json（auth_mode / OPENAI_API_KEY / tokens / last_refresh），
//  保证切换写回时不丢键；用 [String: Any] + JSONSerialization，与项目现有
//  JSON 取值习惯一致（见 CodexBilling.credentials）。
//

import Foundation

public struct CodexAccount: Identifiable, Equatable, @unchecked Sendable {
    /// auth.json 的 tokens.account_id：账号唯一标识，也是切换主键。
    public var id: String
    /// 用户备注名。
    public var name: String
    /// 可选：从 tokens.id_token(JWT) 解出的 email，仅展示。
    public var email: String?
    /// 可选：wham 返回的 plan_type，仅展示。
    public var plan: String?
    /// 整份 auth.json 快照（切换时原样原子写回）。
    public var bundle: [String: Any]
    public var addedAt: Date
    public var lastUsedAt: Date?

    public init(id: String, name: String, email: String? = nil, plan: String? = nil,
                bundle: [String: Any], addedAt: Date = Date(), lastUsedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.email = email
        self.plan = plan
        self.bundle = bundle
        self.addedAt = addedAt
        self.lastUsedAt = lastUsedAt
    }

    /// bundle 含 [String: Any]，无法自动 Equatable；用 NSDictionary 深比较。
    public static func == (lhs: CodexAccount, rhs: CodexAccount) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name
            && lhs.email == rhs.email && lhs.plan == rhs.plan
            && lhs.addedAt == rhs.addedAt && lhs.lastUsedAt == rhs.lastUsedAt
            && (lhs.bundle as NSDictionary) == (rhs.bundle as NSDictionary)
    }

    // ------------------------------------------------------------ 序列化 ----

    /// 落盘表示：日期用 epoch 秒（跨语言可读，与项目其它 JSON 一致）。
    func toDict() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "name": name,
            "bundle": bundle,
            "addedAt": addedAt.timeIntervalSince1970,
        ]
        if let email { dict["email"] = email }
        if let plan { dict["plan"] = plan }
        if let lastUsedAt { dict["lastUsedAt"] = lastUsedAt.timeIntervalSince1970 }
        return dict
    }

    /// 反序列化：缺 id/bundle 视为坏记录，返回 nil（load 侧 compactMap 丢弃）。
    init?(dict: [String: Any]) {
        guard let id = dict["id"] as? String,
              let bundle = dict["bundle"] as? [String: Any] else { return nil }
        self.id = id
        self.name = dict["name"] as? String ?? id
        self.email = dict["email"] as? String
        self.plan = dict["plan"] as? String
        self.bundle = bundle
        self.addedAt = (dict["addedAt"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date()
        self.lastUsedAt = (dict["lastUsedAt"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue) }
    }

    // ------------------------------------------------------------ JWT ----

    /// 从 bundle 的 tokens.id_token(JWT) 解出 email（仅展示；解不出返回 nil）。
    /// 不校验签名——只用于 UI 上区分账号，凭据本身仍原样存 bundle。
    public static func email(fromBundle bundle: [String: Any]) -> String? {
        guard let tokens = bundle["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String else { return nil }
        let segments = idToken.split(separator: ".")
        guard segments.count >= 2,
              let payloadData = base64URLDecode(String(segments[1])),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else { return nil }
        return payload["email"] as? String
    }

    /// base64url 解码（JWT 段无 padding，先还原成标准 base64）。
    static func base64URLDecode(_ segment: String) -> Data? {
        var text = segment.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        return Data(base64Encoded: text)
    }
}
