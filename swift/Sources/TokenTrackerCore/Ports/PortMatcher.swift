//
//  PortMatcher.swift
//  TokenTrackerCore
//
//  把占用端口的进程和开发项目对上：进程的工作目录落在某个项目目录里，就算这个项目的端口。
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

    public static func apply(_ ports: [ListeningPort], directories: [ProjectDirectory],
                             home: String = NSHomeDirectory()) -> [ListeningPort] {
        ports.map { port in
            var port = port
            let hit = match(cwd: port.cwd, directories: directories, home: home)
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
