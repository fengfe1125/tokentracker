//
//  SubscriptionHTTP.swift
//  TokenTrackerCore
//
//  订阅查询专用 HTTP：单请求 15 秒超时；不跟随重定向（配置无法把
//  Authorization 带到别的域名）；无 Cookie、无 URL 缓存；只放行适配器
//  为该供应商登记的 https 域名。
//

import Foundation

public struct SubscriptionRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?

    public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public struct SubscriptionResponse: @unchecked Sendable {
    public enum Failure: Sendable { case timeout, network, blocked }
    public var status: Int
    public var json: [String: Any]
    public var retryAfter: TimeInterval?
    public var failure: Failure?

    public init(status: Int, json: [String: Any] = [:], retryAfter: TimeInterval? = nil, failure: Failure? = nil) {
        self.status = status
        self.json = json
        self.retryAfter = retryAfter
        self.failure = failure
    }
}

public typealias SubscriptionTransport = @Sendable (SubscriptionRequest) -> SubscriptionResponse

public enum SubscriptionHTTP {
    static let timeout: TimeInterval = 15

    /// 认证请求只能发往 https、默认端口、无用户信息、且在白名单内的主机。
    static func permits(_ url: URL, hosts: Set<String>) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        return hosts.contains(host)
    }

    private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var value = SubscriptionResponse(status: 0, failure: .network)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
    }()

    /// 默认传输：同步等待（只在后台队列调用）。
    public static let live: SubscriptionTransport = { request in
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = timeout
        for (key, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box()
        let task = session.dataTask(with: urlRequest) { data, response, error in
            var value = SubscriptionResponse(status: 0, failure: .network)
            if let http = response as? HTTPURLResponse {
                let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
                value = SubscriptionResponse(status: http.statusCode, json: object,
                                             retryAfter: retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
            } else if let error = error as? URLError, error.code == .timedOut {
                value = SubscriptionResponse(status: 0, failure: .timeout)
            }
            box.lock.lock(); box.value = value; box.lock.unlock()
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout + 1) == .timedOut {
            task.cancel()
            return SubscriptionResponse(status: 0, failure: .timeout)
        }
        box.lock.lock(); defer { box.lock.unlock() }
        return box.value
    }

    /// Retry-After：秒数或 HTTP-date。
    static func retryAfter(_ header: String?, now: Date = Date()) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
        if let seconds = Double(header), seconds.isFinite { return max(0, seconds) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: header).map { max(0, $0.timeIntervalSince(now)) }
    }
}
