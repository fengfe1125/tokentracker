import Foundation
import TokenTrackerCore

/// 设置页登录弹窗的状态。cancelled 跨线程共享，供后台轮询检查。
struct SubscriptionLoginState: Identifiable {
    enum Phase: Equatable { case starting, waiting, finishing, failed }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    let id = UUID()
    let provider: SubscriptionProvider
    var flow: SubscriptionLoginFlow?
    var phase: Phase = .starting
    var error: SubscriptionAuthError?
    let cancelled = Flag()
}

extension SubscriptionLoginFlow.Prompt {
    var url: URL? {
        switch self {
        case .deviceCode(_, let url), .pasteCode(let url), .browser(let url): return url
        }
    }
}
