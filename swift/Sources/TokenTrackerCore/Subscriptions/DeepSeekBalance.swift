import Foundation

public struct DeepSeekBalance {
    public let http: BillingHTTP
    public init(http: @escaping BillingHTTP = BillingNet.httpJSON) { self.http = http }
    public func fetch(key: String) -> SubscriptionSnapshot {
        let (status, data) = http("https://api.deepseek.com/user/balance", ["Authorization":"Bearer \(key)","Accept":"application/json"], nil, "GET")
        if status == 401 || status == 403 { return SubscriptionSnapshot(status: .expired, message: "DeepSeek API Key 无效或已过期") }
        guard status == 200 else { return SubscriptionSnapshot(status: .failed, message: "DeepSeek 余额接口返回 HTTP \(status)") }
        guard let rows=data["balance_infos"] as? [[String:Any]] else { return SubscriptionSnapshot(status: .failed, message: "DeepSeek 余额响应格式异常") }
        let balances=rows.compactMap { r -> SubscriptionBalance? in
            guard let c=r["currency"] as? String else{return nil}
            return SubscriptionBalance(currency:c,total:subscriptionDecimal(r["total_balance"]),granted:subscriptionDecimal(r["granted_balance"]),toppedUp:subscriptionDecimal(r["topped_up_balance"]))
        }
        return SubscriptionSnapshot(status: .current, balances: balances, sampledAt: Date(), message: (data["is_available"] as? Bool) == false ? "余额不足以调用 API" : "")
    }
}
