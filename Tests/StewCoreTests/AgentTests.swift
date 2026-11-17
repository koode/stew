import Foundation
import Testing
@testable import StewCore

@Suite struct CodingAgentTests {
    @Test func detectsTheAgentFromItsShellVariables() {
        #expect(CodingAgent.detect(environment: [:]) == nil)
        #expect(CodingAgent.detect(environment: ["CLAUDECODE": "1"]) == .claudeCode)
        #expect(CodingAgent.detect(environment: ["CODEX_THREAD_ID": "019a"]) == .codex)
        #expect(CodingAgent.detect(environment: ["CODEX_SESSION_ID": "019a", "CLAUDE_CODE_SESSION_ID": "5b0e"]) == .claudeCode)
        #expect(CodingAgent.detect(environment: ["CODEX_SESSION_ID": "  "]) == nil)
        #expect(CodingAgent.parse("Codex") == .codex)
        #expect(CodingAgent.parse("claude") == .claudeCode)
        #expect(CodingAgent.parse("gemini") == nil)
    }

    @Test func aCodexShellGivesTheRootSessionID() {
        let session = SessionResolver.resolve(
            explicitName: nil, environment: ["CODEX_SESSION_ID": "root-1", "CODEX_THREAD_ID": "thread-2"],
            cwd: "/Users/me/app", home: "/Users/me"
        ) { _ in nil }
        #expect(session.agent == .codex)
        #expect(session.id == "root-1")
        #expect(SessionResolver.resolve(explicitName: nil, environment: ["CODEX_THREAD_ID": "thread-2"], cwd: "/", home: "/Users/me") { _ in nil }.id == "thread-2")
        let claude = SessionResolver.resolve(explicitName: nil, environment: ["CLAUDE_CODE_SESSION_ID": "5b0e"], cwd: "/", home: "/Users/me") { _ in nil }
        #expect(claude.agent == .claudeCode)
        #expect(claude.id == "5b0e")
    }

    @Test func theAgentTravelsAndOlderOrNewerValuesStillDecode() throws {
        let codex = SessionInfo(name: "web-app", id: "019a", cwd: "~/code/web-app", agent: .codex)
        let encoded = try JSONEncoder().encode(codex)
        #expect(String(decoding: encoded, as: UTF8.self).contains(#""agent":"codex""#))
        #expect(try JSONDecoder().decode(SessionInfo.self, from: encoded) == codex)
        let older = try JSONDecoder().decode(SessionInfo.self, from: Data(#"{"name":"app","id":"5b0e"}"#.utf8))
        #expect(older.agent == nil)
        #expect(older.codingAgent == .claudeCode)
        let newer = try JSONDecoder().decode(SessionInfo.self, from: Data(#"{"name":"app","agent":"someday"}"#.utf8))
        #expect(newer.agent == nil)
        #expect(!String(decoding: try JSONEncoder().encode(older), as: UTF8.self).contains("agent"))
    }

    @Test func aCodexApprovalThatTimedOutIsNotAnsweredLate() {
        let session = SessionInfo(name: "web-app", id: "019a", agent: .codex)
        let approval = StewRequest(session: session, prompt: .permission(PermissionRequest(action: "Run a shell command", reason: "x")), origin: RequestOrigin(agentAsksOnTimeout: true))
        #expect(!LateMailbox.canAnswerLate(approval))
        #expect(!approval.timeoutNote(after: 60).contains("late answer"))
        let permit = StewRequest(session: session, prompt: .permission(PermissionRequest(action: "Push", reason: "x")))
        #expect(LateMailbox.canAnswerLate(permit))
    }

    @Test func historyNamesTheAgentThatAsked() {
        let codexRequest = StewRequest(session: SessionInfo(name: "web-app", id: "019a", agent: .codex), prompt: .needs(NeedsRequest(title: "Sign in")), wait: false)
        let entry = HistoryEntry(
            received: Date(), ended: Date(), session: "web-app", cwd: nil, kind: "needs", summary: "Sign in",
            command: nil, detail: nil, outcome: .resolvedByClaude, request: codexRequest
        )
        #expect(entry.outcomeLabel == "Resolved by Codex")
        #expect(entry.outcomeLine { _ in "now" } == "Resolved by Codex now")
        var older = entry
        older.request = nil
        #expect(older.outcomeLabel == "Resolved by Claude")
    }
}
