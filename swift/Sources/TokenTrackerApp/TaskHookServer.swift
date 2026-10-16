import Foundation
import Darwin
import TokenTrackerCore

final class TaskHookServer: @unchecked Sendable {
    private struct Pending { let event: TaskHookEvent; let fd: Int32; let monitor: DispatchSourceRead }
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var pending: [String: Pending] = [:]
    private let queue = DispatchQueue(label: "tt.task.socket", attributes: .concurrent)
    let path: String
    private let approvalTimeout: TimeInterval
    var onEvent: (@Sendable (TaskHookEvent) -> Void)?
    var onExpire: (@Sendable (String) -> Void)?
    init(channel: String, path: String? = nil, approvalTimeout: TimeInterval = 120) {
        self.path = path ?? TaskSocket.path(channel: channel); self.approvalTimeout = approvalTimeout
    }

    func start() throws {
        let fd = try TaskSocket.listen(path: path)
        lock.lock(); listener = fd; lock.unlock()
        queue.async { [weak self] in
            defer { Darwin.close(fd) }
            while let self {
                self.lock.lock(); let active = self.listener == fd; self.lock.unlock()
                guard active else { return }
                do { try TaskSocket.ready(fd, event: Int16(POLLIN), deadline: Date().addingTimeInterval(1)) }
                catch { continue }
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
                TaskSocket.configure(client)
                guard TaskSocket.sameUser(client) else { Darwin.close(client); continue }
                self.lock.lock(); let capacity = self.pending.count < 32; self.lock.unlock()
                guard capacity else { Darwin.close(client); continue }
                self.queue.async { [weak self] in self?.receive(client) }
            }
        }
    }
    private func receive(_ fd: Int32) {
        do {
            let data = try TaskSocket.receive(fd, deadline: Date().addingTimeInterval(2))
            let event = try JSONDecoder().decode(TaskHookEvent.self, from: data)
            guard event.version == 1, UUID(uuidString: event.id) != nil,
                  !event.session.isEmpty, abs(event.at.timeIntervalSinceNow) < 10 else { throw TaskBridgeError.invalidMessage }
            if !event.requiresReply {
                let reply = try JSONEncoder().encode(TaskHookReply(id: event.id, decision: .pass))
                try TaskSocket.send(reply, fd: fd, deadline: Date().addingTimeInterval(1))
                Darwin.close(fd); onEvent?(event); return
            }
            let id = event.id
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.expire(id) }
            source.setCancelHandler { Darwin.close(fd) }
            lock.lock()
            guard listener >= 0, pending[event.id] == nil, pending.count < 32 else {
                lock.unlock(); source.resume(); source.cancel(); return
            }
            pending[event.id] = Pending(event: event, fd: fd, monitor: source)
            lock.unlock()
            source.resume()
            queue.asyncAfter(deadline: .now() + approvalTimeout) { [weak self] in self?.expire(id) }
            onEvent?(event)
        } catch { Darwin.close(fd) }
    }
    @discardableResult func resolve(_ id: String, decision: TaskHookDecision) -> Bool {
        lock.lock()
        guard let client = pending.removeValue(forKey: id) else { lock.unlock(); return false }
        lock.unlock()
        defer { client.monitor.cancel() }
        // Expired requests can only return control to the original tool.
        let valid = client.event.at.addingTimeInterval(approvalTimeout) > Date()
        let effective: TaskHookDecision = valid ? decision : .pass
        do {
            let reply = try JSONEncoder().encode(TaskHookReply(id: id, decision: effective))
            try TaskSocket.send(reply, fd: client.fd, deadline: Date().addingTimeInterval(1))
            return valid
        } catch { return false }
    }
    func isPending(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return pending[id] != nil
    }
    private func expire(_ id: String) {
        lock.lock(); let exists = pending[id] != nil; lock.unlock()
        guard exists else { return }
        _ = resolve(id, decision: .pass)
        onExpire?(id)
    }
    func cancel(session: String, provider: TaskProvider, agent: String, except: String? = nil) {
        lock.lock()
        let ids = pending.values.filter { $0.event.provider == provider && $0.event.session == session
            && $0.event.agent == agent && $0.event.id != except }.map { $0.event.id }
        lock.unlock()
        for id in ids { expire(id) }
    }
    func stop() {
        lock.lock(); let fd = listener; listener = -1; let ids = Array(pending.keys); lock.unlock()
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
        for id in ids { expire(id) }
        // Keep the filesystem entry until the next bind; removing it here could
        // unlink a replacement server during shutdown/startup races.
    }
}
