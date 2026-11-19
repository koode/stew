import Foundation
import Testing
@testable import StewCore

struct TranscriptWatchTests {
    private let command = #"R=/tmp/x; for dir in a b; do rmdir "$R/$dir"; done"#
    private var key: String { TranscriptWatch.key(of: ["command": command, "description": "Remove a and b"])! }

    private func use(_ id: String, _ toolName: String = "Bash", command: String? = nil) -> Substring {
        let input: [String: Any] = ["command": command ?? self.command, "description": "Remove a and b"]
        let line: [String: Any] = ["type": "assistant", "message": ["role": "assistant", "content": [["type": "tool_use", "id": id, "name": toolName, "input": input]]]]
        return Substring(String(decoding: try! JSONSerialization.data(withJSONObject: line), as: UTF8.self))
    }

    private func result(_ id: String) -> Substring {
        let line: [String: Any] = ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "is_error": true, "content": "The user doesn't want to proceed with this tool use."]]]]
        return Substring(String(decoding: try! JSONSerialization.data(withJSONObject: line), as: UTF8.self))
    }

    @Test func theCallsResultSettlesIt() {
        var watch = TranscriptWatch(toolName: "Bash", key: key)
        let settled1 = watch.read([use("toolu_1")])
        #expect(!settled1)
        watch.follow()
        let settled2 = watch.read([])
        #expect(!settled2)
        let settled3 = watch.read([result("toolu_1")])
        #expect(settled3)
    }

    @Test func theCallCanReachTheTranscriptAfterTheHookStarts() {
        var watch = TranscriptWatch(toolName: "Bash", key: key)
        watch.follow()
        let settled4 = watch.read([use("toolu_1")])
        #expect(!settled4)
        let settled5 = watch.read([result("toolu_1")])
        #expect(settled5)
    }

    @Test func anEarlierIdenticalCallWithItsResultDoesNotCount() {
        var watch = TranscriptWatch(toolName: "Bash", key: key)
        let settled6 = watch.read([use("toolu_old"), result("toolu_old"), use("toolu_new")])
        #expect(!settled6)
        watch.follow()
        let settled7 = watch.read([result("toolu_old")])
        #expect(!settled7)
        let settled8 = watch.read([result("toolu_new")])
        #expect(settled8)
    }

    @Test func otherCallsDoNotSettleIt() {
        var watch = TranscriptWatch(toolName: "Bash", key: key)
        watch.follow()
        let settled9 = watch.read([use("toolu_ls", command: "ls"), result("toolu_ls")])
        #expect(!settled9)
        let settled10 = watch.read([use("toolu_monitor", "Monitor"), result("toolu_monitor")])
        #expect(!settled10)
        let settled11 = watch.read(["not json", "{\"tool_result\": 1}", result("toolu_unknown")])
        #expect(!settled11)
    }

    @Test func aSubagentsCallsAreInItsOwnTranscript() {
        let session = "/u/.claude/projects/p/c776.jsonl"
        #expect(TranscriptWatch.path(transcriptPath: session, agentID: nil) == session)
        #expect(TranscriptWatch.path(transcriptPath: session, agentID: "a083") == "/u/.claude/projects/p/c776/subagents/agent-a083.jsonl")
    }

    @Test func linesWaitForTheirNewline() {
        var follower = LineFollower()
        let lines12 = follower.lines(in: Data("{\"a\":1}\n{\"b\"".utf8))
        #expect(lines12 == ["{\"a\":1}"])
        let lines13 = follower.lines(in: Data(":2}".utf8))
        #expect(lines13.isEmpty)
        let lines14 = follower.lines(in: Data("\n\n{\"c\":3}\n".utf8))
        #expect(lines14 == ["{\"b\":2}", "{\"c\":3}"])
    }

    @Test func shellCallsInAutoModeStopBeforeClaudeCodesCountdown() {
        #expect(PermissionRequest.claudeTimeLimit(toolName: "Bash", permissionMode: "auto", hookLimit: 1780) == 115)
        #expect(PermissionRequest.claudeTimeLimit(toolName: "Monitor", permissionMode: "bypassPermissions", hookLimit: 1780) == 115)
        #expect(PermissionRequest.claudeTimeLimit(toolName: "Bash", permissionMode: "default", hookLimit: 1780) == 1780)
        #expect(PermissionRequest.claudeTimeLimit(toolName: "Write", permissionMode: "auto", hookLimit: 1780) == 1780)
        #expect(PermissionRequest.claudeTimeLimit(toolName: "Bash", permissionMode: nil, hookLimit: 1780) == 1780)
    }

    @Test func theHookInputGivesThePermissionModeAndTheCallKey() throws {
        let input = #"{"session_id":"c776","transcript_path":"/t.jsonl","cwd":"/p","permission_mode":"auto","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"description":"Remove a and b","command":"R=/tmp/x; for dir in a b; do rmdir \"$R/$dir\"; done"},"permission_suggestions":[]}"#
        let call = try HookCall.parse(Data(input.utf8))
        #expect(call.permissionMode == "auto")
        #expect(call.key == key)
        #expect(call.blockedAction == "Remove a and b")
        #expect(call.blockedCommand == command)
    }

    @Test func claudeCodeAsksInStewForItsOwnPrompts() throws {
        let hook = try #require(CodingAgent.claudeCode.stewHooks(waitTimeout: 1800).first { $0.event == "PermissionRequest" })
        #expect(hook.matcher == "*")
        #expect(hook.arguments == "permission")
        #expect(hook.timeout == 1800)
        #expect(hook.onFailure == "continue")
    }
}
