import Foundation

public enum TaskClient: String, Codable, CaseIterable, Sendable {
    case codexCLI, codexDesktop, claudeCLI, claudeDesktop, unknown

    public var provider: TaskProvider? {
        switch self {
        case .codexCLI, .codexDesktop: .codex
        case .claudeCLI, .claudeDesktop: .claude
        case .unknown: nil
        }
    }
    public var name: String {
        switch self {
        case .codexCLI: "Codex CLI"
        case .codexDesktop: "Codex 桌面"
        case .claudeCLI: "Claude Code CLI"
        case .claudeDesktop: "Claude 桌面 Code"
        case .unknown: "来源未确认"
        }
    }
}

public enum TaskExecutionLocation: String, Codable, Sendable { case local, unknown }
public enum TaskSourceConfidence: String, Codable, Sendable { case launchContext, unknown }

/// Only launch metadata is retained. Raw argv, environment, prompts and credentials
/// must never enter the bridge or reminder history.
public struct TaskClientSource: Codable, Sendable, Equatable {
    public var client: TaskClient
    public var location: TaskExecutionLocation
    public var confidence: TaskSourceConfidence
    public var configurationRoot: String?
    public var engineVersion: String?

    public init(client: TaskClient = .unknown, location: TaskExecutionLocation = .unknown,
                confidence: TaskSourceConfidence = .unknown, configurationRoot: String? = nil,
                engineVersion: String? = nil) {
        self.client = client; self.location = location; self.confidence = confidence
        self.configurationRoot = configurationRoot; self.engineVersion = engineVersion
    }
    public static func launchMode(provider: TaskProvider, arguments: [String]) -> String? {
        guard !arguments.isEmpty else { return nil }
        func has(_ option: String) -> Bool {
            arguments.contains { $0 == option || $0.hasPrefix(option + "=") }
        }
        if provider == .codex {
            // Desktop puts global configuration overrides before app-server.
            // Skip only known options so an option value cannot masquerade as
            // a subcommand or silently establish desktop provenance.
            let values = ["-c", "--config", "--enable", "--disable", "-C", "--cd",
                          "-m", "--model", "-p", "--profile", "-s", "--sandbox",
                          "-a", "--ask-for-approval", "--add-dir"]
            let switches = ["--no-alt-screen", "--search", "--full-auto"]
            var index = 1
            while index < arguments.count, arguments[index].hasPrefix("-") {
                let option = arguments[index]
                if values.contains(option) {
                    guard index + 1 < arguments.count else { return nil }
                    index += 2
                } else if values.contains(where: { option.hasPrefix($0 + "=") }) || switches.contains(option) {
                    index += 1
                } else { return nil }
            }
            let command = index < arguments.count ? arguments[index] : nil
            if command == "app-server" { return "app-server" }
            if command == "exec" { return "exec" }
            if ["app-server-daemon", "mcp-server", "debug", "login", "logout"].contains(command ?? "")
                || has("--version") { return nil }
            guard command == nil else { return nil }
            return "interactive"
        }
        if has("--permission-prompt-tool") && has("--input-format") && has("--output-format") {
            return "desktop-stream"
        }
        return has("--print") || has("-p") ? nil : "interactive"
    }
    public static func identify(provider: TaskProvider, enginePath: String?, mode: String?,
                                entrypoint: String?, host: String?, configurationRoot: String?,
                                home: String) -> Self {
        guard let enginePath else { return Self() }
        let binary = URL(fileURLWithPath: enginePath).lastPathComponent
        var client: TaskClient = .unknown
        var version: String?
        if provider == .claude, binary == "claude" {
            let desktopPrefix = home + "/Library/Application Support/Claude/claude-code/"
            if entrypoint == "claude-desktop", host == "com.anthropic.claudefordesktop",
               enginePath.hasPrefix(desktopPrefix), mode == "desktop-stream" {
                client = .claudeDesktop
                version = String(enginePath.dropFirst(desktopPrefix.count).prefix(while: { $0 != "/" }))
            } else if entrypoint != "claude-desktop", mode == "interactive" {
                client = .claudeCLI
            }
        } else if provider == .codex, binary == "codex" {
            // A CLI launched by a desktop tool runner remains a CLI. A daemon
            // without independently established desktop provenance stays unknown.
            if mode == "app-server", host == "com.openai.codex",
               enginePath.contains("/Contents/Resources/codex-cli/") {
                client = .codexDesktop
            } else if mode == "interactive" || mode == "exec" {
                client = .codexCLI
            }
        }
        return Self(client: client, location: .local,
                    confidence: client == .unknown ? .unknown : .launchContext,
                    configurationRoot: configurationRoot, engineVersion: version)
    }
}

/// User-approved roots are separate from candidates and observed runtime roots.
/// A shell override belonging to TokenTracker is never used for a desktop target.
public struct TaskHookConfigurationRoot: Equatable, Sendable {
    public let path: String
    public let confirmed: Bool
    public static func resolve(client: TaskClient, home: String, environment: [String: String],
                               selected: String? = nil, observed: String? = nil,
                               exists: (String) -> Bool) -> Self? {
        guard let provider = client.provider else { return nil }
        let candidate: String
        if let selected, selected.hasPrefix("/") {
            return Self(path: URL(fileURLWithPath: selected).standardizedFileURL.path, confirmed: true)
        } else if let observed, observed.hasPrefix("/") {
            return Self(path: URL(fileURLWithPath: observed).standardizedFileURL.path, confirmed: true)
        } else {
            let isCLI = client == .codexCLI || client == .claudeCLI
            let key = provider == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"
            candidate = (isCLI ? environment[key] : nil) ?? home + (provider == .codex ? "/.codex" : "/.claude")
        }
        guard candidate.hasPrefix("/"), exists(candidate) else { return nil }
        return Self(path: URL(fileURLWithPath: candidate).standardizedFileURL.path, confirmed: false)
    }
    public func configurationPath(provider: TaskProvider) -> String {
        path + (provider == .codex ? "/hooks.json" : "/settings.json")
    }
}
