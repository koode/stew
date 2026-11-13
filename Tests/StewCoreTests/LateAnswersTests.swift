import Foundation
import Testing
@testable import StewCore

private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let session = SessionInfo(name: "deploy job", id: "s1", cwd: "/work/app")

private func cliPermission(_ command: String = "deploy --token ghp_abcdefghijklmnopqrstuvwxyz0123456789", session: SessionInfo = session) -> StewRequest { // gitleaks:allow (test fixture)
    StewRequest(session: session, prompt: .permission(PermissionRequest(action: "Deploy", command: command, reason: "release day")))
}

private func blockedPermission(agentID: String? = nil) -> StewRequest {
    let blocked = BlockedCall(toolName: "Bash", category: "Destructive or Unwanted Actions", reason: "[Destructive or Unwanted Actions]", hardDeny: false, projectRoot: "/work/app", suggestions: [])
    return StewRequest(
        session: session,
        prompt: .permission(PermissionRequest(action: "Push", command: "git push --force origin main", reason: "rebased", blocked: blocked)),
        origin: RequestOrigin(agentID: agentID, toolName: "Bash", callKey: #"{"command":"git push --force origin main"}"#)
    )
}

private let questionSet = QuestionSet(questions: [
    Question(question: "Which database?", header: "DB", options: [QuestionOption(label: "Postgres", description: ""), QuestionOption(label: "SQLite", description: "")]),
    Question(question: "Add caching?", header: "Cache", options: [QuestionOption(label: "Yes", description: ""), QuestionOption(label: "No", description: "")]),
])

private func question(session: SessionInfo = session) -> StewRequest {
    StewRequest(session: session, prompt: .question(questionSet))
}

@Suite struct LateMailboxTests {
    @Test func storesAnAnswerAndDeliversItOnce() throws {
        var mailbox = LateMailbox()
        let entryID = UUID()
        mailbox.addWaiting(cliPermission(), entryID: entryID, now: start)
        #expect(mailbox.waiting(entryID, now: start) != nil)
        let answered = mailbox.answer(entryID, with: StewResponse(status: .approved), now: start.addingTimeInterval(60))
        let late = try #require(answered)
        #expect(late.sessionID == "s1")
        #expect(mailbox.waiting(entryID, now: start) == nil)
        #expect(mailbox.answer(entryID, with: StewResponse(status: .approved), now: start) == nil)

        #expect(mailbox.hasMail(sessionID: "s1", agentID: nil, now: start.addingTimeInterval(120)))
        let first = mailbox.deliver(sessionID: "s1", agentID: nil, event: "PreToolUse", now: start.addingTimeInterval(120))
        #expect(first.map(\.entryID) == [entryID])
        #expect(first.first?.deliveredBy == "PreToolUse")
        #expect(mailbox.deliver(sessionID: "s1", agentID: nil, event: "Stop", now: start.addingTimeInterval(180)).isEmpty)
        #expect(!mailbox.hasMail(sessionID: "s1", agentID: nil, now: start.addingTimeInterval(180)))
        // Kept, marked delivered, for the history.
        #expect(mailbox.answer(entryID)?.delivered == start.addingTimeInterval(120))
    }

    @Test func closingThePanelIsNoAnswer() {
        var mailbox = LateMailbox()
        let entryID = UUID()
        mailbox.addWaiting(cliPermission(), entryID: entryID, now: start)
        #expect(mailbox.answer(entryID, with: StewResponse(status: .dismissed), now: start) == nil)
        #expect(mailbox.waiting(entryID, now: start) != nil)
        #expect(mailbox.answers.isEmpty)
    }

    @Test func dropsWaitingRequestsAndUndeliveredAnswersAfterADay() {
        var mailbox = LateMailbox()
        let oldID = UUID(), freshID = UUID()
        mailbox.addWaiting(cliPermission(), entryID: oldID, now: start)
        mailbox.addWaiting(question(), entryID: freshID, now: start.addingTimeInterval(3600))
        let dayLater = start.addingTimeInterval(LateMailbox.lifetime)
        #expect(mailbox.waiting(oldID, now: dayLater) == nil)
        #expect(mailbox.answer(oldID, with: StewResponse(status: .approved), now: dayLater) == nil)
        #expect(mailbox.waiting.map(\.entryID) == [freshID])

        mailbox.answer(freshID, with: StewResponse(status: .answered, answers: ["Which database?": "Postgres"]), now: dayLater)
        #expect(mailbox.hasMail(sessionID: "s1", agentID: nil, now: dayLater.addingTimeInterval(LateMailbox.lifetime - 1)))
        #expect(!mailbox.hasMail(sessionID: "s1", agentID: nil, now: dayLater.addingTimeInterval(LateMailbox.lifetime)))
        #expect(mailbox.deliver(sessionID: "s1", agentID: nil, event: "Stop", now: dayLater.addingTimeInterval(LateMailbox.lifetime)).isEmpty)
        #expect(mailbox.isEmpty)
    }

    @Test func neverDeliversToAnotherSession() {
        var mailbox = LateMailbox()
        let mine = UUID(), theirs = UUID()
        mailbox.addWaiting(cliPermission(), entryID: mine, now: start)
        mailbox.addWaiting(cliPermission(session: SessionInfo(name: "other", id: "s2")), entryID: theirs, now: start)
        mailbox.answer(mine, with: StewResponse(status: .denied), now: start)
        mailbox.answer(theirs, with: StewResponse(status: .approved), now: start)
        #expect(mailbox.deliver(sessionID: "s3", agentID: nil, event: "Stop", now: start).isEmpty)
        #expect(mailbox.deliver(sessionID: nil, agentID: nil, event: "Stop", now: start).isEmpty)
        #expect(mailbox.deliver(sessionID: "", agentID: nil, event: "Stop", now: start).isEmpty)
        #expect(mailbox.deliver(sessionID: "s2", agentID: nil, event: "Stop", now: start).map(\.entryID) == [theirs])
        #expect(mailbox.deliver(sessionID: "s1", agentID: nil, event: "Stop", now: start).map(\.entryID) == [mine])
    }

    @Test func aSubagentGetsOnlyItsOwnAnswersAndTheMainAgentGetsAll() {
        var mailbox = LateMailbox()
        let fromSubagent = UUID(), fromMain = UUID()
        mailbox.addWaiting(blockedPermission(agentID: "agent-7"), entryID: fromSubagent, now: start)
        mailbox.addWaiting(question(), entryID: fromMain, now: start)
        mailbox.answer(fromSubagent, with: StewResponse(status: .approved), now: start)
        mailbox.answer(fromMain, with: StewResponse(status: .answered, answers: ["Which database?": "SQLite"]), now: start.addingTimeInterval(1))
        #expect(mailbox.deliver(sessionID: "s1", agentID: "agent-9", event: "PreToolUse", now: start).isEmpty)
        #expect(mailbox.deliver(sessionID: "s1", agentID: "agent-7", event: "PreToolUse", now: start).map(\.entryID) == [fromSubagent])
        #expect(mailbox.deliver(sessionID: "s1", agentID: nil, event: "Stop", now: start).map(\.entryID) == [fromMain])
    }

    @Test func deliversOldestFirst() {
        var mailbox = LateMailbox()
        let first = UUID(), second = UUID()
        mailbox.addWaiting(cliPermission(), entryID: second, now: start)
        mailbox.addWaiting(question(), entryID: first, now: start)
        mailbox.answer(first, with: StewResponse(status: .answered, answers: ["Which database?": "SQLite"]), now: start)
        mailbox.answer(second, with: StewResponse(status: .denied), now: start.addingTimeInterval(5))
        #expect(mailbox.deliver(sessionID: "s1", agentID: nil, event: "Stop", now: start.addingTimeInterval(10)).map(\.entryID) == [first, second])
    }

    @Test func onlyPermissionsAndQuestionsOfAKnownSessionWait() {
        var mailbox = LateMailbox()
        mailbox.addWaiting(cliPermission(session: SessionInfo(name: "shell")), entryID: UUID(), now: start)
        mailbox.addWaiting(cliPermission(session: SessionInfo(name: "shell", id: "")), entryID: UUID(), now: start)
        mailbox.addWaiting(StewRequest(session: session, prompt: .notify(NotifyRequest(title: "t"))), entryID: UUID(), now: start)
        #expect(mailbox.waiting.isEmpty)
    }

    @Test func roundTripsThroughJSON() throws {
        var mailbox = LateMailbox()
        let entryID = UUID()
        mailbox.addWaiting(blockedPermission(), entryID: entryID, now: start)
        mailbox.addWaiting(question(), entryID: UUID(), now: start)
        mailbox.answer(entryID, with: StewResponse(status: .approved), now: start)
        #expect(LateMailbox.decode(try LateMailbox.encode(mailbox)) == mailbox)
        #expect(LateMailbox.decode(Data("not json".utf8)) == LateMailbox())
    }
}

@Suite struct LateWordingTests {
    @Test func masksSecretsInWhatClaudeReads() throws {
        let message = try #require(LateWording.message(for: cliPermission(), response: StewResponse(status: .approved)))
        #expect(message.contains("deploy --token ••••"))
        #expect(!message.contains("ghp_"))
    }

    @Test func approvedBlockedCallSaysRetry() throws {
        let message = try #require(LateWording.message(for: blockedPermission(), response: StewResponse(status: .approved)))
        #expect(message.hasPrefix("Late answer from the user, through stew."))
        #expect(message.contains("approved it: Push (`git push --force origin main`)"))
        #expect(message.contains("retry it if it is still needed"))
    }

    @Test func approvedCLIRequestSaysItMayRun() throws {
        let message = try #require(LateWording.message(for: cliPermission("make release"), response: StewResponse(status: .approved, note: "go ahead")))
        #expect(message.contains("approved it: Deploy (`make release`). You may run it now if it is still relevant."))
        #expect(message.hasSuffix("Their note: go ahead"))
    }

    @Test func deniedCarriesTheNote() throws {
        let message = try #require(LateWording.message(for: cliPermission("make release"), response: StewResponse(status: .denied, note: "not on a Friday")))
        #expect(message.contains("declined it: Deploy (`make release`). Do not run it."))
        #expect(message.hasSuffix("Their note: not on a Friday"))
    }

    @Test func questionAnswersUseTheQuestionAndAnswerPairs() throws {
        let response = StewResponse(status: .answered, answers: ["Which database?": "Postgres", "Add caching?": "Only for reads"])
        let message = try #require(LateWording.message(for: question(), response: response))
        #expect(message.contains(#""Which database?"="Postgres", "Add caching?"="Only for reads""#))
        #expect(message.contains("replace the timeout"))
    }

    @Test func noMessageForWhatIsNotAnAnswer() {
        #expect(LateWording.message(for: question(), response: StewResponse(status: .answered, answers: [:])) == nil)
        #expect(LateWording.message(for: cliPermission(), response: StewResponse(status: .timeout)) == nil)
        #expect(LateWording.combined([]) == nil)
    }

    @Test func noEmDashesForClaude() {
        let messages = [
            LateWording.message(for: blockedPermission(), response: StewResponse(status: .approved)),
            LateWording.message(for: cliPermission(), response: StewResponse(status: .denied, note: "n")),
            LateWording.message(for: question(), response: StewResponse(status: .answered, answers: ["Which database?": "Postgres"])),
        ]
        #expect(messages.allSatisfy { $0 != nil && !$0!.contains("\u{2014}") })
    }

    @Test func timeoutNoteMentionsLateAnswersOnlyWhenOneCanArrive() {
        #expect(cliPermission().timeoutNote(after: 60).contains("late answer, which replaces this timeout"))
        #expect(question().timeoutNote(after: 60).contains("late answer"))
        #expect(!cliPermission(session: SessionInfo(name: "shell")).timeoutNote(after: 60).contains("late answer"))
    }
}

@Suite struct LateHookOutputTests {
    private func object(_ text: String?) throws -> [String: Any] {
        let json = try #require(text)
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        return try #require(parsed)
    }

    @Test func preToolUseCarriesTheAnswerAsAdditionalContext() {
        let output = HookOutput.preToolUse(nil, additionalContext: "Late answer")
        #expect(output == #"{"hookSpecificOutput":{"additionalContext":"Late answer","hookEventName":"PreToolUse"}}"#)
    }

    @Test func preToolUseCombinesAGrantDecisionAndTheAnswer() throws {
        let specific = try object(HookOutput.preToolUse(.allow, additionalContext: "Late answer"))["hookSpecificOutput"] as? [String: Any]
        #expect(specific?["permissionDecision"] as? String == "allow")
        #expect(specific?["additionalContext"] as? String == "Late answer")
    }

    @Test func preToolUsePrintsNothingWithoutEither() {
        #expect(HookOutput.preToolUse(nil, additionalContext: nil) == nil)
        #expect(HookOutput.preToolUse(.deny(note: "n")).contains(#""permissionDecision":"deny""#))
    }

    @Test func promptAndStopShapes() {
        #expect(HookOutput.promptContext("Late answer") == #"{"hookSpecificOutput":{"additionalContext":"Late answer","hookEventName":"UserPromptSubmit"}}"#)
        #expect(HookOutput.blockStop(reason: "Late answer") == #"{"decision":"block","reason":"Late answer"}"#)
    }

    @Test func hookInputsCarryTheAgentID() throws {
        let call = try HookCall.parse(Data(#"{"session_id":"s1","agent_id":"agent-7","tool_name":"Bash","tool_input":{"command":"ls"}}"#.utf8))
        #expect(call.agentID == "agent-7")
        #expect(try HookCall.parse(Data(#"{"session_id":"s1","tool_name":"Bash","tool_input":{}}"#.utf8)).agentID == nil)
        #expect(TurnHookInput.parse(Data(#"{"session_id":"s1","agent_id":"agent-7"}"#.utf8))?.agentID == "agent-7")
        #expect(TurnHookInput.parse(Data(#"{"session_id":"s1"}"#.utf8))?.agentID == nil)
    }
}

@Suite struct LateGrantTests {
    private let call = HookCall(event: "PreToolUse", sessionID: "s1", cwd: "/p", toolName: "Bash", key: #"{"command":"git push --force origin main"}"#, command: "git push --force origin main", description: nil, summary: "", reason: nil)

    @Test func lateApprovalReplacesTheTimeoutNoteAndLetsOneRetryThrough() {
        var grants = [GrantBook.denyNote(for: call, note: "The user didn't respond within 1 min.", now: start)]
        GrantBook.approveLate(grants: &grants, toolName: "Bash", callKey: call.key, sessionID: "s1", now: start.addingTimeInterval(600))
        #expect(grants.count == 1)
        // Hours later, when Claude finally retries, the grant still holds.
        let later = start.addingTimeInterval(6 * 3600)
        #expect(GrantBook.preToolUse(grants: &grants, call: call, projectRoot: { "/p" }, now: later) == .allow)
        #expect(GrantBook.preToolUse(grants: &grants, call: call, projectRoot: { "/p" }, now: later) == nil)
    }

    @Test func lateApprovalIsForThatSessionOnly() {
        var grants: [Grant] = []
        GrantBook.approveLate(grants: &grants, toolName: "Bash", callKey: call.key, sessionID: "s2", now: start)
        #expect(GrantBook.preToolUse(grants: &grants, call: call, projectRoot: { "/p" }, now: start) == nil)
    }
}

@Suite struct LateHistoryTests {
    @Test func theHistoryNeverKeepsTheRawCallKey() throws {
        let entry = HistoryEntry.record(blockedPermission(), received: start, response: StewResponse(status: .timeout, note: "n"), ended: start)
        let line = String(decoding: try History.line(entry), as: UTF8.self)
        #expect(!line.contains("callKey"))
    }

    @Test func aLateAnswerShowsAsItsOwnOutcome() throws {
        var entry = HistoryEntry.record(question(), received: start, response: StewResponse(status: .timeout, note: "n"), ended: start)
        #expect(entry.outcomeLabel == "Timed out")
        entry.recordLate(StewResponse(status: .answered, answers: ["Which database?": "Postgres"]), message: "Late answer", at: start.addingTimeInterval(60))
        #expect(entry.outcomeLabel == "Answered late")
        #expect(entry.late?.answers == ["Which database?": "Postgres"])
        #expect(entry.missed)
        let reparsed = History.parse(try History.line(entry))
        #expect(reparsed == [entry])
    }

    @Test func theOriginTravelsOverTheSocket() throws {
        let request = blockedPermission(agentID: "agent-7")
        let decoded = try Wire.decode(StewRequest.self, line: try Wire.encode(request))
        #expect(decoded.origin == request.origin)
    }
}

@Suite struct LateHookInstallTests {
    private func stopHandlers(_ data: Data) throws -> [[String: Any]] {
        let hooks = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["hooks"] as! [String: Any]
        return (hooks["Stop"] as! [[String: Any]]).flatMap { $0["hooks"] as! [[String: Any]] }
    }

    @Test func theLateAnswerStopHookRunsInTheForeground() throws {
        let installed = try ClaudeSettings.installingHooks(executable: "/u/stew", deniedTimeout: 1800, into: nil)
        let late = try #require(try stopHandlers(installed).first { $0["command"] as? String == "/u/stew hook stop-late" })
        #expect(late["async"] == nil)
        #expect(late["timeout"] as? Int == 5)
    }

    @Test func anInstallWithoutTheLateAnswerStopHookNeedsUpdating() throws {
        let previous = Data(#"""
        {"hooks":{"PermissionDenied":[{"matcher":"*","hooks":[{"type":"command","command":"/u/stew hook denied"}]}],
        "PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"/u/stew hook pre"}]},
        {"matcher":"AskUserQuestion","hooks":[{"type":"command","command":"/u/stew hook question"}]}],
        "Stop":[{"hooks":[{"type":"command","command":"/u/stew hook stop","async":true}]}],
        "UserPromptSubmit":[{"hooks":[{"type":"command","command":"/u/stew hook prompt"}]}]}}
        """#.utf8)
        #expect(ClaudeSettings.hookState(executable: "/u/stew", in: previous) == .partial)
        let migrated = try ClaudeSettings.installingHooks(executable: "/u/stew", deniedTimeout: 1800, into: previous)
        #expect(ClaudeSettings.hookState(executable: "/u/stew", in: migrated) == .complete)
        #expect(try stopHandlers(migrated).count == 2)
    }
}
