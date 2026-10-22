import Foundation
import Darwin

/// Same-user, framed local transport. No raw payloads or errors are logged.
public enum TaskSocket {
    public static let maximumFrame = 1_048_576
    /// How long a PermissionRequest waits for a card decision before abstaining.
    public static let approvalTimeout: TimeInterval = 120
    /// Upstream hook timeout; longer than approvalTimeout so the helper always abstains first.
    public static let hookTimeout = Int(approvalTimeout) + 10
    public static func directory(channel: String) -> String {
        // Per-user private temp root (/var/folders/…/T). It is the same for the App and
        // every hook process regardless of TMPDIR, and unlike /tmp other users cannot
        // pre-create it or have it swept away by periodic /tmp cleanup.
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        var base = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 ? String(cString: buffer) : "/tmp"
        if !base.hasSuffix("/") { base += "/" }
        return base + "tt-tasks-\(getuid())-" + (channel == "development" ? "dev" : "app")
    }
    public static func path(channel: String) -> String { directory(channel: channel) + "/events.sock" }

    public static func prepareDirectory(_ path: String) throws {
        if mkdir(path, 0o700) != 0 && errno != EEXIST { throw TaskBridgeError.unsafePath }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else { throw TaskBridgeError.unsafePath }
    }
    private static func address<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw TaskBridgeError.unsafePath }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in buffer.copyBytes(from: bytes) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return try withUnsafePointer(to: &addr) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
    public static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
    }
    public static func sameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0; var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }
    public static func connect(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TaskBridgeError.unavailable }
        configure(fd)
        do {
            let result = try address(path) { Darwin.connect(fd, $0, $1) }
            if result != 0 {
                guard errno == EINPROGRESS else { throw TaskBridgeError.unavailable }
                try ready(fd, event: Int16(POLLOUT), deadline: Date().addingTimeInterval(0.2))
                var error: Int32 = 0; var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { throw TaskBridgeError.unavailable }
            }
            guard sameUser(fd) else { throw TaskBridgeError.unavailable }
            return fd
        } catch { Darwin.close(fd); throw error }
    }
    public static func listen(path: String) throws -> Int32 {
        try prepareDirectory((path as NSString).deletingLastPathComponent)
        // Never remove a socket owned by another live App.
        if let existing = try? connect(path: path) { Darwin.close(existing); throw TaskBridgeError.unavailable }
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK else { throw TaskBridgeError.unsafePath }
            guard unlink(path) == 0 else { throw TaskBridgeError.unavailable }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TaskBridgeError.unavailable }
        configure(fd)
        do {
            guard try address(path, { bind(fd, $0, $1) }) == 0,
                  chmod(path, 0o600) == 0, Darwin.listen(fd, 32) == 0 else { throw TaskBridgeError.unavailable }
            return fd
        } catch { Darwin.close(fd); throw error }
    }
    public static func ready(_ fd: Int32, event: Int16, deadline: Date) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw TaskBridgeError.timeout }
            var descriptor = pollfd(fd: fd, events: event, revents: 0)
            let result = poll(&descriptor, 1, Int32(min(remaining * 1000 + 1, 1000)))
            if result < 0 { if errno == EINTR { continue }; throw TaskBridgeError.disconnected }
            if descriptor.revents & event != 0 { return }
            if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { throw TaskBridgeError.disconnected }
        }
    }
    private static func read(_ count: Int, fd: Int32, deadline: Date) throws -> Data {
        var data = Data(count: count); var offset = 0
        while offset < count {
            try ready(fd, event: Int16(POLLIN), deadline: deadline)
            let n = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), count - offset) }
            if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard n > 0 else { throw TaskBridgeError.disconnected }; offset += n
        }
        return data
    }
    public static func receive(_ fd: Int32, deadline: Date) throws -> Data {
        let header = try read(4, fd: fd, deadline: deadline)
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= maximumFrame else { throw TaskBridgeError.invalidMessage }
        return try read(count, fd: fd, deadline: deadline)
    }
    public static func send(_ data: Data, fd: Int32, deadline: Date) throws {
        guard !data.isEmpty, data.count <= maximumFrame else { throw TaskBridgeError.invalidMessage }
        var length = UInt32(data.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }; frame.append(data)
        var offset = 0
        while offset < frame.count {
            try ready(fd, event: Int16(POLLOUT), deadline: deadline)
            let n = frame.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), frame.count - offset) }
            if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard n > 0 else { throw TaskBridgeError.disconnected }; offset += n
        }
    }
}
