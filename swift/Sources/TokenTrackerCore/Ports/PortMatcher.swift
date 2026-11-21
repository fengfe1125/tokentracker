//
//  PortMatcher.swift
//  TokenTrackerCore
//
//  把占用端口的进程和开发项目对上：先看进程工作目录，再回退到父进程工作目录
//  以及命令行里的项目路径参数；根目录和用户主目录不参与匹配。
//

import Foundation

/// 用量库里记录过的项目目录。
public struct ProjectDirectory: Sendable, Equatable {
    public var path: String
    public var projectID: String
    public var name: String

    public init(path: String, projectID: String, name: String) {
        self.path = path; self.projectID = projectID; self.name = name
    }
}

public enum PortMatcher {
    /// 最长前缀匹配。根目录和用户主目录本身不参与，否则会把几乎所有进程都归进去。
    public static func match(cwd: String?, directories: [ProjectDirectory],
                             home: String = NSHomeDirectory()) -> ProjectDirectory? {
        guard let cwd, cwd.hasPrefix("/") else { return nil }
        var best: ProjectDirectory?
        for directory in directories {
            let path = directory.path
            guard path.count > 1, path != home else { continue }
            guard cwd == path || cwd.hasPrefix(path.hasSuffix("/") ? path : path + "/") else { continue }
            if best == nil || path.count > best!.path.count { best = directory }
        }
        return best
    }

    /// 从命令行参数里提取可能的绝对路径片段（如 `node /Users/a/web/node_modules/.bin/vite` 或 `--root=/Users/a/web`）。
    static func matchCommandLine(_ commandLine: String?, directories: [ProjectDirectory],
                                 home: String = NSHomeDirectory()) -> ProjectDirectory? {
        guard let commandLine, !commandLine.isEmpty else { return nil }
        var best: ProjectDirectory?
        for rawToken in commandLine.split(whereSeparator: \.isWhitespace) {
            var token = String(rawToken).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if let eq = token.firstIndex(of: "="), token[token.index(after: eq)...].hasPrefix("/") {
                token = String(token[token.index(after: eq)...])
            }
            guard token.hasPrefix("/") else { continue }
            if let hit = match(cwd: token, directories: directories, home: home) {
                if best == nil || hit.path.count > best!.path.count { best = hit }
            }
        }
        return best
    }

    /// 依次按 cwd -> parentCwd -> commandLine 匹配项目。
    public static func match(port: ListeningPort, directories: [ProjectDirectory],
                             home: String = NSHomeDirectory()) -> ProjectDirectory? {
        if let hit = match(cwd: port.cwd, directories: directories, home: home) { return hit }
        if let hit = match(cwd: port.parentCwd, directories: directories, home: home) { return hit }
        return matchCommandLine(port.commandLine, directories: directories, home: home)
    }

    public static func apply(_ ports: [ListeningPort], directories: [ProjectDirectory],
                             home: String = NSHomeDirectory()) -> [ListeningPort] {
        ports.map { port in
            var port = port
            let hit = match(port: port, directories: directories, home: home)
            port.projectID = hit?.projectID
            port.projectName = hit?.name
            return port
        }
    }

    /// 项目的根目录：Git 项目取仓库根，目录项目取目录本身，其余取记录过的最短目录。
    public static func root(projectID: String, directories: [ProjectDirectory]) -> String? {
        if projectID.hasPrefix("git:") {
            let common = String(projectID.dropFirst(4))
            if common.hasSuffix("/.git") { return String(common.dropLast(5)) }
        }
        if projectID.hasPrefix("directory:") { return String(projectID.dropFirst(10)) }
        return directories.filter { $0.projectID == projectID }
            .map(\.path).min { $0.count < $1.count }
    }
}

extension UsageStore {
    /// 记录过的项目目录，外加 Git 项目的仓库根（会话可能只在子目录里跑过）。
    public func projectDirectories() throws -> [ProjectDirectory] {
        let rows = try conn.query("""
            SELECT pp.path path, COALESCE(pp.manual_id,pp.automatic_id) id, COALESCE(p.name,'') name
            FROM project_paths pp LEFT JOIN projects p ON p.id=COALESCE(pp.manual_id,pp.automatic_id)
            """)
        var result = rows.map {
            ProjectDirectory(path: $0.string("path"), projectID: $0.string("id"), name: $0.string("name"))
        }
        var known = Set(result.map(\.path))
        for directory in result where directory.projectID.hasPrefix("git:") {
            let common = String(directory.projectID.dropFirst(4))
            guard common.hasSuffix("/.git") else { continue }
            let root = String(common.dropLast(5))
            if known.insert(root).inserted {
                result.append(ProjectDirectory(path: root, projectID: directory.projectID, name: directory.name))
            }
        }
        return result
    }
}
