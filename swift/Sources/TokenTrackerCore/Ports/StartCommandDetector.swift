//
//  StartCommandDetector.swift
//  TokenTrackerCore
//
//  从项目目录里的常见文件猜启动命令。猜不出来就返回 nil，由界面让用户手填。
//  只读文件名和 package.json / Makefile 的内容，不执行任何东西。
//

import Foundation

public struct StartCommand: Sendable, Equatable {
    public var command: String
    /// 依据的文件名，如 package.json
    public var file: String
    /// 脚本或目标名，如 dev；没有时为 nil
    public var target: String?

    public init(command: String, file: String, target: String? = nil) {
        self.command = command; self.file = file; self.target = target
    }
}

public enum StartCommandDetector {
    static let scriptNames = ["dev", "start", "serve"]

    public static func detect(directory: String, fileManager: FileManager = .default) -> StartCommand? {
        func exists(_ name: String) -> Bool { fileManager.fileExists(atPath: directory + "/" + name) }
        func contents(_ name: String) -> Data? { fileManager.contents(atPath: directory + "/" + name) }

        if let data = contents("package.json"),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let scripts = object["scripts"] as? [String: Any],
           let script = scriptNames.first(where: { (scripts[$0] as? String)?.isEmpty == false }) {
            let command: String
            if exists("pnpm-lock.yaml") { command = "pnpm \(script)" }
            else if exists("yarn.lock") { command = "yarn \(script)" }
            else if exists("bun.lockb") || exists("bun.lock") { command = "bun run \(script)" }
            else { command = script == "start" ? "npm start" : "npm run \(script)" }
            return StartCommand(command: command, file: "package.json", target: script)
        }
        for name in ["Makefile", "makefile"] {
            guard let data = contents(name) else { continue }
            let text = String(decoding: data.prefix(256 * 1024), as: UTF8.self)
            for target in ["dev", "run", "serve", "start"] {
                let hit = text.split(whereSeparator: \.isNewline).contains { line in
                    line.hasPrefix(target + ":") && !line.hasPrefix(target + ":=")
                }
                if hit { return StartCommand(command: "make \(target)", file: name, target: target) }
            }
        }
        if exists("manage.py") {
            return StartCommand(command: "python3 manage.py runserver", file: "manage.py")
        }
        if exists("Cargo.toml") { return StartCommand(command: "cargo run", file: "Cargo.toml") }
        if exists("go.mod") { return StartCommand(command: "go run .", file: "go.mod") }
        if exists("Package.swift") { return StartCommand(command: "swift run", file: "Package.swift") }
        return nil
    }
}
