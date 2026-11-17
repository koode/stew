import Foundation

/// The command line tool that runs a risk check.
public enum RiskCheckEngine: String, Codable, CaseIterable, Sendable {
    case claude, codex

    /// The agent the tool belongs to, for its name in settings and messages.
    public var agent: CodingAgent {
        switch self {
        case .claude: .claudeCode
        case .codex: .codex
        }
    }
}

/// `classifier.backend`: which tool checks a request.
public enum RiskCheckBackend: String, Codable, CaseIterable, Sendable {
    /// The tool of the agent that asks, so a Codex user needs no Claude login and the
    /// other way round. The other tool takes over when that one cannot run.
    case agent
    case claude
    case codex

    /// `classifier.backend` as written in the config: an unknown value reads as `agent`.
    public init(configValue: String) {
        self = RiskCheckBackend(rawValue: configValue.lowercased()) ?? .agent
    }

    /// The tools to try for a request from `agent`, in order. A chosen tool is the only
    /// one: the user picked it, so stew does not quietly use another.
    public func engines(for agent: CodingAgent) -> [RiskCheckEngine] {
        switch self {
        case .agent: agent == .codex ? [.codex, .claude] : [.claude, .codex]
        case .claude: [.claude]
        case .codex: [.codex]
        }
    }

    /// The first of `engines` that can run. `unavailable` returns why a tool cannot run
    /// (not installed, not logged in), or nil when it can. When none can, the error names
    /// every tool and its reason.
    public static func choose(
        _ engines: [RiskCheckEngine], unavailable: (RiskCheckEngine) -> String?
    ) -> Result<RiskCheckEngine, RiskCheck.CheckError> {
        var reasons: [String] = []
        for engine in engines {
            guard let reason = unavailable(engine) else { return .success(engine) }
            reasons.append(reason)
        }
        return .failure(RiskCheck.CheckError(description: reasons.joined(separator: "; ")))
    }
}

/// How the panel and the iPhone name the rules a verdict comes from. Only Claude Code's
/// auto mode rules may be called "your auto mode rules"; a check against stew's default
/// rules says it is stew's.
public enum RiskWording {
    public static func checking(defaultRules: Bool) -> String {
        defaultRules ? "Checking against stew's default rules…" : "Checking against your auto mode rules…"
    }

    /// The banner's title for the check's verdict. A call auto mode really blocked keeps
    /// "Auto mode blocked this": that verdict is Claude Code's own.
    public static func verdict(_ verdict: RiskAssessment.Verdict, defaultRules: Bool) -> String {
        let subject = defaultRules ? "stew's check" : "Auto mode"
        switch verdict {
        case .allow: return "\(subject) would allow this"
        case .softDeny: return "\(subject) would block this"
        case .hardDeny: return "\(subject) never allows this"
        }
    }
}

extension RiskCheckBackend {
    /// Whether a check that is about to start will use stew's default rules, for the
    /// banner while it runs: only Codex checks without them, when Claude Code cannot give
    /// its rules. The check itself says for sure once it knows.
    public static func expectsDefaultRules(engines: [RiskCheckEngine], claudeRulesAvailable: Bool) -> Bool {
        engines.first == .codex && !claudeRulesAvailable
    }
}

extension RiskCheck {
    /// Codex's small, fast model, for focused high-volume work such as classification
    /// ("Luna, for clear, repeatable tasks": https://learn.chatgpt.com/docs/models).
    public static let defaultCodexModel = "gpt-6-luna"

    /// Rules for a check without Claude Code's `claude auto-mode config`: a short set in
    /// the same shape and with the same category names, so the prompt reads the same.
    public static let defaultPolicyJSON = """
    {"hard_deny":["Data Exfiltration: sending secrets, credentials or private data to a host, repo or service outside the project"],\
    "soft_deny":[\
    "Git Destructive: force pushes, history rewrites, git reset --hard or checkout that discards uncommitted work, deleting remote branches",\
    "Irreversible Local Destruction: rm -rf or overwrites outside build and cache folders, deleting files that are not in git",\
    "Production Deploy: deploying, migrating or changing production systems or data",\
    "Credential Leakage: printing, copying or committing secrets and tokens",\
    "Code from External: running scripts or packages from the internet without review",\
    "Security Weaken: turning off TLS checks, auth, sandboxes or other protections",\
    "Modify Shared Resources: changing infrastructure, clusters, DNS or cloud resources other people use",\
    "Real-World Transactions: payments, purchases, sending email or messages to people"],\
    "allow":[\
    "Read-Only Operations: commands that only read files, state or logs",\
    "Local Operations: edits, builds and tests inside the project",\
    "Declared Dependencies: installing the dependencies the project declares"],\
    "environment":["No Claude Code auto mode rules were available, so these are stew's defaults. Treat the working directory's git repository as trusted."]}
    """

    /// The prompt argument of `codex exec`. The request itself comes on stdin, which Codex
    /// adds as context to this instruction.
    public static let codexPrompt = "Judge the action described in the JSON on stdin, following your instructions. Reply with only the JSON object the output schema asks for."

    /// The `codex exec` arguments for a check. Nothing reaches a shell: each value is one
    /// argument. Codex runs read-only with no tools at all (no shell, no web search, no
    /// apps or subagents), no approvals, no hooks, no user config (so no MCP servers or
    /// profiles) and no saved session, from a folder outside any project.
    public static func codexArguments(model: String, instructionsPath: String, schemaPath: String, outputPath: String) -> [String] {
        [
            "exec",
            "--model", model,
            "--sandbox", "read-only",
            "--ephemeral",
            "--ignore-user-config",
            "--ignore-rules",
            "--skip-git-repo-check",
            "--color", "never",
            "-c", "approval_policy=\"never\"",
            "-c", "web_search=\"disabled\"",
            "-c", "features.shell_tool=false",
            "-c", "features.apps=false",
            "-c", "features.multi_agent=false",
            "-c", "features.hooks=false",
            "-c", "features.memories=false",
            "-c", "history.persistence=\"none\"",
            "-c", "model_reasoning_effort=\"low\"",
            "-c", "model_instructions_file=\(tomlString(instructionsPath))",
            "--output-schema", schemaPath,
            "--output-last-message", outputPath,
            codexPrompt,
        ]
    }

    /// A TOML basic string, for a `-c key=value` override.
    public static func tomlString(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\t": escaped += "\\t"
            case "\r": escaped += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    escaped += String(format: "\\u%04X", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return "\"\(escaped)\""
    }

    /// Reads Codex's final message, which `--output-schema` makes a JSON object of the
    /// verdict. A fenced code block around it is accepted, since a model can add one.
    public static func parse(codexOutput: Data) throws -> RiskAssessment {
        var text = String(decoding: codexOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.components(separatedBy: .newlines).dropFirst().filter { !$0.hasPrefix("```") }.joined(separator: "\n")
        }
        guard !text.isEmpty else { throw CheckError(description: "no output from codex") }
        guard let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw CheckError(description: "codex returned no verdict: \(String(text.prefix(200)))")
        }
        do {
            return try JSONDecoder().decode(RiskAssessment.self, from: data)
        } catch {
            throw CheckError(description: "unexpected verdict shape")
        }
    }

    /// Whether `codex login status` says the CLI runs on a ChatGPT login. The check never
    /// runs on pay-per-token API billing: an API key login, or no login, says no.
    public static func codexUsesChatGPTLogin(exitStatus: Int32, output: String) -> Bool {
        let lowered = output.lowercased()
        return exitStatus == 0 && lowered.contains("chatgpt") && !lowered.contains("api key")
    }

    /// The user's last messages in a Codex session file (JSONL), oldest first. Codex says
    /// its session format is not a stable interface, so this reads only the user message
    /// events and returns nothing for lines it does not know.
    public static func recentUserMessages(codexSession: Data, limit: Int, maxCharacters: Int = 1500) -> [String] {
        guard limit > 0 else { return [] }
        var messages: [String] = []
        for line in codexSession.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "user_message",
                  let message = payload["message"] as? String else { continue }
            let cleaned = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            messages.append(cleaned.count > maxCharacters ? String(cleaned.prefix(maxCharacters)) + "…" : cleaned)
        }
        return Array(messages.suffix(limit))
    }
}
