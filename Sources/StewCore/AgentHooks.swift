import Foundation

/// One hook handler stew adds to an agent's hook file.
public struct StewHook: Equatable, Sendable {
    public var event: String
    /// Nil for events that take no matcher.
    public var matcher: String?
    /// What follows "<stew> hook " in the command: the subcommand and its options.
    public var arguments: String
    /// Seconds the agent waits for the hook.
    public var timeout: Int
    /// Runs in the background, so it never holds up the agent.
    public var background: Bool
    /// Shown by the agent while the hook runs.
    public var statusMessage: String?
    /// What the agent does when the hook cannot run or gives no decision in time.
    /// "continue" lets the tool call go ahead: Claude Code's Code Mode otherwise refuses a
    /// call whose PreToolUse hook fails, so a moved or deleted stew would block every call.
    public var onFailure: String?

    public init(event: String, matcher: String?, arguments: String, timeout: Int, background: Bool = false, statusMessage: String? = nil, onFailure: String? = nil) {
        self.event = event
        self.matcher = matcher
        self.arguments = arguments
        self.timeout = timeout
        self.background = background
        self.statusMessage = statusMessage
        self.onFailure = onFailure
    }

    public func command(executable: String) -> String {
        "\(executable) hook \(arguments)"
    }

    /// The handler entry stew writes for this hook.
    public func handler(executable: String) -> [String: Any] {
        var handler: [String: Any] = ["type": "command", "command": command(executable: executable), "timeout": timeout]
        if background { handler["async"] = true }
        if let statusMessage { handler["statusMessage"] = statusMessage }
        if let onFailure { handler["onFailure"] = onFailure }
        return handler
    }
}

/// How much of the current set of hooks a hook file holds.
public enum HookInstallState: Equatable, Sendable {
    case none
    /// Installed by an older stew: re-run install to add what is missing.
    case partial
    case complete
}

extension CodingAgent {
    /// The hooks stew installs for the agent. `waitTimeout` is how long a hook that waits
    /// for the user may take.
    ///
    /// Claude Code: the question hook waits for the user, so it needs the long timeout;
    /// the general PreToolUse hook only reads the grant and late answer files and must stay
    /// short. Stop and UserPromptSubmit take no matcher. The needs Stop hook runs in the
    /// background, so it can never hold up the end of a turn. The late answer Stop hook
    /// runs in the foreground, because only a foreground hook can keep the agent going; it
    /// only reads late-answers.json, so it stays fast.
    ///
    /// Codex has no auto mode and no AskUserQuestion: its PermissionRequest hook asks in
    /// stew before Codex shows its own approval prompt. The Stop and UserPromptSubmit hooks
    /// do what they do for Claude Code.
    /// Claude Code hooks never hold up the agent when stew itself fails: the call goes ahead
    /// as if stew were not installed. Codex's hook file has no such field.
    static let claudeOnFailure = "continue"

    public func stewHooks(waitTimeout: Int) -> [StewHook] {
        switch self {
        case .claudeCode:
            let failure = Self.claudeOnFailure
            return [
                StewHook(event: "PermissionDenied", matcher: "*", arguments: "denied", timeout: waitTimeout, onFailure: failure),
                StewHook(event: "PreToolUse", matcher: "*", arguments: "pre", timeout: 10, onFailure: failure),
                StewHook(event: "PreToolUse", matcher: "AskUserQuestion", arguments: "question", timeout: waitTimeout, onFailure: failure),
                StewHook(event: "Stop", matcher: nil, arguments: "stop", timeout: 15, background: true, onFailure: failure),
                StewHook(event: "Stop", matcher: nil, arguments: "stop-late", timeout: 5, onFailure: failure),
                StewHook(event: "UserPromptSubmit", matcher: nil, arguments: "prompt", timeout: 5, onFailure: failure),
            ]
        case .codex:
            return [
                StewHook(event: "PermissionRequest", matcher: "*", arguments: "permission --agent codex", timeout: waitTimeout, statusMessage: "Asking in stew"),
                StewHook(event: "Stop", matcher: nil, arguments: "stop --agent codex", timeout: 15, background: true),
                StewHook(event: "Stop", matcher: nil, arguments: "stop-late --agent codex", timeout: 5),
                StewHook(event: "UserPromptSubmit", matcher: nil, arguments: "prompt --agent codex", timeout: 5),
            ]
        }
    }
}

/// Edits the `hooks` object that Claude Code's settings.json and Codex's hooks.json share:
/// event name to a list of matcher groups, each with a list of handlers. Every key and
/// hook stew does not own stays as it is.
public enum HookFile {
    public struct EditError: Error, CustomStringConvertible {
        public let description: String
    }

    static func object(from data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EditError(description: "hook file is not a JSON object")
        }
        return object
    }

    static func data(from object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    /// Hook entries stew owns are recognized by their command: "<stew binary> hook <event>".
    static func isStewHook(_ entry: [String: Any], executable: String) -> Bool {
        let hooks = entry["hooks"] as? [[String: Any]] ?? []
        return hooks.contains { ($0["command"] as? String)?.hasPrefix(executable + " hook ") == true }
    }

    /// The file with exactly `hooks` as stew's: older stew entries for these events go,
    /// so installing twice changes nothing.
    public static func installing(_ hooks: [StewHook], executable: String, into data: Data?) throws -> Data {
        var object = try object(from: data)
        var events = object["hooks"] as? [String: Any] ?? [:]
        for event in Set(hooks.map(\.event)) {
            events[event] = (events[event] as? [[String: Any]] ?? []).filter { !isStewHook($0, executable: executable) }
        }
        for hook in hooks {
            var list = events[hook.event] as? [[String: Any]] ?? []
            var entry: [String: Any] = ["hooks": [hook.handler(executable: executable)]]
            if let matcher = hook.matcher { entry["matcher"] = matcher }
            list.append(entry)
            events[hook.event] = list
        }
        object["hooks"] = events
        return try self.data(from: object)
    }

    /// Nil when the file holds none of stew's hooks in these events: the file must then
    /// stay untouched, byte for byte, instead of being re-serialized.
    public static func removing(events: [String], executable: String, from data: Data?) throws -> Data? {
        var object = try object(from: data)
        guard var hooks = object["hooks"] as? [String: Any],
              events.contains(where: { event in
                  (hooks[event] as? [[String: Any]] ?? []).contains { isStewHook($0, executable: executable) }
              }) else { return nil }
        for event in events {
            guard let list = hooks[event] as? [[String: Any]] else { continue }
            let kept = list.filter { !isStewHook($0, executable: executable) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        object["hooks"] = hooks.isEmpty ? nil : hooks
        return try self.data(from: object)
    }

    public static func state(of wanted: [StewHook], executable: String, in data: Data?) -> HookInstallState {
        guard let object = try? object(from: data), let hooks = object["hooks"] as? [String: Any] else { return .none }
        let handlers = { (event: String) in
            (hooks[event] as? [[String: Any]] ?? []).flatMap { entry in entry["hooks"] as? [[String: Any]] ?? [] }
        }
        // A hook counts as present when its command is there, and as current only when the
        // handler also has today's fields (async, onFailure...): an older stew's entry then
        // shows as needing an update. The timeout is left out: it follows the user's time
        // limit, and callers that only look for the hooks pass any value.
        let shape = { (handler: [String: Any]) in
            NSDictionary(dictionary: handler.filter { $0.key != "timeout" })
        }
        let found = wanted.map { hook in
            handlers(hook.event).first { $0["command"] as? String == hook.command(executable: executable) }
        }
        let present = found.compactMap { $0 }
        if present.isEmpty { return .none }
        let current = zip(wanted, found).allSatisfy { hook, handler in
            guard let handler else { return false }
            return shape(handler).isEqual(shape(hook.handler(executable: executable)))
        }
        return current ? .complete : .partial
    }
}

/// What stew reads from Codex's config.toml. Only a few lines matter, so it scans lines
/// instead of parsing TOML: tables, dotted keys and comments, no multi-line values.
public enum CodexConfig {
    /// `[features] hooks = false`, or the deprecated `codex_hooks = false`: Codex then
    /// loads no hooks at all.
    public static func hooksDisabled(toml: String) -> Bool {
        var table = ""
        for rawLine in toml.components(separatedBy: .newlines) {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                table = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            let fullKey = table.isEmpty ? key : "\(table).\(key)"
            if ["features.hooks", "features.codex_hooks"].contains(fullKey), value == "false" { return true }
        }
        return false
    }

    /// Hooks defined inline, such as `[[hooks.Stop]]`: Codex merges them with hooks.json
    /// and warns at startup. Event names start with a capital letter; `[hooks.state]`,
    /// where Codex records which hooks the user trusts, is not a hook.
    public static func hasInlineHooks(toml: String) -> Bool {
        var table = ""
        for rawLine in toml.components(separatedBy: .newlines) {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                table = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                let parts = table.split(separator: ".", maxSplits: 2)
                if parts.count >= 2, parts[0] == "hooks", parts[1].first?.isUppercase == true { return true }
                continue
            }
            guard table == "hooks", let equals = line.firstIndex(of: "=") else { continue }
            if line[..<equals].trimmingCharacters(in: .whitespaces).first?.isUppercase == true { return true }
        }
        return false
    }

    private static func stripComment(_ line: String) -> String {
        var inString: Character?
        for (offset, character) in line.enumerated() {
            if let quote = inString {
                if character == quote { inString = nil }
            } else if character == "\"" || character == "'" {
                inString = character
            } else if character == "#" {
                return String(line.prefix(offset))
            }
        }
        return line
    }
}

extension PermissionRequest {
    /// An approval request from a PermissionRequest hook, as the panel shows it. Codex
    /// sends the reason it asks in `tool_input.description` when it has one.
    public static func approval(_ call: HookCall, agent: CodingAgent) -> PermissionRequest {
        let reason = call.description.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? "\(agent.name) did not say why."
        switch call.toolName {
        case "Bash":
            return PermissionRequest(action: "Run a shell command", command: call.command, reason: reason)
        case "apply_patch":
            return PermissionRequest(action: patchAction(call.command ?? ""), command: call.command, reason: reason)
        default:
            let parts = call.toolName.components(separatedBy: "__")
            let action = parts.count >= 3 && parts[0] == "mcp"
                ? "Use \(parts[2...].joined(separator: "__")) from the \(parts[1]) MCP server"
                : "Use the \(call.toolName) tool"
            return PermissionRequest(action: action, command: "\(call.toolName): \(call.summary)", reason: reason)
        }
    }

    /// "Edit Sources/App.swift", "Edit a.swift and b.swift", "Edit a.swift and 3 more
    /// files", from the file headers of an apply_patch patch.
    static func patchAction(_ patch: String) -> String {
        let headers = ["*** Update File: ", "*** Add File: ", "*** Delete File: "]
        var files: [String] = []
        for line in patch.components(separatedBy: .newlines) {
            guard let header = headers.first(where: line.hasPrefix) else { continue }
            let file = line.dropFirst(header.count).trimmingCharacters(in: .whitespaces)
            if !file.isEmpty, !files.contains(file) { files.append(file) }
        }
        switch files.count {
        case 0: return "Edit files"
        case 1: return "Edit \(files[0])"
        case 2: return "Edit \(files[0]) and \(files[1])"
        default: return "Edit \(files[0]) and \(files.count - 1) more files"
        }
    }
}

extension HookOutput {
    /// PermissionRequest (Codex, and Claude Code's event of the same name): allow, or deny
    /// with a message the agent reads. Never the reserved fields (`updatedInput`,
    /// `updatedPermissions`, `interrupt`), which Codex fails closed on. To leave the
    /// decision to the agent's own prompt, a hook prints nothing.
    public static func permissionRequest(allow: Bool, message: String? = nil) -> String {
        var decision: [String: Any] = ["behavior": allow ? "allow" : "deny"]
        if !allow { decision["message"] = message ?? "The user denied this in stew." }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        let data = (try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// No decision, for an event whose output must be JSON: Codex treats plain text from a
    /// Stop hook as invalid.
    public static let noDecision = "{}"
}
