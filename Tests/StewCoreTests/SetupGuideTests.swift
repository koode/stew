import Foundation
import Testing
@testable import StewCore

@Suite struct SetupGuideTests {
    private func agent(_ agent: CodingAgent, _ presence: AgentPresence = .configured, hooks: HookInstallState = .none, skill: Bool = false) -> AgentSetup {
        AgentSetup(agent: agent, presence: presence, hooks: hooks, skillInstalled: skill)
    }

    @Test func opensByItselfOnlyWhenNothingIsSetUp() {
        #expect(SetupGuide.isDue(completed: false, hooks: [.none, .none]))
        #expect(!SetupGuide.isDue(completed: true, hooks: [.none, .none]))
    }

    @Test func someoneWithHooksSetStewUpBefore() {
        #expect(!SetupGuide.isDue(completed: false, hooks: [.complete, .none]))
        #expect(!SetupGuide.isDue(completed: false, hooks: [.none, .partial]))
    }

    @Test func theConfigKeyDefaultsToNotCompleted() throws {
        #expect(!StewConfig().setup.completed)
        let older = try JSONDecoder().decode(StewConfig.self, from: Data(#"{"chord":"cmd"}"#.utf8))
        #expect(!older.setup.completed)
        let done = try JSONDecoder().decode(StewConfig.self, from: Data(#"{"setup":{"completed":true}}"#.utf8))
        #expect(done.setup.completed)
        let empty = try JSONDecoder().decode(StewConfig.self, from: Data(#"{"setup":{}}"#.utf8))
        #expect(!empty.setup.completed)
        let encoded = String(decoding: try JSONEncoder().encode(done), as: UTF8.self)
        #expect(encoded.contains(#""setup":{"completed":true}"#))
    }

    @Test func presenceComesFromTheFolderThenTheCommand() {
        #expect(AgentPresence.detect(configFolderExists: true, commandFound: false) == .configured)
        #expect(AgentPresence.detect(configFolderExists: false, commandFound: true) == .commandOnly)
        #expect(AgentPresence.detect(configFolderExists: false, commandFound: false) == .missing)
    }

    @Test func statusOfEachAgent() {
        #expect(agent(.claudeCode, .missing).status == .notFound)
        #expect(agent(.claudeCode, .commandOnly).status == .notFound)
        #expect(agent(.claudeCode).status == .notInstalled)
        #expect(agent(.claudeCode, skill: true).status == .partlyInstalled)
        #expect(agent(.claudeCode, hooks: .complete).status == .partlyInstalled)
        #expect(agent(.claudeCode, hooks: .partial, skill: true).status == .needsUpdate)
        #expect(agent(.claudeCode, hooks: .complete, skill: true).status == .installed)
    }

    @Test func installNeedsTheFolderAndSomethingMissing() {
        #expect(agent(.codex).canInstall)
        #expect(agent(.codex, skill: true).canInstall)
        #expect(!agent(.codex, .commandOnly).canInstall)
        #expect(!agent(.codex, .missing).canInstall)
        #expect(!agent(.codex, hooks: .complete, skill: true).canInstall)
    }

    @Test func onlyCodexHooksWaitForTrust() {
        #expect(!agent(.codex).needsTrust)
        #expect(agent(.codex, hooks: .complete).needsTrust)
        #expect(agent(.codex, hooks: .partial).needsTrust)
        #expect(!agent(.claudeCode, hooks: .complete).needsTrust)
        #expect(CodingAgent.codex.minimumVersion == "0.122")
        #expect(CodingAgent.claudeCode.minimumVersion == nil)
    }

    @Test func agentsStepIsDoneWhenEveryFoundAgentIsInstalled() {
        let claude = agent(.claudeCode, hooks: .complete, skill: true)
        let codexMissing = agent(.codex, .missing)
        #expect(SetupGuide.isDone(.agents, agents: [claude, codexMissing], sampleAnswered: false, phonePaired: false))
        #expect(!SetupGuide.isDone(.agents, agents: [claude, agent(.codex)], sampleAnswered: false, phonePaired: false))
        #expect(!SetupGuide.isDone(.agents, agents: [agent(.claudeCode, .missing), codexMissing], sampleAnswered: false, phonePaired: false))
    }

    @Test func otherStepsFollowTheirState() {
        #expect(SetupGuide.isDone(.tryIt, agents: [], sampleAnswered: true, phonePaired: false))
        #expect(!SetupGuide.isDone(.tryIt, agents: [], sampleAnswered: false, phonePaired: true))
        #expect(SetupGuide.isDone(.phone, agents: [], sampleAnswered: false, phonePaired: true))
        #expect(!SetupGuide.isDone(.welcome, agents: [], sampleAnswered: true, phonePaired: true))
        #expect(!SetupGuide.isDone(.done, agents: [], sampleAnswered: true, phonePaired: true))
    }

    @Test func stepsRunInOrder() {
        #expect(SetupStep.welcome.previous == nil)
        #expect(SetupStep.welcome.next == .agents)
        #expect(SetupStep.phone.next == .done)
        #expect(SetupStep.done.next == nil)
        #expect(SetupStep.done.previous == .phone)
    }

    @Test func theSampleNamesAnAgentThatIsSetUp() {
        #expect(SetupGuide.sampleAgent([]) == .claudeCode)
        #expect(SetupGuide.sampleAgent([agent(.claudeCode, .missing), agent(.codex)]) == .codex)
        #expect(SetupGuide.sampleAgent([agent(.claudeCode), agent(.codex, hooks: .complete, skill: true)]) == .codex)
        let request = SetupGuide.sampleRequest(agent: .codex)
        #expect(request.session.agent == .codex)
        #expect(request.maxWait == nil)
        guard case .permission(let permission) = request.prompt else {
            Issue.record("the sample is a permission request")
            return
        }
        #expect(permission.blocked == nil)
        #expect(permission.command == "echo hello")
    }
}
