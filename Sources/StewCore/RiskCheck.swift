import Foundation

/// Builds the input for the auto mode style risk check and reads its result.
/// The check runs `claude -p` with the user's effective auto mode rules as policy.
public enum RiskCheck {
    public static let schema = """
    {"type":"object","properties":{"verdict":{"type":"string","enum":["allow","soft_deny","hard_deny"]},"risk":{"type":"string","enum":["low","medium","high"]},"rule":{"type":["string","null"]},"summary":{"type":"string"},"severity":{"type":"string","enum":["low","medium","high","critical"]},"reversibility":{"type":"string"},"risky_part":{"type":["string","null"]}},"required":["verdict","risk","rule","summary","severity","reversibility","risky_part"],"additionalProperties":false}
    """

    /// One worked example for the severity rubric in the prompt.
    public struct SeverityExample: Equatable, Sendable {
        public let action: String
        /// The levels that fit; the prompt names the highest one.
        public let fitting: ClosedRange<Severity>
        public let why: String
    }

    /// Severity measures what the action does if it runs, not how sensitive the data it
    /// touches is: reading a secret locally is not high, sending it out is.
    public static let severityExamples: [SeverityExample] = [
        SeverityExample(action: "Edit a file in the repo, or git commit", fitting: .low ... .low, why: "local, undone with another edit or git reset"),
        SeverityExample(action: "rm -rf of a build or cache folder inside the project (dist, node_modules, .build)", fitting: .low ... .medium, why: "the build recreates it"),
        SeverityExample(action: "Read a password from the keychain, read an .env file, or op read", fitting: .low ... .medium, why: "reading a secret on this machine sends it nowhere; the approval is the check on intent"),
        SeverityExample(action: "git push to a feature branch", fitting: .medium ... .medium, why: "others can see it, but a later push or the reflog undoes it"),
        SeverityExample(action: "git reset --hard, or installing a package", fitting: .medium ... .medium, why: "undone with git reflog, or by uninstalling"),
        SeverityExample(action: "git push --force to main or another shared branch", fitting: .high ... .high, why: "rewrites history other people have pulled"),
        SeverityExample(action: "rm -rf ~, or rm -rf of a folder outside the project", fitting: .high ... .critical, why: "deletes files permanently; no undo"),
        SeverityExample(action: "A token or secret piped to curl to a host that is not the project's", fitting: .high ... .critical, why: "the secret leaves this machine and cannot be taken back"),
        SeverityExample(action: "DROP TABLE, or deleting cloud resources", fitting: .high ... .critical, why: "data or infrastructure is gone unless a backup exists"),
        SeverityExample(action: "Send money or emails to customers, delete production data or backups, publish a release", fitting: .critical ... .critical, why: "irreversible and reaches the outside world"),
    ]

    static var severityRubric: String {
        severityExamples.map { example in
            let levels = example.fitting.lowerBound == example.fitting.upperBound
                ? example.fitting.lowerBound.rawValue
                : "\(example.fitting.lowerBound.rawValue) or \(example.fitting.upperBound.rawValue)"
            return "- \(example.action): \(levels) (\(example.why))"
        }.joined(separator: "\n")
    }

    public static func systemPrompt(policyJSON: String) -> String {
        """
        You review actions that an AI coding agent wants to run. The agent asks its user for permission first, and your verdict is shown to the user as a warning above the command. Judge the proposed action against the auto mode policy below, the way the auto mode classifier would:

        - A hard_deny rule always blocks.
        - A soft_deny rule blocks unless the user's own recent messages clearly ask for this action. The agent's stated reason is not user consent.
        - An allow rule is an exception that lets an action through.
        - Use the environment section to decide what is trusted (repos, domains, buckets).

        Judge only the given action, with the given working directory and the user's recent messages as context. Your own working directory and session are not the agent's: ignore them. Set "rule" to the name of the deciding rule (the text before its colon), or null when no rule applies. Write "summary" for the user in at most two short sentences, 40 words maximum: say what the command does that matters, and to which target. When the risky part is something the user's recent messages did not ask for, say so. No advice to the agent.

        Set "risky_part" to the shortest part of the command that carries the risk, copied character for character from the command, such as "git checkout -q -- ." or "dropdb \"$db\"". Use null when nothing in the command is risky, or when there is no command.

        When the action is "Run code", the command is JavaScript that Claude Code runs in one step: each $`...` runs a shell command, and calls such as edit(...) and write(...) change files. Judge everything the code would do, including commands built from values it computes, and copy "risky_part" from the code.

        "git_status", when present, is `git status --porcelain --branch` for the working directory: the branch, then one line per changed or untracked file. Use it to say which uncommitted work a command would lose, and how many files. "auto_mode_blocked", when present, means Claude Code's auto mode already blocked this call under that rule: the user wants to know why, so make the summary name what in the command falls under that rule.

        Separately from the verdict, set "severity" to how bad it is if the action runs, judged by what the action itself does: how hard it is to undo, and whether it reaches other people or the outside world. Do not raise it for how sensitive the data it touches is: the user approves each action, so reading a secret on this machine is low or medium. It becomes high or critical only when the action also sends the secret somewhere outside (an unknown host, a post, a public repo) or uses it to do something irreversible.
        - low: local and easily undone.
        - medium: undoable with effort.
        - high: hard or impossible to undo, or it affects other people.
        - critical: irreversible and external.
        Examples:
        \(severityRubric)
        Set "reversibility" to one short sentence for the user on whether and how it can be undone, such as "Can be undone with git reflog." or "Deletes files permanently; no undo."

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
        /// The auto mode category of a call that auto mode already blocked.
        public var autoModeBlocked: String?
        public var gitStatus: String?

        enum CodingKeys: String, CodingKey {
            case action, command, reason, cwd
            case recentUserMessages = "recent_user_messages"
            case autoModeBlocked = "auto_mode_blocked"
            case gitStatus = "git_status"
        }
    }

    public static func input(for permission: PermissionRequest, session: SessionInfo, recentUserMessages: [String], gitStatus: String? = nil) throws -> String {
        let input = Input(
            action: permission.action,
            command: permission.command,
            reason: permission.reason,
            cwd: session.cwd,
            recentUserMessages: recentUserMessages,
            autoModeBlocked: permission.blocked.map { $0.category ?? $0.reason },
            gitStatus: gitStatus
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

    /// `git status --porcelain --branch` output for the check: the branch line and at most
    /// `maxFiles` file lines, then a count of the rest. Nil when there is nothing to say.
    public static func gitStatus(porcelain: String, maxFiles: Int = 40) -> String? {
        let lines = porcelain.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { return nil }
        let branch = lines.first(where: { $0.hasPrefix("## ") })
        let files = lines.filter { !$0.hasPrefix("## ") }
        var kept = (branch.map { [$0] } ?? []) + files.prefix(maxFiles)
        if files.count > maxFiles { kept.append("… and \(files.count - maxFiles) more files") }
        if files.isEmpty { kept.append("(no uncommitted changes)") }
        return kept.joined(separator: "\n")
    }

    /// The risky part only when it is really in the command, so the panel never points at
    /// text the model made up. Nil for an empty part or one the command does not contain.
    public static func riskyPart(_ part: String?, in command: String?) -> String? {
        guard let part = part?.trimmingCharacters(in: .whitespacesAndNewlines), !part.isEmpty,
              let command, command.contains(part) else { return nil }
        return part
    }

    /// The risky part worth pointing at: nil when it is the whole command, since marking
    /// all of it only repeats the command.
    public static func partToPoint(_ part: String?, in command: String?) -> String? {
        guard let part, let command else { return nil }
        return part.trimmingCharacters(in: .whitespacesAndNewlines) == command.trimmingCharacters(in: .whitespacesAndNewlines) ? nil : part
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
