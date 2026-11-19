import Foundation

/// Follows a Claude Code transcript to see when a call that stew asks about gets its
/// result some other way. Claude Code shows its own prompt for the call at the same
/// time as the PermissionRequest hook runs, and runs no hook when that prompt is
/// answered, or when it blocks the call after its time limit. The call's result in the
/// transcript is then the only sign that nobody waits for stew's answer any more.
public struct TranscriptWatch: Sendable {
    let toolName: String
    /// Canonical JSON of the call's input, as `HookCall.key`.
    let key: String
    /// Matching calls with no result yet.
    private var open: Set<String> = []
    /// False while reading what the transcript held when the hook started.
    private var following = false

    public init(toolName: String, key: String) {
        self.toolName = toolName
        self.key = key
    }

    /// The transcript that records the call: a subagent's calls go to its own file next
    /// to the session's transcript.
    public static func path(transcriptPath: String, agentID: String?) -> String {
        guard let agentID else { return transcriptPath }
        let session = transcriptPath.hasSuffix(".jsonl") ? String(transcriptPath.dropLast(6)) : transcriptPath
        return "\(session)/subagents/agent-\(agentID).jsonl"
    }

    /// From now on, a result for a matching call means the call is settled. Results read
    /// before this belong to earlier calls with the same input.
    public mutating func follow() {
        following = true
    }

    /// Reads transcript lines. True once a matching call that was still open gets its
    /// result while following.
    public mutating func read(_ lines: [Substring]) -> Bool {
        var settled = false
        for line in lines {
            guard line.contains("\"tool_") else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for part in content {
                switch part["type"] as? String {
                case "tool_use":
                    guard part["name"] as? String == toolName, let id = part["id"] as? String,
                          Self.key(of: part["input"]) == key else { continue }
                    open.insert(id)
                case "tool_result":
                    guard let id = part["tool_use_id"] as? String, open.remove(id) != nil else { continue }
                    if following { settled = true }
                default:
                    continue
                }
            }
        }
        return settled
    }

    static func key(of input: Any?) -> String? {
        let object = input as? [String: Any] ?? [:]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Splits what a growing file gains, read by read, into complete lines.
public struct LineFollower: Sendable {
    private var partial = Data()

    public init() {}

    /// The complete lines so far. A trailing line without its newline waits for the
    /// next read.
    public mutating func lines(in data: Data) -> [Substring] {
        partial.append(data)
        guard let lastNewline = partial.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        let complete = partial[partial.startIndex...lastNewline]
        partial = Data(partial[partial.index(after: lastNewline)...])
        return String(decoding: complete, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
    }
}

extension PermissionRequest {
    /// Seconds stew may ask about a Claude Code PermissionRequest. In auto and
    /// bypassPermissions mode, the terminal prompt for a shell removal that could reach
    /// far more than intended blocks the call after two minutes, so stew stops a little
    /// earlier. The hook input does not say which check asked, so every shell call in
    /// those modes gets the shorter time; for any other prompt the terminal still waits
    /// once stew's time is up.
    public static func claudeTimeLimit(toolName: String, permissionMode: String?, hookLimit: Double) -> Double {
        let countdown = ["auto", "bypassPermissions"].contains(permissionMode ?? "") && ["Bash", "Monitor"].contains(toolName)
        return countdown ? min(hookLimit, claudeCountdown - 5) : hookLimit
    }

    /// Claude Code's time limit on the terminal prompt for such a removal.
    public static let claudeCountdown: Double = 120
}
