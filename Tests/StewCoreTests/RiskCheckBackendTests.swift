import Foundation
import Testing
@testable import StewCore

@Suite struct RiskCheckBackendTests {
    @Test func theAskingAgentsToolGoesFirst() {
        #expect(RiskCheckBackend.agent.engines(for: .claudeCode) == [.claude, .codex])
        #expect(RiskCheckBackend.agent.engines(for: .codex) == [.codex, .claude])
        #expect(RiskCheckBackend.claude.engines(for: .codex) == [.claude])
        #expect(RiskCheckBackend.codex.engines(for: .claudeCode) == [.codex])
    }

    @Test func configValuesReadAsABackend() {
        #expect(RiskCheckBackend(configValue: "codex") == .codex)
        #expect(RiskCheckBackend(configValue: "Claude") == .claude)
        #expect(RiskCheckBackend(configValue: "agent") == .agent)
        #expect(RiskCheckBackend(configValue: "gemini") == .agent)
    }

    @Test func theFirstToolThatCanRunIsChosen() throws {
        let both = RiskCheckBackend.choose([.codex, .claude]) { _ in nil }
        #expect(try both.get() == .codex)
        let fallback = RiskCheckBackend.choose([.codex, .claude]) { $0 == .codex ? "codex CLI not found" : nil }
        #expect(try fallback.get() == .claude)
        var asked: [RiskCheckEngine] = []
        _ = RiskCheckBackend.choose([.claude, .codex]) { engine in asked.append(engine); return nil }
        #expect(asked == [.claude], "a tool after the chosen one is not even checked")
    }

    @Test func withNoToolTheReasonNamesEachOne() {
        let reasons: [RiskCheckEngine: String] = [
            .codex: "codex CLI not found; set classifier.codexPath",
            .claude: "claude is not logged in with a Claude subscription",
        ]
        let none = RiskCheckBackend.choose([.codex, .claude]) { reasons[$0] }
        #expect(throws: RiskCheck.CheckError(description: "codex CLI not found; set classifier.codexPath; claude is not logged in with a Claude subscription")) { try none.get() }
        let chosenOnly = RiskCheckBackend.choose(RiskCheckBackend.codex.engines(for: .claudeCode)) { reasons[$0] }
        #expect(throws: RiskCheck.CheckError(description: "codex CLI not found; set classifier.codexPath")) { try chosenOnly.get() }
    }

    @Test func configDefaultsAndValues() throws {
        let defaults = try JSONDecoder().decode(StewConfig.ClassifierConfig.self, from: Data("{}".utf8))
        #expect(defaults.backend == "agent")
        #expect(defaults.codexModel == "gpt-6-luna")
        #expect(defaults.codexPath == nil)
        let set = try JSONDecoder().decode(StewConfig.ClassifierConfig.self, from: Data(#"{"backend":"codex","codexModel":"gpt-6.1-terra","codexPath":"/opt/codex"}"#.utf8))
        #expect(set.backend == "codex")
        #expect(set.codexModel == "gpt-6.1-terra")
        #expect(set.codexPath == "/opt/codex")
    }
}

@Suite struct CodexRiskCheckTests {
    @Test func theCommandLineKeepsCodexReadOnlyAndToolFree() {
        let arguments = RiskCheck.codexArguments(
            model: "gpt-6-luna", instructionsPath: "/Users/me/Library/Caches/stew/codex-policy-1a.txt",
            schemaPath: "/Users/me/Library/Caches/stew/risk-schema-2b.json", outputPath: "/Users/me/Library/Caches/stew/codex-verdict-3c.json"
        )
        #expect(arguments == [
            "exec",
            "--model", "gpt-6-luna",
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
            "-c", "model_instructions_file=\"/Users/me/Library/Caches/stew/codex-policy-1a.txt\"",
            "--output-schema", "/Users/me/Library/Caches/stew/risk-schema-2b.json",
            "--output-last-message", "/Users/me/Library/Caches/stew/codex-verdict-3c.json",
            RiskCheck.codexPrompt,
        ])
        #expect(!arguments.contains { $0.contains("danger") || $0.contains("yolo") || $0 == "--trust" })
    }

    @Test func valuesStayOneArgumentAndOneTOMLString() {
        let arguments = RiskCheck.codexArguments(
            model: "gpt-6-luna; rm -rf ~", instructionsPath: "/tmp/a \"b\" $(id)\\c.txt", schemaPath: "/tmp/s.json", outputPath: "/tmp/o.json"
        )
        #expect(arguments[2] == "gpt-6-luna; rm -rf ~")
        #expect(arguments.contains(#"model_instructions_file="/tmp/a \"b\" $(id)\\c.txt""#))
        #expect(RiskCheck.tomlString("line\nnext\ttab") == #""line\nnext\ttab""#)
        #expect(RiskCheck.tomlString("\u{1}") == #""\u0001""#)
    }

    @Test func readsTheVerdictCodexWrote() throws {
        let verdict = #"{"verdict":"soft_deny","risk":"high","rule":"Git Destructive","summary":"Force-pushes main.","severity":"high","reversibility":"Others lose commits they pulled.","risky_part":"--force"}"#
        let assessment = try RiskCheck.parse(codexOutput: Data((verdict + "\n").utf8))
        #expect(assessment.verdict == .softDeny)
        #expect(assessment.severity == .high)
        #expect(assessment.riskyPart == "--force")
        #expect(assessment.reversibility == "Others lose commits they pulled.")
        let fenced = try RiskCheck.parse(codexOutput: Data("```json\n\(verdict)\n```".utf8))
        #expect(fenced == assessment)
    }

    @Test func malformedOutputIsAnError() {
        #expect(throws: RiskCheck.CheckError(description: "no output from codex")) { try RiskCheck.parse(codexOutput: Data("  \n".utf8)) }
        #expect(throws: RiskCheck.CheckError(description: "codex returned no verdict: I think this is fine.")) {
            try RiskCheck.parse(codexOutput: Data("I think this is fine.".utf8))
        }
        #expect(throws: RiskCheck.CheckError(description: "unexpected verdict shape")) {
            try RiskCheck.parse(codexOutput: Data(#"{"verdict":"maybe","summary":"x"}"#.utf8))
        }
        #expect(throws: RiskCheck.CheckError.self) { try RiskCheck.parse(codexOutput: Data("[1]".utf8)) }
    }

    @Test func onlyAChatGPTLoginRunsTheCheck() {
        #expect(RiskCheck.codexUsesChatGPTLogin(exitStatus: 0, output: "Logged in using ChatGPT\n"))
        #expect(!RiskCheck.codexUsesChatGPTLogin(exitStatus: 0, output: "Logged in using an API key - sk-proj-***"))
        #expect(!RiskCheck.codexUsesChatGPTLogin(exitStatus: 1, output: "Not logged in"))
        #expect(!RiskCheck.codexUsesChatGPTLogin(exitStatus: 0, output: ""))
    }

    @Test func defaultRulesHaveTheAutoModeShape() throws {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(RiskCheck.defaultPolicyJSON.utf8)) as? [String: [String]])
        #expect(Set(object.keys) == ["hard_deny", "soft_deny", "allow", "environment"])
        #expect(BlockedCall.hardDenyNames(policyJSON: Data(RiskCheck.defaultPolicyJSON.utf8)) == ["Data Exfiltration"])
        let softNames = try #require(object["soft_deny"]).map { $0.components(separatedBy: ":")[0] }
        #expect(softNames.contains("Git Destructive"))
        #expect(softNames.contains("Irreversible Local Destruction"))
        #expect(try #require(object["allow"]).allSatisfy { $0.contains(": ") })
        #expect(RiskCheck.defaultPolicyJSON.count < 2500, "short enough to keep the prompt small")
        #expect(RiskCheck.systemPrompt(policyJSON: RiskCheck.defaultPolicyJSON).contains("Data Exfiltration: sending secrets"))
    }

    @Test func readsTheUserMessagesOfACodexSession() {
        let lines = [
            #"{"timestamp":"2026-11-17T10:00:00Z","type":"session_meta","payload":{"id":"019a"}}"#,
            #"{"timestamp":"2026-11-17T10:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"tidy the repo"}}"#,
            #"{"timestamp":"2026-11-17T10:00:02Z","type":"event_msg","payload":{"type":"agent_message","message":"On it."}}"#,
            "not json",
            #"{"timestamp":"2026-11-17T10:00:03Z","type":"event_msg","payload":{"type":"user_message","message":"  delete the merged branches too  "}}"#,
            #"{"timestamp":"2026-11-17T10:00:04Z","type":"event_msg","payload":{"type":"user_message","message":""}}"#,
        ]
        let data = Data(lines.joined(separator: "\n").utf8)
        #expect(RiskCheck.recentUserMessages(codexSession: data, limit: 6) == ["tidy the repo", "delete the merged branches too"])
        #expect(RiskCheck.recentUserMessages(codexSession: data, limit: 1) == ["delete the merged branches too"])
        #expect(RiskCheck.recentUserMessages(codexSession: data, limit: 0).isEmpty)
    }
}

@Suite struct RiskWordingTests {
    @Test func onlyAutoModeRulesAreCalledTheUsersAutoModeRules() {
        #expect(RiskWording.checking(defaultRules: false) == "Checking against your auto mode rules…")
        #expect(RiskWording.checking(defaultRules: true) == "Checking against stew's default rules…")
        #expect(RiskWording.verdict(.allow, defaultRules: false) == "Auto mode would allow this")
        #expect(RiskWording.verdict(.softDeny, defaultRules: false) == "Auto mode would block this")
        #expect(RiskWording.verdict(.hardDeny, defaultRules: false) == "Auto mode never allows this")
        #expect(RiskWording.verdict(.allow, defaultRules: true) == "stew's check would allow this")
        #expect(RiskWording.verdict(.softDeny, defaultRules: true) == "stew's check would block this")
        #expect(RiskWording.verdict(.hardDeny, defaultRules: true) == "stew's check never allows this")
    }

    @Test func onlyCodexWithoutClaudesRulesExpectsTheDefaults() {
        #expect(RiskCheckBackend.expectsDefaultRules(engines: [.codex, .claude], claudeRulesAvailable: false))
        #expect(!RiskCheckBackend.expectsDefaultRules(engines: [.codex, .claude], claudeRulesAvailable: true))
        #expect(!RiskCheckBackend.expectsDefaultRules(engines: [.claude, .codex], claudeRulesAvailable: false))
        #expect(!RiskCheckBackend.expectsDefaultRules(engines: [], claudeRulesAvailable: false))
    }

    @Test func theFlagTravelsAndOlderVerdictsLeaveItOut() throws {
        let assessment = RiskAssessment(verdict: .softDeny, risk: .high, rule: "Git Destructive", summary: "x", defaultRules: true)
        let encoded = try JSONEncoder().encode(assessment)
        #expect(String(decoding: encoded, as: UTF8.self).contains(#""default_rules":true"#))
        #expect(try JSONDecoder().decode(RiskAssessment.self, from: encoded).usesDefaultRules)
        let older = try JSONDecoder().decode(RiskAssessment.self, from: Data(#"{"verdict":"allow","risk":"low","rule":null,"summary":"x"}"#.utf8))
        #expect(older.defaultRules == nil)
        #expect(!older.usesDefaultRules)
        #expect(!String(decoding: try JSONEncoder().encode(older), as: UTF8.self).contains("default_rules"))
        #expect(!RiskCheck.schema.contains("default_rules"), "the model never sets it")
    }
}

@Suite struct CodexSessionFilesTests {
    private func makeSessions(_ files: [String]) throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stew-sessions-test-\(UUID().uuidString)").path
        for file in files {
            let path = root + "/" + file
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path, contents: Data())
        }
        return root
    }

    private let now = ISO8601DateFormatter().date(from: "2026-11-17T12:00:00Z")!

    @Test func findsARecentSessionInItsDayFolder() throws {
        let root = try makeSessions(["2026/11/16/rollout-2026-11-16T09-00-00-019a.jsonl", "2026/11/16/rollout-2026-11-16T10-00-00-019b.jsonl"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(CodexSessionFiles.file(sessionsFolder: root, sessionID: "019b", now: now) == root + "/2026/11/16/rollout-2026-11-16T10-00-00-019b.jsonl")
    }

    @Test func findsAnOlderSessionAnywhereUnderSessions() throws {
        let root = try makeSessions(["2026/09/02/rollout-2026-09-02T09-00-00-old1.jsonl", "2026/11/17/rollout-2026-11-17T08-00-00-new1.jsonl"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(CodexSessionFiles.file(sessionsFolder: root, sessionID: "old1", now: now) == root + "/2026/09/02/rollout-2026-09-02T09-00-00-old1.jsonl")
        #expect(CodexSessionFiles.file(sessionsFolder: root, sessionID: "missing", now: now) == nil)
        #expect(CodexSessionFiles.file(sessionsFolder: root, sessionID: "", now: now) == nil)
        #expect(CodexSessionFiles.file(sessionsFolder: root + "/nothing-here", sessionID: "old1", now: now) == nil)
    }
}
