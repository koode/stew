import AppKit
import SwiftUI
import StewCore

/// Renders each step of the setup window in its states, for `stew snapshot`. It never
/// reads the agents' folders or hook files.
enum SetupSnapshot {
    private struct Scenario {
        let name: String
        let step: SetupStep
        var agents: [AgentSetup] = SetupSnapshot.installedClaudeOnly
        var codexHooksDisabled = false
        var sampleOutcome: HistoryEntry.Outcome?
        var signedIn = false
        var paired = false
        var config: (inout StewConfig) -> Void = { _ in }
    }

    private static func agent(_ agent: CodingAgent, _ presence: AgentPresence, hooks: HookInstallState = .none, skill: Bool = false) -> AgentSetup {
        AgentSetup(agent: agent, presence: presence, hooks: hooks, skillInstalled: skill)
    }

    private static let installedClaudeOnly = [
        agent(.claudeCode, .configured, hooks: .complete, skill: true),
        agent(.codex, .missing),
    ]

    static func render(to directory: String, write: (AnyView, Bool, String) -> Void) {
        let scenarios = [
            Scenario(name: "welcome", step: .welcome, agents: [agent(.claudeCode, .configured), agent(.codex, .missing)]),
            Scenario(name: "agents-none", step: .agents, agents: [agent(.claudeCode, .missing), agent(.codex, .missing)]),
            // The skill comes with every install; the hooks are a choice.
            Scenario(name: "agents-claude-only", step: .agents, agents: [agent(.claudeCode, .configured, skill: true), agent(.codex, .missing)]),
            Scenario(name: "agents-both", step: .agents, agents: [agent(.claudeCode, .configured), agent(.codex, .configured)]),
            Scenario(name: "agents-installed", step: .agents, agents: [
                agent(.claudeCode, .configured, hooks: .complete, skill: true),
                agent(.codex, .configured, hooks: .complete, skill: true),
            ]),
            Scenario(name: "agents-update", step: .agents, agents: [
                agent(.claudeCode, .configured, hooks: .partial, skill: true),
                agent(.codex, .configured, hooks: .complete, skill: true),
            ], codexHooksDisabled: true),
            Scenario(name: "agents-codex-command", step: .agents, agents: [
                agent(.claudeCode, .configured, hooks: .complete, skill: true),
                agent(.codex, .commandOnly),
            ]),
            Scenario(name: "try", step: .tryIt),
            Scenario(name: "try-approved", step: .tryIt, sampleOutcome: .approved),
            Scenario(name: "try-timed-out", step: .tryIt, sampleOutcome: .timedOut, config: { $0.position = "top-left" }),
            Scenario(name: "phone", step: .phone),
            Scenario(name: "phone-paired", step: .phone, signedIn: true, paired: true),
            Scenario(name: "done", step: .done),
            Scenario(name: "done-hidden-icon", step: .done, config: { $0.menuBar = false }),
        ]
        for scenario in scenarios {
            for dark in [false, true] {
                let settings = SettingsModel()
                settings.load()
                settings.showSample(scenario.config)
                let setup = SetupModel()
                setup.showSample(step: scenario.step, agents: scenario.agents, codexHooksDisabled: scenario.codexHooksDisabled, sampleOutcome: scenario.sampleOutcome)
                let view = SetupView(setup: setup, settings: settings, phoneSample: (scenario.signedIn, scenario.paired))
                    .frame(width: SetupWindowController.size.width, height: SetupWindowController.size.height)
                let path = "\(directory)/setup-\(scenario.name)-\(dark ? "dark" : "light").png"
                write(AnyView(view), dark, path)
                print(path)
            }
        }
    }
}
