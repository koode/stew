import Foundation

/// Builds the input for the auto mode style risk check and reads its result.
/// The check runs `claude -p` with the user's effective auto mode rules as policy.
public enum RiskCheck {
    public static let schema = """
    {"type":"object","properties":{"verdict":{"type":"string","enum":["allow","soft_deny","hard_deny"]},"risk":{"type":"string","enum":["low","medium","high"]},"rule":{"type":["string","null"]},"summary":{"type":"string"}},"required":["verdict","risk","rule","summary"],"additionalProperties":false}
    """

    public static func systemPrompt(policyJSON: String) -> String {
        """
        You review actions that an AI coding agent wants to run. The agent asks its user for permission first, and your verdict is shown to the user as a warning above the command. Judge the proposed action against the auto mode policy below, the way the auto mode classifier would:

        - A hard_deny rule always blocks.
        - A soft_deny rule blocks unless the user's own recent messages clearly ask for this action. The agent's stated reason is not user consent.
        - An allow rule is an exception that lets an action through.
        - Use the environment section to decide what is trusted (repos, domains, buckets).

        Judge only the given action, with the given working directory and the user's recent messages as context. Your own working directory and session are not the agent's: ignore them. Set "rule" to the name of the deciding rule (the text before its colon), or null when no rule applies. Write "summary" for the user in at most two short sentences, 40 words maximum: say what the command does that matters, and to which target. No advice to the agent.

        POLICY (JSON):
        \(policyJSON)
        """
    }

    public struct Input: Codable, Equatable, Sendable {
        public var action: String
        public var command: String?
        public var reason: String
        public var cwd: String?
        public var recentUserMessages: [String]

        enum CodingKeys: String, CodingKey {
            case action, command, reason, cwd
            case recentUserMessages = "recent_user_messages"
        }
    }

    public static func input(for permission: PermissionRequest, session: SessionInfo, recentUserMessages: [String]) throws -> String {
        let input = Input(
            action: permission.action,
            command: permission.command,
            reason: permission.reason,
            cwd: session.cwd,
            recentUserMessages: recentUserMessages
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(input), as: UTF8.self)
    }

    public struct CheckError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// Reads `claude -p --output-format json` output: the verdict sits in `structured_output`.
    public static func parse(cliOutput: Data) throws -> RiskAssessment {
        guard let object = try? JSONSerialization.jsonObject(with: cliOutput) as? [String: Any] else {
            let text = String(decoding: cliOutput.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CheckError(description: text.isEmpty ? "no output from claude" : text)
        }
        if object["is_error"] as? Bool == true {
            throw CheckError(description: (object["result"] as? String) ?? "claude reported an error")
        }
        guard let structured = object["structured_output"] else {
            throw CheckError(description: "claude returned no structured output")
        }
        let data = try JSONSerialization.data(withJSONObject: structured)
        do {
            return try JSONDecoder().decode(RiskAssessment.self, from: data)
        } catch {
            throw CheckError(description: "unexpected verdict shape")
        }
    }

    /// The user's last messages in a Claude Code transcript (JSONL), oldest first.
    /// Skips tool results, meta lines, slash command wrappers and system reminders.
    public static func recentUserMessages(transcript: Data, limit: Int, maxCharacters: Int = 1500) -> [String] {
        guard limit > 0 else { return [] }
        var messages: [String] = []
        for line in transcript.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "user",
                  object["toolUseResult"] == nil,
                  object["isMeta"] as? Bool != true,
                  object["isCompactSummary"] as? Bool != true,
                  let message = object["message"] as? [String: Any] else { continue }
            let text: String
            if let content = message["content"] as? String {
                text = content
            } else if let parts = message["content"] as? [[String: Any]] {
                guard !parts.contains(where: { $0["type"] as? String == "tool_result" }) else { continue }
                text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            } else {
                continue
            }
            let cleaned = stripSystemReminders(text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, !cleaned.hasPrefix("<command-"), !cleaned.hasPrefix("<local-command") else { continue }
            messages.append(cleaned.count > maxCharacters ? String(cleaned.prefix(maxCharacters)) + "…" : cleaned)
        }
        return Array(messages.suffix(limit))
    }

    /// The text of Claude's last message in a transcript, shortened for the panel.
    public static func lastAssistantText(transcript: Data, maxCharacters: Int = 600) -> String? {
        var latest: String?
        for line in transcript.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let parts = message["content"] as? [[String: Any]] else { continue }
            let text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { latest = text }
        }
        guard let latest else { return nil }
        return latest.count > maxCharacters ? String(latest.prefix(maxCharacters)) + "…" : latest
    }

    static func stripSystemReminders(_ text: String) -> String {
        var result = text
        while let start = result.range(of: "<system-reminder>"),
              let end = result.range(of: "</system-reminder>", range: start.upperBound..<result.endIndex) {
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return result
    }
}
