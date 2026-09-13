import Foundation

/// These errors intentionally contain neither credential data nor filesystem paths.
public enum AccountPersistenceError: Error, Equatable, CustomStringConvertible {
    case corrupt, encode, create, permissions, replace, verify, historyAfterSwitch
    public var description: String {
        switch self {
        case .corrupt: return "账号快照损坏或格式不受支持；原文件已保留"
        case .encode: return "账号数据无法编码"
        case .create: return "无法保存账号文件，请检查权限和磁盘空间"
        case .permissions: return "无法设置账号文件权限"
        case .replace: return "无法替换账号文件，原登录已保留"
        case .verify: return "账号文件回读校验失败，请检查当前登录状态"
        case .historyAfterSwitch: return "切换已完成，但记录保存失败"
        }
    }
}

public enum AccountWriteStage: Sendable { case encode, create, permissions, replace, verify }

public func writeAccountJSON(_ path: String, _ object: [String: Any], permissions: Int = 0o600, beforeStep: ((AccountWriteStage) throws -> Void)? = nil) throws {
    try beforeStep?(.encode)
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
        throw AccountPersistenceError.encode
    }
    let directory = (path as NSString).deletingLastPathComponent
    do { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true) }
    catch { throw AccountPersistenceError.create }
    let temporary = directory + "/.account-" + UUID().uuidString
    try beforeStep?(.create)
    let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL, mode_t(permissions))
    guard fd >= 0 else { throw AccountPersistenceError.create }
    defer { close(fd); try? FileManager.default.removeItem(atPath: temporary) }
    try beforeStep?(.permissions)
    guard fchmod(fd, mode_t(permissions)) == 0 else { throw AccountPersistenceError.permissions }
    let written = data.withUnsafeBytes { bytes -> Bool in
        var offset = 0
        while offset < bytes.count {
            let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { return false }
            offset += count
        }
        return true
    }
    guard written, fsync(fd) == 0 else { throw AccountPersistenceError.create }
    try beforeStep?(.replace)
    guard rename(temporary, path) == 0 else { throw AccountPersistenceError.replace }
    try beforeStep?(.verify)
    guard let actual = FileManager.default.contents(atPath: path), actual == data else {
        throw AccountPersistenceError.verify
    }
}
