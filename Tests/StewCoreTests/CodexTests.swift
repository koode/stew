import Foundation
import Testing
@testable import StewCore

/// Hook input as Codex sends it, after the generated schemas in codex-rs/hooks/schema:
/// every turn-scoped event has `turn_id`, `model` and `permission_mode` besides the
/// fields Claude Code also sends.
private func codexInput(_ event: String, _ fields: [String: Any]) -> Data {
    var object: [String: Any] = [
        "session_id": "019a4c2e-7d1b-7f30-9a52-3c8e1f0b6d47",
        "transcript_path": NSNull(),
        "cwd": "/Users/me/code/web-app",
        "hook_event_name": event,
        "model": "gpt-5.5-codex",
        "permission_mode": "default",
        "turn_id": "turn-7",
    ]
    object.merge(fields) { _, new in new }
    return try! JSONSerialization.data(withJSONObject: object)
}

@Suite struct CodexPermissionRequestTests {
    @Test func bashAsksWithTheCommandAndCodexsReason() throws {
        let call = try HookCall.parse(codexInput("PermissionRequest", [
            "tool_name": "Bash",
            "tool_input": ["command": "pnpm add zod@4", "description": "Install zod; the sandbox has no network."],
        ]))
        #expect(call.event == "PermissionRequest")
        #expect(call.sessionID == "019a4c2e-7d1b-7f30-9a52-3c8e1f0b6d47")
        #expect(call.transcriptPath == nil)
        let permission = PermissionRequest.approval(call, agent: .codex)
        #expect(permission.action == "Run a shell command")
        #expect(permission.command == "pnpm add zod@4")
        #expect(permission.reason == "Install zod; the sandbox has no network.")
        #expect(permission.blocked == nil)
    }

    @Test func applyPatchNamesTheFilesAndSaysWhenCodexGaveNoReason() throws {
        let patch = """
        *** Begin Patch
        *** Update File: src/auth/session.ts
        @@
        -const ttl = 3600
        +const ttl = 900
        *** Add File: src/auth/refresh.ts
        +export const refresh = () => {}
        *** End Patch
        """
        let call = try HookCall.parse(codexInput("PermissionRequest", ["tool_name": "apply_patch", "tool_input": ["command": patch]]))
        let permission = PermissionRequest.approval(call, agent: .codex)
        #expect(permission.action == "Edit src/auth/session.ts and src/auth/refresh.ts")
        #expect(permission.command == patch)
        #expect(permission.reason == "Codex did not say why.")
    }

    @Test func patchActionCountsTheFiles() {
        #expect(PermissionRequest.patchAction("no headers") == "Edit files")
        #expect(PermissionRequest.patchAction("*** Delete File: old.txt") == "Edit old.txt")
        let many = ["a", "b", "c", "a"].map { "*** Update File: \($0).swift" }.joined(separator: "\n")
        #expect(PermissionRequest.patchAction(many) == "Edit a.swift and 2 more files")
    }

    @Test func mcpToolNamesTheServerAndShowsTheArguments() throws {
        let call = try HookCall.parse(codexInput("PermissionRequest", [
            "tool_name": "mcp__github__create_issue",
            "tool_input": ["title": "Flaky test", "body": "Fails one run in ten", "description": NSNull()],
        ]))
        let permission = PermissionRequest.approval(call, agent: .codex)
        #expect(permission.action == "Use create_issue from the github MCP server")
        #expect(permission.command == #"mcp__github__create_issue: {"body":"Fails one run in ten","description":null,"title":"Flaky test"}"#)
        #expect(permission.reason == "Codex did not say why.")
    }

    @Test func malformedInputIsRefused() {
        #expect(throws: (any Error).self) { try HookCall.parse(Data("not json".utf8)) }
        #expect(throws: HookCall.ParseError.self) { try HookCall.parse(Data("[1, 2]".utf8)) }
        #expect(throws: HookCall.ParseError.self) { try HookCall.parse(codexInput("PermissionRequest", ["tool_input": ["command": "ls"]])) }
    }

    @Test func approvalAllowsAndDenialCarriesTheMessage() throws {
        #expect(HookOutput.permissionRequest(allow: true) == #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)
        #expect(HookOutput.permissionRequest(allow: false, message: "The user denied this in stew: use the catalog version")
            == #"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"The user denied this in stew: use the catalog version"},"hookEventName":"PermissionRequest"}}"#)
        let denial = HookOutput.permissionRequest(allow: false)
        #expect(denial.contains(#""message":"The user denied this in stew.""#))
        for output in [HookOutput.permissionRequest(allow: true), denial] {
            for reserved in ["updatedInput", "updatedPermissions", "interrupt", "continue", "stopReason", "suppressOutput"] {
                #expect(!output.contains(reserved), "\(reserved) fails closed in Codex")
            }
        }
    }
}

@Suite struct CodexTurnHookTests {
    @Test func stopWithANeedsLineBecomesAnItemNamedForCodex() throws {
        let input = try #require(TurnHookInput.parse(codexInput("Stop", [
            "stop_hook_active": false,
            "last_assistant_message": "The deploy is ready.\n\nneeds input: sign in to the staging dashboard\n1. Open https://staging.example.com/login",
        ])))
        #expect(input.sessionID == "019a4c2e-7d1b-7f30-9a52-3c8e1f0b6d47")
        let message = try #require(input.lastAssistantMessage)
        let needs = try #require(NeedsParser.parse(message, agent: .codex))
        #expect(needs.title == "sign in to the staging dashboard")
        #expect(needs.links.map(\.url) == ["https://staging.example.com/login"])
        #expect(NeedsParser.parse("needs input:", agent: .codex)?.title == "Codex needs your input")
        #expect(NeedsParser.parse("needs input:")?.title == "Claude needs your input")
    }

    @Test func stopWithoutAMessageHasNothingToRead() throws {
        let input = try #require(TurnHookInput.parse(codexInput("Stop", ["stop_hook_active": true, "last_assistant_message": NSNull()])))
        #expect(input.lastAssistantMessage == nil)
        #expect(TurnHookInput.parse(Data("{".utf8)) == nil)
    }

    @Test func userPromptSubmitCarriesTheSessionAndSubagent() throws {
        let input = try #require(TurnHookInput.parse(codexInput("UserPromptSubmit", ["prompt": "go on", "agent_id": "agent-2", "agent_type": "explorer"])))
        #expect(input.sessionID == "019a4c2e-7d1b-7f30-9a52-3c8e1f0b6d47")
        #expect(input.agentID == "agent-2")
    }

    @Test func stopOutputIsAlwaysJSON() throws {
        #expect(try JSONSerialization.jsonObject(with: Data(HookOutput.noDecision.utf8)) is [String: Any])
        let block = try #require(try JSONSerialization.jsonObject(with: Data(HookOutput.blockStop(reason: "Late answer").utf8)) as? [String: String])
        #expect(block == ["decision": "block", "reason": "Late answer"])
    }
}

@Suite struct CodexHookFileTests {
    let stew = "/u/.local/bin/stew"
    var codexHooks: [StewHook] { CodingAgent.codex.stewHooks(waitTimeout: 1800) }

    private func events(_ data: Data) throws -> [String: [[String: Any]]] {
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["hooks"] as? [String: [[String: Any]]])
    }

    @Test func freshFileGetsTheFourHooks() throws {
        let data = try HookFile.installing(codexHooks, executable: stew, into: nil)
        let hooks = try events(data)
        #expect(Set(hooks.keys) == ["PermissionRequest", "Stop", "UserPromptSubmit"])
        let permission = try #require((hooks["PermissionRequest"]?.first?["hooks"] as? [[String: Any]])?.first)
        #expect(permission["command"] as? String == "/u/.local/bin/stew hook permission --agent codex")
        #expect(permission["timeout"] as? Int == 1800)
        #expect(permission["type"] as? String == "command")
        #expect(permission["statusMessage"] as? String == "Asking in stew")
        #expect(permission["async"] == nil)
        #expect(permission["onFailure"] == nil)
        #expect(hooks["PermissionRequest"]?.first?["matcher"] as? String == "*")
        let stops = try #require(hooks["Stop"]).compactMap { ($0["hooks"] as? [[String: Any]])?.first }
        #expect(stops.map { $0["command"] as? String } == ["/u/.local/bin/stew hook stop --agent codex", "/u/.local/bin/stew hook stop-late --agent codex"])
        #expect(stops.map { $0["async"] as? Bool } == [true, nil])
        #expect(hooks["Stop"]?.allSatisfy { $0["matcher"] == nil } == true)
        #expect(HookFile.state(of: codexHooks, executable: stew, in: data) == .complete)
        #expect(String(decoding: data, as: UTF8.self).hasSuffix("}\n"))
    }

    @Test func userHooksStayAndInstallingTwiceChangesNothing() throws {
        let existing = Data(#"""
        {"description": "My hooks", "hooks": {
          "PermissionRequest": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "python3 ~/.codex/hooks/policy.py"}]}],
          "SessionStart": [{"matcher": "startup", "hooks": [{"type": "command", "command": "echo hi"}]}]
        }}
        """#.utf8)
        let once = try HookFile.installing(codexHooks, executable: stew, into: existing)
        let twice = try HookFile.installing(codexHooks, executable: stew, into: once)
        #expect(once == twice)
        let object = try #require(try JSONSerialization.jsonObject(with: once) as? [String: Any])
        #expect(object["description"] as? String == "My hooks")
        let hooks = try events(once)
        #expect(hooks["PermissionRequest"]?.count == 2)
        #expect(hooks["PermissionRequest"]?.first?["matcher"] as? String == "Bash")
        #expect(hooks["SessionStart"]?.count == 1)

        let removed = try #require(try HookFile.removing(events: ["PermissionRequest", "Stop", "UserPromptSubmit"], executable: stew, from: twice))
        let left = try events(removed)
        #expect(Set(left.keys) == ["PermissionRequest", "SessionStart"])
        #expect((left["PermissionRequest"]?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String == "python3 ~/.codex/hooks/policy.py")
        #expect(HookFile.state(of: codexHooks, executable: stew, in: removed) == .none)
    }

    @Test func uninstallWithoutStewHooksLeavesTheFileAlone() throws {
        let untouched = Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#.utf8)
        #expect(try HookFile.removing(events: ["Stop"], executable: stew, from: untouched) == nil)
        #expect(try HookFile.removing(events: ["Stop"], executable: stew, from: nil) == nil)
        let onlyStew = try HookFile.installing(codexHooks, executable: stew, into: nil)
        let empty = try #require(try HookFile.removing(events: ["PermissionRequest", "Stop", "UserPromptSubmit"], executable: stew, from: onlyStew))
        #expect(String(decoding: empty, as: UTF8.self) == "{\n\n}\n")
    }

    @Test func aMissingHookReadsAsPartial() throws {
        let installed = try HookFile.installing(codexHooks, executable: stew, into: nil)
        let withoutLate = try HookFile.installing(codexHooks.filter { $0.arguments != "stop-late --agent codex" }, executable: stew, into: nil)
        #expect(HookFile.state(of: codexHooks, executable: stew, in: withoutLate) == .partial)
        #expect(HookFile.state(of: codexHooks, executable: "/elsewhere/stew", in: installed) == .none)
        #expect(throws: HookFile.EditError.self) { try HookFile.installing(codexHooks, executable: stew, into: Data("[]".utf8)) }
    }

    @Test func claudeAndCodexHooksDoNotCountForEachOther() throws {
        let claude = try ClaudeSettings.installingHooks(executable: stew, deniedTimeout: 1800, into: nil)
        #expect(HookFile.state(of: codexHooks, executable: stew, in: claude) == .none)
        let codex = try HookFile.installing(codexHooks, executable: stew, into: nil)
        #expect(ClaudeSettings.hookState(executable: stew, in: codex) == .none)
    }
}

@Suite struct CodexConfigTests {
    @Test func hooksTurnedOffInFeatures() {
        #expect(CodexConfig.hooksDisabled(toml: "[features]\nhooks = false\n"))
        #expect(CodexConfig.hooksDisabled(toml: "model = \"gpt-5.5\"\n[features]\ncodex_hooks = false # old name\n"))
        #expect(CodexConfig.hooksDisabled(toml: "features.hooks = false\n"))
        #expect(!CodexConfig.hooksDisabled(toml: "[features]\nhooks = true\n"))
        #expect(!CodexConfig.hooksDisabled(toml: "[features]\n# hooks = false\n"))
        #expect(!CodexConfig.hooksDisabled(toml: "[profiles.work]\nhooks = false\n"))
        #expect(!CodexConfig.hooksDisabled(toml: ""))
    }

    @Test func inlineHooksButNotTheTrustRecords() {
        #expect(CodexConfig.hasInlineHooks(toml: "[[hooks.PreToolUse]]\nmatcher = \"^Bash$\"\n"))
        #expect(CodexConfig.hasInlineHooks(toml: "[hooks]\nStop = [{ hooks = [{ type = \"command\", command = \"x\" }] }]\n"))
        #expect(!CodexConfig.hasInlineHooks(toml: "[hooks.state.\"user:hooks.json:Stop:0:0\"]\ntrusted_hash = \"abc\"\n"))
        #expect(!CodexConfig.hasInlineHooks(toml: "[features]\nhooks = true\n# [[hooks.Stop]]\n"))
    }
}
