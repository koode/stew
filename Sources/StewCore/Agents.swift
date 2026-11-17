import Foundation

/// The coding agent a request comes from. A request without one comes from Claude Code:
/// that was the only agent stew knew, so older callers and stored requests mean it.
public enum CodingAgent: String, Codable, CaseIterable, Sendable {
    case claudeCode = "claude"
    case codex

    /// The product, as settings, setup and help name it.
    public var productName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// The agent inside a sentence: "Claude wants to", "Note for Codex".
    public var name: String {
        switch self {
        case .claudeCode: "Claude"
        case .codex: "Codex"
        }
    }

    /// What happens when stew's time runs out on a request the agent asks again in its
    /// own prompt, such as a Codex approval: the agent is told nothing.
    public var asksInItsOwnPrompt: String { "\(name) asks in its own prompt instead." }

    /// The agent whose shell a command runs in, from the variables each agent sets for
    /// its commands. Nil outside both. Claude Code wins when both are set, because its
    /// variables reach only commands it starts itself.
    public static func detect(environment: [String: String]) -> CodingAgent? {
        if environment["CLAUDECODE"] == "1" || nonEmpty(environment["CLAUDE_CODE_SESSION_ID"]) != nil { return .claudeCode }
        if codexSessionID(environment: environment) != nil { return .codex }
        return nil
    }

    /// The id of the Codex session a shell command runs in. Codex gives its commands
    /// CODEX_SESSION_ID, the root session that hooks see as `session_id`, and
    /// CODEX_THREAD_ID, the thread itself, which differs only in a subagent.
    public static func codexSessionID(environment: [String: String]) -> String? {
        nonEmpty(environment["CODEX_SESSION_ID"]) ?? nonEmpty(environment["CODEX_THREAD_ID"])
    }

    /// `--agent` values on the command line.
    public static func parse(_ text: String) -> CodingAgent? {
        switch text.lowercased() {
        case "claude", "claude-code", "claudecode": .claudeCode
        case "codex": .codex
        default: nil
        }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
