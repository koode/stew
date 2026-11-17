import Foundation

/// `setup` in config.json.
public struct SetupConfig: Codable, Equatable, Sendable {
    /// The user finished or closed the setup window, so it no longer opens by itself.
    public var completed: Bool

    public init(completed: Bool = false) {
        self.completed = completed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        completed = try container.decodeIfPresent(Bool.self, forKey: .completed) ?? false
    }
}

/// The steps of the setup window, in order.
public enum SetupStep: String, CaseIterable, Identifiable, Sendable {
    case welcome, agents, tryIt = "try", phone, done

    public var id: String { rawValue }

    public var next: SetupStep? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index + 1 < all.count else { return nil }
        return all[index + 1]
    }

    public var previous: SetupStep? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index > 0 else { return nil }
        return all[index - 1]
    }
}

/// Whether an agent is on this Mac, from its config folder and its command.
public enum AgentPresence: Equatable, Sendable {
    /// Its config folder exists, so the skill and hooks have a place to go.
    case configured
    /// Its command is installed but has not made its config folder yet: it has never run.
    case commandOnly
    case missing

    public static func detect(configFolderExists: Bool, commandFound: Bool) -> AgentPresence {
        if configFolderExists { return .configured }
        return commandFound ? .commandOnly : .missing
    }
}

/// One agent as the setup window shows it: found or not, and what of stew it has.
public struct AgentSetup: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case notFound
        case notInstalled
        /// The skill without the hooks, or the hooks without the skill.
        case partlyInstalled
        /// Hooks from an older stew: installing again adds what is missing.
        case needsUpdate
        case installed
    }

    public var agent: CodingAgent
    public var presence: AgentPresence
    public var hooks: HookInstallState
    public var skillInstalled: Bool

    public init(agent: CodingAgent, presence: AgentPresence, hooks: HookInstallState, skillInstalled: Bool) {
        self.agent = agent
        self.presence = presence
        self.hooks = hooks
        self.skillInstalled = skillInstalled
    }

    public var status: Status {
        if hooks == .none && !skillInstalled { return presence == .configured ? .notInstalled : .notFound }
        if hooks == .partial { return .needsUpdate }
        if hooks == .complete && skillInstalled { return .installed }
        return .partlyInstalled
    }

    /// Install puts the skill in the agent's config folder, so it needs that folder.
    public var canInstall: Bool { presence == .configured && status != .installed }

    /// Codex runs a new or changed hook only after the user trusts it in its /hooks view.
    public var needsTrust: Bool { agent == .codex && hooks != .none }
}

extension CodingAgent {
    /// The oldest version whose hooks stew uses: Codex has PermissionRequest hooks from
    /// 0.122. Nil when every version that has hooks works.
    public var minimumVersion: String? {
        switch self {
        case .claudeCode: nil
        case .codex: "0.122"
        }
    }
}

public enum SetupGuide {
    /// The setup window opens by itself when stew starts, and in place of Settings when
    /// Stew.app is opened, until the user finishes or closes it. Someone with hooks
    /// installed for any agent set stew up before this window existed, so it never opens
    /// by itself for them.
    public static func isDue(completed: Bool, hooks: [HookInstallState]) -> Bool {
        !completed && hooks.allSatisfy { $0 == .none }
    }

    /// Whether a step's work is done, for the check beside its name. Welcome and Done
    /// have nothing to do.
    public static func isDone(_ step: SetupStep, agents: [AgentSetup], sampleAnswered: Bool, phonePaired: Bool) -> Bool {
        switch step {
        case .welcome, .done:
            return false
        case .agents:
            let found = agents.filter { $0.presence == .configured }
            return !found.isEmpty && found.allSatisfy { $0.status == .installed }
        case .tryIt:
            return sampleAnswered
        case .phone:
            return phonePaired
        }
    }

    /// The agent the sample request names: one that is set up for stew, else one that is
    /// on this Mac, else Claude Code.
    public static func sampleAgent(_ agents: [AgentSetup]) -> CodingAgent {
        agents.first { $0.status == .installed }?.agent
            ?? agents.first { $0.presence == .configured }?.agent
            ?? .claudeCode
    }

    /// The sample permission request of the Try it step. It runs nothing: the panel
    /// shows it like any request, but no caller waits for the answer.
    public static func sampleRequest(agent: CodingAgent) -> StewRequest {
        StewRequest(
            session: SessionInfo(name: "Try stew", agent: agent),
            prompt: .permission(PermissionRequest(
                action: "Run a sample command",
                command: "echo hello",
                reason: "This is a sample from stew's setup. Nothing runs, and no agent gets your answer."
            ))
        )
    }
}
