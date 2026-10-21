import Foundation

/// Subscription requests never follow redirects: a config cannot move an
/// Authorization header to another origin. No cookie store or URL cache.
public enum SubscriptionHTTP {
    public static let hosts: Set<String> = ["api.deepseek.com", "api.anthropic.com", "chatgpt.com",
        "api.kimi.com", "api.kimi.ai", "api.kimi.com", "opencode.ai", "api.github.com",
        "cli-chat-proxy.grok.com", "copilot.tencent.com", "www.workbuddy.ai"]
    public static func permits(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
            && hosts.contains(url.host?.lowercased() ?? "")
    }
    private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    private final class ResponseBox: @unchecked Sendable {
        let lock = NSLock()
        var value: (Int, [String:Any]) = (0, [:])
    }
    public static func call(_ url: String, _ headers: [String:String], _ body: Data?, _ method: String) -> (Int, [String:Any]) {
        guard let endpoint = URL(string:url), permits(endpoint) else { return (0, ["error":"untrusted_endpoint"]) }
        var request = URLRequest(url:endpoint)
        request.timeoutInterval = 15
        request.httpMethod = method; request.httpBody = body
        for (key,value) in headers { request.setValue(value,forHTTPHeaderField:key) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration:configuration,delegate:RedirectBlocker(),delegateQueue:nil)
        let semaphore = DispatchSemaphore(value:0), box = ResponseBox()
        let task = session.dataTask(with:request) { data,response,error in
            var value: (Int,[String:Any]) = (0,[:])
            if let response = response as? HTTPURLResponse {
                var object = data.flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] } ?? [:]
                if let header = response.value(forHTTPHeaderField:"Retry-After") {
                    if let seconds = Double(header), seconds.isFinite { object["_retry_after"] = max(0,seconds) }
                    else {
                        let f=DateFormatter(); f.locale=Locale(identifier:"en_US_POSIX"); f.timeZone=TimeZone(secondsFromGMT:0)
                        f.dateFormat="EEE, dd MMM yyyy HH:mm:ss zzz"
                        if let date=f.date(from:header) { object["_retry_after"] = max(0,date.timeIntervalSinceNow) }
                    }
                }
                value=(response.statusCode,object)
            } else if error != nil { value=(0,["error":"network_or_timeout"]) }
            box.lock.lock(); box.value=value; box.lock.unlock(); semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout:.now()+16) == .timedOut { task.cancel() }
        session.invalidateAndCancel()
        box.lock.lock(); defer { box.lock.unlock() }
        return box.value
    }
}
