import Foundation

/// A tool call that Claude Code's auto mode blocked, as shown in the panel.
public struct BlockedCall: Codable, Equatable, Sendable {
    public var toolName: String
    /// Rule category from the denial, such as "Destructive or Unwanted Actions".
    public var category: String?
    /// The raw denial reason.
    public var reason: String
    /// The category is a hard deny rule: no grants beyond a single approval.
    public var hardDeny: Bool
    /// Absolute project folder (git root, else the session folder) that grants apply to.
    public var projectRoot: String
    /// Allow-rule candidates for a Bash command, secrets already wildcarded.
    public var suggestions: [RuleSuggestion]

    public init(toolName: String, category: String?, reason: String, hardDeny: Bool, projectRoot: String, suggestions: [RuleSuggestion]) {
        self.toolName = toolName
        self.category = category
        self.reason = reason
        self.hardDeny = hardDeny
        self.projectRoot = projectRoot
        self.suggestions = suggestions
    }

    /// Scopes the user can grant, in panel order: rule suggestions, then the category.
    public var grantScopes: [GrantChoice.Scope] {
        guard !hardDeny else { return [] }
        var scopes = suggestions.map { GrantChoice.Scope(kind: $0.kind == .exact ? .exact : .pattern, value: $0.pattern) }
        if let category {
            scopes.append(GrantChoice.Scope(kind: .category, value: category))
        }
        return Array(scopes.prefix(4))
    }

    /// "[Destructive or Unwanted Actions]" → "Destructive or Unwanted Actions".
    public static func category(fromReason reason: String) -> String? {
        let trimmed = reason.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { return nil }
        let name = trimmed[trimmed.index(after: trimmed.startIndex)..<close].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Denials Claude Code will not let the model retry, so asking would be pointless.
    public static func isRetryable(reason: String) -> Bool {
        let lowered = reason.lowercased()
        return !(lowered.hasPrefix("auto mode could not evaluate") || lowered.hasPrefix("classifier unavailable"))
    }

    /// Rule names from the `hard_deny` list of `claude auto-mode config`.
    public static func hardDenyNames(policyJSON: Data) -> Set<String> {
        guard let object = try? JSONSerialization.jsonObject(with: policyJSON) as? [String: Any],
              let rules = object["hard_deny"] as? [String] else { return [] }
        return Set(rules.compactMap { rule in
            guard let colon = rule.firstIndex(of: ":") else { return nil }
            let name = rule[..<colon].split(separator: "[").first.map(String.init) ?? ""
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || trimmed.count > 60 ? nil : trimmed
        })
    }
}

/// What the user chose beyond a single approval.
public struct GrantChoice: Codable, Equatable, Sendable {
    public struct Scope: Codable, Equatable, Hashable, Sendable {
        public enum Kind: String, Codable, Sendable { case exact, pattern, category }
        public var kind: Kind
        /// Rule pattern for exact and pattern, category name for category.
        public var value: String

        public init(kind: Kind, value: String) {
            self.kind = kind
            self.value = value
        }
    }

    public enum Duration: String, Codable, Sendable { case hour, always }

    public var scope: Scope
    public var duration: Duration

    public init(scope: Scope, duration: Duration) {
        self.scope = scope
        self.duration = duration
    }

    /// Command rules kept forever belong in Claude Code's own allow list, which it
    /// enforces itself. Everything else lives in stew's grant store.
    public var writesClaudeRule: Bool { duration == .always && scope.kind != .category }
}

/// A stored permission. `once` and `denyNote` are consumed by the retry they answer.
public struct Grant: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Lets one identical retry through.
        case once
        /// Blocks the retry and hands the user's note to Claude as the reason.
        case denyNote
        /// Bash commands matching a pattern, in one project, until expiry.
        case pattern
        /// Calls auto mode blocks under one category, in one project.
        case category
        /// A rule stew wrote into a Claude Code settings file; listed so it can be revoked.
        case claudeRule
    }

    public var id: UUID
    public var kind: Kind
    public var toolName: String
    /// Exact call key, pattern, category name or rule content.
    public var value: String
    public var sessionID: String?
    public var projectRoot: String?
    public var note: String?
    /// For claudeRule: the settings file holding the rule.
    public var settingsPath: String?
    public var created: Date
    public var expires: Date?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        toolName: String,
        value: String,
        sessionID: String? = nil,
        projectRoot: String? = nil,
        note: String? = nil,
        settingsPath: String? = nil,
        created: Date = Date(),
        expires: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.toolName = toolName
        self.value = value
        self.sessionID = sessionID
        self.projectRoot = projectRoot
        self.note = note
        self.settingsPath = settingsPath
        self.created = created
        self.expires = expires
    }

    public func isLive(at now: Date) -> Bool {
        expires.map { $0 > now } ?? true
    }

    /// Shown in the approvals window.
    public var isStanding: Bool { kind == .pattern || kind == .category || kind == .claudeRule }
}

/// Decisions over the grant list. Pure: callers load and save the list.
public enum GrantBook {
    /// One-shot approvals live briefly: long enough for Claude to retry.
    public static let onceLifetime: TimeInterval = 15 * 60

    public enum PreToolDecision: Equatable, Sendable {
        case allow
        case deny(note: String)
    }

    /// PreToolUse: an approved retry, a denial note, or a standing pattern grant.
    public static func preToolUse(
        grants: inout [Grant],
        call: HookCall,
        projectRoot: () -> String,
        now: Date = Date()
    ) -> PreToolDecision? {
        grants.removeAll { !$0.isLive(at: now) }
        if let index = grants.firstIndex(where: {
            ($0.kind == .once || $0.kind == .denyNote) && $0.toolName == call.toolName && $0.value == call.key && $0.sessionID == call.sessionID
        }) {
            let grant = grants.remove(at: index)
            return grant.kind == .once ? .allow : .deny(note: grant.note ?? "Denied by the user.")
        }
        guard call.toolName == "Bash", let command = call.command, !CommandText.isCompound(command),
              grants.contains(where: { $0.kind == .pattern }) else { return nil }
        let root = projectRoot()
        let matched = grants.contains {
            $0.kind == .pattern && $0.projectRoot == root && CommandText.matches(pattern: $0.value, command: command)
        }
        return matched ? .allow : nil
    }

    /// PermissionDenied: a live category grant for this project and tool.
    public static func categoryGrant(grants: [Grant], toolName: String, category: String?, projectRoot: String, now: Date = Date()) -> Grant? {
        guard let category else { return nil }
        return grants.first {
            $0.kind == .category && $0.isLive(at: now) && $0.value == category && $0.projectRoot == projectRoot
        }
    }

    public static func once(for call: HookCall, now: Date = Date()) -> Grant {
        Grant(kind: .once, toolName: call.toolName, value: call.key, sessionID: call.sessionID, created: now, expires: now.addingTimeInterval(onceLifetime))
    }

    public static func denyNote(for call: HookCall, note: String, now: Date = Date()) -> Grant {
        Grant(kind: .denyNote, toolName: call.toolName, value: call.key, sessionID: call.sessionID, note: note, created: now, expires: now.addingTimeInterval(onceLifetime))
    }

    /// The standing grant for a choice kept in stew's store (not a Claude rule).
    public static func standing(_ choice: GrantChoice, toolName: String, projectRoot: String, now: Date = Date()) -> Grant? {
        guard !choice.writesClaudeRule else { return nil }
        let expires = choice.duration == .hour ? now.addingTimeInterval(3600) : nil
        let kind: Grant.Kind = choice.scope.kind == .category ? .category : .pattern
        return Grant(kind: kind, toolName: kind == .category ? "*" : toolName, value: choice.scope.value, projectRoot: projectRoot, created: now, expires: expires)
    }
}

/// One tool call as a hook sees it.
public struct HookCall: Equatable, Sendable {
    public var event: String
    public var sessionID: String?
    public var cwd: String
    public var transcriptPath: String?
    public var toolName: String
    /// Canonical JSON of the tool input: identical calls have identical keys.
    public var key: String
    public var command: String?
    public var description: String?
    /// Short text for the panel when the tool is not Bash: a path, a URL or the input.
    public var summary: String
    public var reason: String?

    public struct ParseError: Error, CustomStringConvertible {
        public let description: String
    }

    public static func parse(_ data: Data) throws -> HookCall {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError(description: "hook input is not a JSON object")
        }
        guard let toolName = object["tool_name"] as? String else {
            throw ParseError(description: "hook input has no tool_name")
        }
        let input = object["tool_input"] as? [String: Any] ?? [:]
        let keyData = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        let key = String(decoding: keyData, as: UTF8.self)
        let command = input["command"] as? String
        let summary: String
        if let command {
            summary = command
        } else if let path = (input["file_path"] ?? input["notebook_path"] ?? input["path"]) as? String {
            summary = path
        } else if let url = input["url"] as? String {
            summary = url
        } else {
            summary = key
        }
        return HookCall(
            event: object["hook_event_name"] as? String ?? "",
            sessionID: object["session_id"] as? String,
            cwd: object["cwd"] as? String ?? FileManager.default.currentDirectoryPath,
            transcriptPath: object["transcript_path"] as? String,
            toolName: toolName,
            key: key,
            command: command,
            description: input["description"] as? String,
            summary: summary,
            reason: object["reason"] as? String
        )
    }

    public init(event: String, sessionID: String?, cwd: String, transcriptPath: String? = nil, toolName: String, key: String, command: String?, description: String?, summary: String, reason: String?) {
        self.event = event
        self.sessionID = sessionID
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.toolName = toolName
        self.key = key
        self.command = command
        self.description = description
        self.summary = summary
        self.reason = reason
    }
}

/// JSON a hook prints on stdout.
public enum HookOutput {
    public static func retry() -> String {
        #"{"hookSpecificOutput":{"hookEventName":"PermissionDenied","retry":true}}"#
    }

    public static func preToolUse(_ decision: GrantBook.PreToolDecision) -> String {
        let output: [String: Any]
        switch decision {
        case .allow:
            output = ["hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "permissionDecisionReason": "Approved by the user in stew",
            ]]
        case .deny(let note):
            output = ["hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": "The user denied this in stew: \(note)",
            ]]
        }
        let data = (try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Edits Claude Code settings JSON, keeping every key it does not own.
public enum ClaudeSettings {
    public struct EditError: Error, CustomStringConvertible {
        public let description: String
    }

    static func object(from data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EditError(description: "settings file is not a JSON object")
        }
        return object
    }

    static func data(from object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    public static func addingAllowRule(_ rule: String, to data: Data?) throws -> Data {
        var object = try object(from: data)
        var permissions = object["permissions"] as? [String: Any] ?? [:]
        var allow = permissions["allow"] as? [String] ?? []
        if !allow.contains(rule) { allow.append(rule) }
        permissions["allow"] = allow
        object["permissions"] = permissions
        return try self.data(from: object)
    }

    public static func removingAllowRule(_ rule: String, from data: Data?) throws -> Data {
        var object = try object(from: data)
        guard var permissions = object["permissions"] as? [String: Any],
              var allow = permissions["allow"] as? [String] else { return try self.data(from: object) }
        allow.removeAll { $0 == rule }
        permissions["allow"] = allow
        object["permissions"] = permissions
        return try self.data(from: object)
    }

    /// Hook entries stew owns are recognized by their command: "<stew binary> hook <event>".
    static func isStewHook(_ entry: [String: Any], executable: String) -> Bool {
        let hooks = entry["hooks"] as? [[String: Any]] ?? []
        return hooks.contains { ($0["command"] as? String)?.hasPrefix(executable + " hook ") == true }
    }

    public static func installingHooks(executable: String, deniedTimeout: Int, into data: Data?) throws -> Data {
        var object = try object(from: data)
        var hooks = object["hooks"] as? [String: Any] ?? [:]
        let entries: [(String, String, Int)] = [
            ("PermissionDenied", "denied", deniedTimeout),
            ("PreToolUse", "pre", 10),
        ]
        for (event, subcommand, timeout) in entries {
            var list = (hooks[event] as? [[String: Any]] ?? []).filter { !isStewHook($0, executable: executable) }
            list.append([
                "matcher": "*",
                "hooks": [["type": "command", "command": "\(executable) hook \(subcommand)", "timeout": timeout]],
            ])
            hooks[event] = list
        }
        object["hooks"] = hooks
        return try self.data(from: object)
    }

    public static func removingHooks(executable: String, from data: Data?) throws -> Data {
        var object = try object(from: data)
        guard var hooks = object["hooks"] as? [String: Any] else { return try self.data(from: object) }
        for event in ["PermissionDenied", "PreToolUse"] {
            guard let list = hooks[event] as? [[String: Any]] else { continue }
            let kept = list.filter { !isStewHook($0, executable: executable) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        object["hooks"] = hooks.isEmpty ? nil : hooks
        return try self.data(from: object)
    }

    public static func hasHooks(executable: String, in data: Data?) -> Bool {
        guard let object = try? object(from: data), let hooks = object["hooks"] as? [String: Any] else { return false }
        return ["PermissionDenied", "PreToolUse"].allSatisfy { event in
            (hooks[event] as? [[String: Any]] ?? []).contains { isStewHook($0, executable: executable) }
        }
    }
}
