//
//  ScanScheduler.swift
//  TokenTrackerCore
//
//  移植自 server.py 的 ScanService：一次只跑一个扫描，HTTP 动作与
//  桌面定时器共用锁。时钟/等待/线程可注入（测试隔离）；失败记录时间戳
//  并释放锁；stop 不取消进行中的事务，只阻止新扫描。
//

import Foundation

/// 可注入的线程抽象（测试用 InlineScanThread 同步执行）。
public protocol ScanThreadHandle {
    func start()
    func join(timeout: TimeInterval)
    var isAlive: Bool { get }
    var isCurrentThread: Bool { get }
}

public final class RealScanThread: ScanThreadHandle, @unchecked Sendable {
    /// 独立状态盒：避免 init 里 Thread(block:) 捕获未初始化完的 self。
    private final class State: @unchecked Sendable {
        var alive = true
        let lock = NSLock()
    }
    private let state = State()
    private let thread: Thread

    public init(_ block: @escaping @Sendable () -> Void) {
        let state = self.state
        thread = Thread(block: {
            block()
            state.lock.lock()
            state.alive = false
            state.lock.unlock()
        })
    }

    public func start() { thread.start() }

    public func join(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while isAlive && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    public var isAlive: Bool {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.alive && thread.isExecuting && !thread.isFinished
    }

    public var isCurrentThread: Bool { Thread.current == thread }
}

public struct ScanSchedulerStatus: Equatable, Sendable {
    public struct Last: Equatable, Sendable {
        public var startedAt: Double = 0
        public var finishedAt: Double = 0
        public var source: String = ""
        public var done = false
        public var error: String?
        public var added: Int = 0
        public var repriced: Int = 0
        public var counterResets: Int = 0
        public var warnings: [String] = []
    }
    public var running = false
    public var last: Last?

    public init(running: Bool = false, last: Last? = nil) {
        self.running = running
        self.last = last
    }
}

public final class ScanScheduler: @unchecked Sendable {
    public typealias ScanBlock = @Sendable (_ tools: [String]?, _ full: Bool) throws
        -> (results: [String: ScanOutcome], repriced: Int)
    public typealias ThreadFactory = (@Sendable @escaping () -> Void) -> ScanThreadHandle

    private let scan: ScanBlock
    private let interval: Double
    private let clock: () -> Double
    private let waitImpl: (Double) -> Bool   // true = 收到停止信号（对齐 Event.wait）
    private let threadFactory: ThreadFactory

    private let lock = NSLock()
    private final class StopFlag: @unchecked Sendable {
        var value = false
    }
    private let stopFlag = StopFlag()
    private var status = ScanSchedulerStatus()
    private var worker: ScanThreadHandle?
    private var timer: ScanThreadHandle?

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopFlag.value
    }

    /// 扫描完成回调（调用方负责切主线程）。
    public var onFinish: (() -> Void)?

    public init(scan: @escaping ScanBlock, interval: Double = 60,
                clock: (() -> Double)? = nil,
                wait: ((Double) -> Bool)? = nil,
                threadFactory: ThreadFactory? = nil) {
        self.scan = scan
        self.interval = interval
        let flag = stopFlag
        let lockRef = lock
        let stopCheck: @Sendable () -> Bool = {
            lockRef.lock()
            defer { lockRef.unlock() }
            return flag.value
        }
        self.clock = clock ?? { Date().timeIntervalSince1970 }
        self.waitImpl = wait ?? { timeout in
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if stopCheck() { return true }
                Thread.sleep(forTimeInterval: min(0.05, max(0, deadline.timeIntervalSinceNow)))
            }
            return stopCheck()
        }
        self.threadFactory = threadFactory ?? { RealScanThread($0) }
    }

    public func snapshot() -> ScanSchedulerStatus {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    /// 请求一次扫描；运行中/已停止返回 false。
    @discardableResult
    public func request(tools: [String]? = nil, full: Bool = false, source: String = "manual") -> Bool {
        lock.lock()
        if stopFlag.value || status.running {
            lock.unlock()
            return false
        }
        status.running = true
        status.last = ScanSchedulerStatus.Last(startedAt: clock(), source: source)
        let worker = threadFactory { [weak self] in self?.run(tools: tools, full: full) }
        self.worker = worker
        lock.unlock()
        worker.start()
        return true
    }

    private func run(tools: [String]?, full: Bool) {
        var scanError: String?
        var added = 0, repriced = 0, resets = 0, warnings: [String] = []
        do {
            let result = try scan(tools, full)
            repriced = result.repriced
            var errors: [String] = []
            for (name, outcome) in result.results {
                if let e = outcome.error { errors.append("\(name): \(e)") }
                if let w = outcome.warning { warnings.append(w) }
                added += outcome.added
                resets += outcome.counterResets
            }
            if !errors.isEmpty { scanError = errors.joined(separator: "; ") }
        } catch {
            // 失败的扫描不得污染共享锁
            scanError = String(describing: error)
        }
        lock.lock()
        status.last?.done = true
        status.last?.finishedAt = clock()
        status.last?.error = scanError
        status.last?.added = added
        status.last?.repriced = repriced
        status.last?.counterResets = resets
        status.last?.warnings = warnings
        status.running = false
        lock.unlock()
        onFinish?()
    }

    /// 启动自动调度：立即扫一次，此后每 interval 秒增量扫描。
    public func startAuto() {
        lock.lock()
        if stopFlag.value || timer != nil {
            lock.unlock()
            return
        }
        let timer = threadFactory { [weak self] in self?.autoLoop() }
        self.timer = timer
        lock.unlock()
        timer.start()
    }

    private func autoLoop() {
        request(source: "automatic")
        while !waitImpl(interval) {
            if isStopped { break }
            request(source: "automatic")
        }
    }

    /// 停止调度：不取消进行中的 SQLite 事务；阻止新扫描并有界等待。
    public func stop() {
        lock.lock()
        stopFlag.value = true
        let worker = self.worker
        let timer = self.timer
        lock.unlock()
        for thread in [worker, timer] {
            if let thread, !thread.isCurrentThread { thread.join(timeout: 2) }
        }
    }
}
