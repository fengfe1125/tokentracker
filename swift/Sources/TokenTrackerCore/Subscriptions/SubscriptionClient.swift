import Foundation

/// Queries exactly the discovered account. Never refreshes, swaps or writes tokens.
public struct SubscriptionClient {
    public var http: BillingHTTP
    public var clock: () -> Date
    public init(http: @escaping BillingHTTP = SubscriptionHTTP.call, clock: @escaping () -> Date = Date.init) {
        self.http=http; self.clock=clock
    }
    public func fetch(_ account: SubscriptionAccount) -> SubscriptionSnapshot {
        let credential=account.credential
        let access=credential["access"] ?? "", key=credential["key"] ?? ""
        let supported=Set(["claude","codex","kimi","go","deepseek","copilot","grok","workbuddy","workbuddy-ai"])
        guard supported.contains(account.provider) else {
            return SubscriptionSnapshot(status:.unsupported,message:"已发现配置；暂未接入可可靠读取的额度接口")
        }
        guard !access.isEmpty || !key.isEmpty else {
            return SubscriptionSnapshot(status:.signedOut,message:"未找到可用登录态，请在来源工具中登录")
        }
        if let text=credential["expires"], let expiry=Double(text), expiry > 0,
           (expiry > 1e12 ? expiry/1000 : expiry) <= clock().timeIntervalSince1970 {
            return SubscriptionSnapshot(status:.expired,message:"登录态已过期，请打开来源工具续期")
        }
        if account.provider == "deepseek" {
            guard !key.isEmpty else { return SubscriptionSnapshot(status:.signedOut,message:"未找到 DeepSeek 官方 API Key") }
            var result=DeepSeekBalance(http:http).fetch(key:key)
            if result.status == .current { result.sampledAt=clock() }
            return result
        }
        var url="", headers=["Accept":"application/json"], method="GET"
        var body:Data?
        var privateAPI=true
        switch account.provider {
        case "claude":
            guard !access.isEmpty else { return SubscriptionSnapshot(status:.unsupported,message:"发现 Anthropic API Key；它不能读取 Claude 订阅配额") }
            url=ClaudeBilling.usageURL
            headers["Authorization"]="Bearer " + access
            headers["anthropic-beta"]="oauth-2025-04-20"
            headers["User-Agent"]=ClaudeBilling.userAgent
        case "codex":
            url=CodexBilling.whamURL
            headers["Authorization"]="Bearer " + access
            headers["User-Agent"]=CodexBilling.cliUA
            if let id=credential["account"] { headers["ChatGPT-Account-Id"]=id }
        case "kimi":
            let host=credential["domain"] == "api.kimi.ai" ? "api.kimi.ai" : "api.kimi.com"
            url="https://"+host+"/coding/v1/usages"
            headers["Authorization"]="Bearer " + (access.isEmpty ? key : access)
        case "go":
            url=GoBilling.quotaURL
            headers["Authorization"]="Bearer " + key
            headers["User-Agent"]=GoBilling.browserUA
        case "copilot":
            url="https://api.github.com/copilot_internal/user"
            headers["Authorization"]="token " + (access.isEmpty ? key : access)
            headers["Editor-Version"]="vscode/1.99.0"
            headers["Editor-Plugin-Version"]="copilot/1.300.0"
        case "grok":
            url="https://cli-chat-proxy.grok.com/v1/billing?format=credits"
            headers["Authorization"]="Bearer " + (access.isEmpty ? key : access)
        case "workbuddy", "workbuddy-ai":
            let host=account.provider == "workbuddy" ? "copilot.tencent.com" : "www.workbuddy.ai"
            url="https://"+host+"/billing/meter/get-user-resource-summary"
            headers["Authorization"]="Bearer " + access
            headers["X-User-Id"]=credential["uid"] ?? ""
            headers["X-Domain"]=credential["domain"] ?? ""
            headers["X-Product"]="SaaS"; headers["X-IDE-Type"]="WorkBuddy"
            headers["User-Agent"]="WorkBuddy/1.0"
            headers["Content-Type"]="application/json"
            method="POST"; body=Data("{}".utf8)
        default: privateAPI=false
        }
        guard let endpoint=URL(string:url), SubscriptionHTTP.permits(endpoint) else {
            return SubscriptionSnapshot(status:.failed,message:"额度接口域名未获信任")
        }
        let (status,data)=http(url,headers,body,method)
        guard status == 200 else { return failure(status,data,privateAPI:privateAPI) }
        var result=parse(account.provider,data)
        result.privateAPI=privateAPI
        if result.status == .current { result.sampledAt=clock() }
        return result
    }
    private func failure(_ status:Int,_ data:[String:Any],privateAPI:Bool) -> SubscriptionSnapshot {
        let state:SubscriptionStatus = status == 401 ? .expired : status == 403 ? .forbidden : .failed
        let message = status == 401 ? "凭据失效，请打开来源工具重新登录" : status == 403 ? "账号没有读取配额的权限" : status == 429 ? "接口限流，稍后自动重试" : status == 0 ? "连接失败或超时" : "配额接口返回 HTTP \(status)"
        let retry=(data["_retry_after"] as? NSNumber)?.doubleValue
        return SubscriptionSnapshot(status:state,message:message,retryAt:retry.map { clock().addingTimeInterval(max(0,$0)) },privateAPI:privateAPI)
    }
    func parse(_ provider:String,_ data:[String:Any]) -> SubscriptionSnapshot {
        var windows:[SubscriptionWindow]=[]
        var plan=data["plan_type"] as? String ?? data["plan"] as? String ?? ""
        func append(_ id:String,_ label:String,_ pct:Any?,_ reset:Any?=nil,_ used:Any?=nil,_ limit:Any?=nil,_ unit:String?=nil) {
            guard let percent=BillingNet.pct(pct) else { return }
            windows.append(SubscriptionWindow(id:id,label:label,usedPercent:percent,used:subscriptionDecimal(used),limit:subscriptionDecimal(limit),unit:unit,resetsAt:subscriptionDate(reset)))
        }
        switch provider {
        case "claude":
            for (key,label) in [("five_hour","5 小时"),("seven_day","周（7 天）"),("seven_day_sonnet","Sonnet 周配额"),("seven_day_opus","Opus 周配额")] {
                if let w=data[key] as? [String:Any] { append(key,label,w["utilization"] ?? w["used_percentage"],w["resets_at"]) }
            }
        case "codex":
            let rate=data["rate_limit"] as? [String:Any] ?? [:]
            for key in ["primary_window","secondary_window"] {
                if let w=rate[key] as? [String:Any] {
                    let seconds=(w["limit_window_seconds"] as? NSNumber)?.intValue
                    let label=seconds == 18000 ? "5 小时" : seconds == 604800 ? "周（7 天）" : seconds.map { "\($0 / 60) 分钟" } ?? key
                    append(key,label,w["used_percent"],w["reset_at"])
                }
            }
        case "kimi":
            func window(_ id:String,_ label:String,_ w:[String:Any]) {
                let limit=BillingNet.pct(w["limit"])
                let remaining=BillingNet.pct(w["remaining"])
                let used=BillingNet.pct(w["used"]) ?? (limit.flatMap { l in remaining.map { l-$0 } })
                guard let limit,limit>0,let used else {return}
                append(id,label,used/limit*100,w["resetTime"],used,limit,"requests")
            }
            if let w=data["usage"] as? [String:Any] { window("cycle","周期配额",w) }
            for (i,l) in (data["limits"] as? [[String:Any]] ?? []).enumerated() {
                let w=l["window"] as? [String:Any] ?? [:]
                let duration=(w["duration"] as? NSNumber)?.intValue
                if let d=l["detail"] as? [String:Any] { window("limit-\(i)",duration == 300 ? "5 小时" : duration.map { "\($0) 分钟" } ?? "配额窗口",d) }
            }
            let user=data["user"] as? [String:Any] ?? [:]
            plan=(user["membership"] as? [String:Any])?["level"] as? String ?? ""
        case "go":
            if let usage=data["usage"] as? [String:Any] {
                for (key,label) in [("rolling","5 小时"),("weekly","周（7 天）"),("monthly","月度")] {
                    if let w=usage[key] as? [String:Any] { append(key,label,w["percent"],w["resetsAt"]) }
                }
            }
        case "copilot":
            plan=data["copilot_plan"] as? String ?? ""
            if let snapshots=data["quota_snapshots"] as? [String:Any] {
                for key in snapshots.keys.sorted() {
                    guard let w=snapshots[key] as? [String:Any] else {continue}
                    if (w["unlimited"] as? Bool) == true { continue }
                    if let remaining=BillingNet.pct(w["percent_remaining"]) {
                        append(key,key.replacingOccurrences(of:"_",with:" "),100-remaining,data["quota_reset_date"],nil,w["entitlement"],"requests")
                    }
                }
            }
        case "grok":
            let c=data["config"] as? [String:Any] ?? [:]
            append("allowance","订阅额度",c["creditUsagePercent"],c["billingPeriodEnd"])
        case "workbuddy", "workbuddy-ai":
            if let code=data["code"] as? NSNumber,code.intValue != 0 { return SubscriptionSnapshot(status:.forbidden,message:"服务拒绝读取额度，请打开来源工具检查登录") }
            let d=data["data"] as? [String:Any] ?? [:]
            let packages=d["Packages"] as? [[String:Any]] ?? []
            var total=Decimal(0),used=Decimal(0),valid=true
            for p in packages {
                guard let t=subscriptionDecimal(p["CycleTotalCapacity"]),let u=subscriptionDecimal(p["CycleUsedCapacity"]) else {valid=false;break}
                total+=t;used+=u
            }
            if valid,total>0 { append("credits","积分",NSDecimalNumber(decimal:used/total*100),nil,NSDecimalNumber(decimal:used),NSDecimalNumber(decimal:total),"credits") }
            plan=(d["IsPaidUser"] as? Bool) == true ? "Pro" : ""
        default:break
        }
        guard !windows.isEmpty else { return SubscriptionSnapshot(status:.failed,message:"接口没有返回可用额度窗口（可能尚未支持该套餐）") }
        return SubscriptionSnapshot(status:.current,windows:windows,plan:plan)
    }
}
