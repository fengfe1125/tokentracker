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
    /// Identifies the client from the nearest engine process. Only signals that the
    /// engine itself establishes count: its executable location, the subcommand it
    /// runs, Claude's own entrypoint variable and the hosting App. Anything ambiguous
    /// stays unknown; the result only labels reminders and never gates approvals.
    public static func identify(provider: TaskProvider, enginePath: String?, arguments: [String],
                                entrypoint: String?, host: String?, configurationRoot: String?,
                                home: String) -> Self {
        guard let enginePath else { return Self() }
        let binary = URL(fileURLWithPath: enginePath).lastPathComponent
        var client: TaskClient = .unknown
        var version: String?
        if provider == .claude, binary == "claude" {
            let desktopPrefix = home + "/Library/Application Support/Claude/claude-code/"
            if enginePath.hasPrefix(desktopPrefix) {
                if entrypoint == "claude-desktop", host == "com.anthropic.claudefordesktop" {
                    client = .claudeDesktop
                    version = String(enginePath.dropFirst(desktopPrefix.count).prefix(while: { $0 != "/" }))
                }
            } else if entrypoint == nil || entrypoint == "cli" {
                // A CLI started from a desktop shell inherits CLAUDE_CODE_ENTRYPOINT=claude-desktop
                // but runs the user's own engine; that combination stays unknown.
                client = .claudeCLI
            }
        } else if provider == .codex, binary == "codex" {
            let servers: Set = ["app-server", "app-server-daemon", "exec-server", "mcp-server"]
            let subcommands = servers.union(["exec", "e", "resume", "fork", "review", "login", "logout", "mcp",
                                             "debug", "sandbox", "apply", "cloud", "completion"])
            let command = arguments.dropFirst().first(where: subcommands.contains)
            if command == "app-server" {
                // A daemon without the desktop host and bundled engine stays unknown.
                if host == "com.openai.codex", enginePath.contains("/Contents/Resources/codex-cli/") {
                    client = .codexDesktop
                }
            } else if !servers.contains(command ?? "") {
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
