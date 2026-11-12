import Foundation
import Testing
@testable import StewCore

private func sampleQuestions(multiSecond: Bool = false) -> [Question] {
    [
        Question(question: "Which database?", header: "DB", options: [
            QuestionOption(label: "Postgres", description: "Relational", preview: "CREATE TABLE ..."),
            QuestionOption(label: "SQLite", description: "Embedded"),
        ]),
        Question(question: "Which extras?", header: "Extras", options: [
            QuestionOption(label: "Auth", description: "Login"),
            QuestionOption(label: "Billing", description: "Stripe"),
            QuestionOption(label: "Search", description: "Full text"),
        ], multiSelect: multiSecond),
    ]
}

@Suite struct QuestionFlowTests {
    @Test func singleSelectAdvancesThenCompletes() {
        var flow = QuestionFlow(questions: sampleQuestions())
        #expect(flow.choose(1) == .advanced)
        #expect(flow.index == 1)
        #expect(flow.choose(2) == .complete)
        #expect(flow.answers() == ["Which database?": "SQLite", "Which extras?": "Search"])
    }

    @Test func outOfRangeOptionIsIgnored() {
        var flow = QuestionFlow(questions: sampleQuestions())
        #expect(flow.choose(3) == .stay)
        #expect(flow.answers().isEmpty)
    }

    @Test func multiSelectTogglesAndNeedsSubmit() {
        var flow = QuestionFlow(questions: sampleQuestions(multiSecond: true))
        flow.go(to: 1)
        #expect(flow.submitCurrent() == .stay)
        #expect(flow.choose(2) == .stay)
        #expect(flow.choose(0) == .stay)
        #expect(flow.choose(2) == .stay)
        #expect(flow.choose(1) == .stay)
        #expect(flow.submitCurrent() == .advanced)
        #expect(flow.index == 0)
        #expect(flow.choose(0) == .complete)
        #expect(flow.answers()["Which extras?"] == "Auth, Billing")
    }

    @Test func otherReplacesSingleChoiceAndAddsToMulti() {
        var flow = QuestionFlow(questions: sampleQuestions(multiSecond: true))
        _ = flow.choose(0)
        flow.previous()
        #expect(flow.answerOther("  DuckDB ") == .advanced)
        #expect(flow.answers()["Which database?"] == "DuckDB")
        _ = flow.choose(1)
        #expect(flow.answerOther("Webhooks") == .complete)
        #expect(flow.answers()["Which extras?"] == "Billing, Webhooks")
    }

    @Test func emptyOtherDoesNotAnswer() {
        var flow = QuestionFlow(questions: sampleQuestions())
        #expect(flow.answerOther("   ") == .stay)
        #expect(!flow.isAnswered(0))
    }

    @Test func annotationsCarryChosenPreview() {
        var flow = QuestionFlow(questions: sampleQuestions())
        _ = flow.choose(0)
        _ = flow.choose(0)
        #expect(flow.annotations() == ["Which database?": QuestionAnnotation(preview: "CREATE TABLE ...")])
    }

    @Test func navigationClamps() {
        var flow = QuestionFlow(questions: sampleQuestions())
        flow.previous()
        #expect(flow.index == 0)
        flow.next(); flow.next()
        #expect(flow.index == 1)
    }
}

@Suite struct ValidationTests {
    @Test func acceptsAskUserQuestionInput() throws {
        let json = """
        {"questions":[{"question":"Pick one?","header":"Pick","multiSelect":false,
          "options":[{"label":"A","description":"first"},{"label":"B","description":"second","preview":"b"}]}]}
        """
        let set = try JSONDecoder().decode(QuestionSet.self, from: Data(json.utf8))
        try set.validate()
        #expect(set.questions[0].options[1].preview == "b")
    }

    @Test func rejectsWrongCounts() {
        let one = QuestionSet(questions: [Question(question: "Q?", header: "Q", options: [QuestionOption(label: "A", description: "")])])
        #expect(throws: QuestionSet.ValidationError.self) { try one.validate() }
        #expect(throws: QuestionSet.ValidationError.self) { try QuestionSet(questions: []).validate() }
    }

    @Test func rejectsDuplicateLabels() {
        let set = QuestionSet(questions: [Question(question: "Q?", header: "Q", options: [
            QuestionOption(label: "A", description: ""), QuestionOption(label: "A", description: ""),
        ])])
        #expect(throws: QuestionSet.ValidationError.self) { try set.validate() }
    }
}

@Suite struct WireTests {
    @Test func requestRoundTripsForEveryKind() throws {
        let session = SessionInfo(name: "job", id: "abc-def", cwd: "~/x")
        let requests = [
            StewRequest(session: session, prompt: .permission(PermissionRequest(action: "Delete", command: "rm -rf x", reason: "stale")), timeout: 30),
            StewRequest(session: session, prompt: .notify(NotifyRequest(title: "Done", level: .success)), wait: false),
            StewRequest(session: session, prompt: .question(QuestionSet(questions: sampleQuestions()))),
        ]
        for request in requests {
            let line = try Wire.encode(request)
            #expect(line.last == 0x0A)
            #expect(!line.dropLast().contains(0x0A))
            #expect(try Wire.decode(StewRequest.self, line: line.dropLast()) == request)
        }
    }

    @Test func exitCodes() {
        #expect(StewResponse(status: .approved).exitCode == 0)
        #expect(StewResponse(status: .denied).exitCode == 1)
        #expect(StewResponse(status: .dismissed).exitCode == 2)
        #expect(StewResponse(status: .timeout).exitCode == 3)
    }
}

@Suite struct ShortcutTests {
    @Test func bareKeyJoinsChord() throws {
        let shortcut = try Shortcut.parse("y", chord: [.control, .option])
        #expect(shortcut.description == "⌃⌥Y")
    }

    @Test func fullSpecStandsAlone() throws {
        let shortcut = try Shortcut.parse("cmd+shift+return", chord: [.control, .option])
        #expect(shortcut == Shortcut(modifiers: [.command, .shift], key: .special(.return)))
        #expect(shortcut.description == "⇧⌘↩")
    }

    @Test func plainKeysAreRefused() {
        #expect(throws: Shortcut.ParseError.self) { try Shortcut.parse("y", chord: []) }
        #expect(throws: Shortcut.ParseError.self) { try Shortcut.parse("shift+y", chord: [.control]) }
        #expect(throws: Shortcut.ParseError.self) { try Shortcut.parse("hyper+y", chord: [.control]) }
    }

    @Test func defaultKeymapHasNoConflicts() throws {
        let keymap = try Keymap(config: StewConfig())
        #expect(keymap[.approve].description == "⌘↩")
        #expect(keymap[.deny].description == "⌘D")
        #expect(keymap[.dismiss].description == "⌘.")
        #expect(keymap[.dismissAll].description == "⇧⌘.")
        #expect(keymap[.next].description == "⌘]")
        #expect(keymap.options.map(\.description) == ["⌘1", "⌘2", "⌘3", "⌘4"])
        #expect(keymap[.approve].adding(keymap.hardDenyExtra).description == "⇧⌘↩")
    }

    @Test func approveAndSubmitMayShareAKey() throws {
        let keymap = try Keymap(config: StewConfig())
        #expect(keymap[.approve] == keymap[.submit])
    }

    @Test func conflictingConfigIsRejected() throws {
        let sameAsApprove = try JSONDecoder().decode(StewConfig.self, from: Data(#"{"keys":{"deny":"return"}}"#.utf8))
        #expect(throws: Shortcut.ParseError.self) { try Keymap(config: sameAsApprove) }
        let sameAsOption = try JSONDecoder().decode(StewConfig.self, from: Data(#"{"keys":{"next":"2"}}"#.utf8))
        #expect(throws: Shortcut.ParseError.self) { try Keymap(config: sameAsOption) }
        let sameAsHardDenyApprove = try JSONDecoder().decode(StewConfig.self, from: Data(#"{"keys":{"deny":"cmd+shift+return"}}"#.utf8))
        #expect(throws: Shortcut.ParseError.self) { try Keymap(config: sameAsHardDenyApprove) }
    }

    @Test func partialConfigKeepsDefaults() throws {
        let config = try JSONDecoder().decode(StewConfig.self, from: Data(#"{"chord":"ctrl+cmd","classifier":{"model":"sonnet"}}"#.utf8))
        let keymap = try Keymap(config: config)
        #expect(keymap[.deny].description == "⌃⌘D")
        #expect(config.armDelay == 0.5)
        #expect(config.classifier.model == "sonnet")
        #expect(config.classifier.enabled)
    }
}

@Suite struct SessionResolverTests {
    let home = "/Users/me"

    @Test func explicitNameWins() {
        let session = SessionResolver.resolve(explicitName: "deploy", environment: ["STEW_SESSION": "env"], cwd: "/Users/me/p/app", home: home) { _ in nil }
        #expect(session.name == "deploy")
        #expect(session.cwd == "~/p/app")
    }

    @Test func jobNameFromStateFile() {
        let state = #"{"respawnFlags":["--agent","claude","--name","tooling: notify"]}"#
        let environment = ["CLAUDE_JOB_DIR": "/jobs/1", "CLAUDE_CODE_SESSION_ID": "5b1f0c3a-ace5"]
        let session = SessionResolver.resolve(explicitName: nil, environment: environment, cwd: "/tmp", home: home) { path in
            path == "/jobs/1/state.json" ? Data(state.utf8) : nil
        }
        #expect(session.name == "tooling: notify")
        #expect(session.shortID == "5b1f0c3a")
    }

    @Test func fallsBackToFolderName() {
        let session = SessionResolver.resolve(explicitName: nil, environment: [:], cwd: "/Users/me/Projects/stew", home: home) { _ in nil }
        #expect(session.name == "stew")
        #expect(SessionResolver.resolve(explicitName: nil, environment: [:], cwd: home, home: home) { _ in nil }.name == "~")
    }
}

@Suite struct RiskCheckTests {
    @Test func parsesStructuredOutput() throws {
        let output = #"{"type":"result","is_error":false,"structured_output":{"verdict":"soft_deny","risk":"high","rule":"Git Destructive [named+specifics]: A force-push","summary":"Deletes release/2.1 on origin."}}"#
        let assessment = try RiskCheck.parse(cliOutput: Data(output.utf8))
        #expect(assessment.verdict == .softDeny)
        #expect(assessment.risk == .high)
        #expect(assessment.ruleName == "Git Destructive")
    }

    @Test func reportsCliErrors() {
        #expect(throws: RiskCheck.CheckError(description: "Not logged in")) {
            try RiskCheck.parse(cliOutput: Data(#"{"is_error":true,"result":"Not logged in"}"#.utf8))
        }
        #expect(throws: RiskCheck.CheckError.self) { try RiskCheck.parse(cliOutput: Data("boom".utf8)) }
    }

    @Test func extractsOnlyRealUserMessages() {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"tidy up the repo"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}"#,
            #"{"type":"user","toolUseResult":{},"message":{"role":"user","content":[{"type":"tool_result","content":"x"}]}}"#,
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"meta"}}"#,
            #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>noise</system-reminder>delete old branches too"}]}}"#,
            "not json",
        ]
        let transcript = Data(lines.joined(separator: "\n").utf8)
        #expect(RiskCheck.recentUserMessages(transcript: transcript, limit: 5) == ["tidy up the repo", "delete old branches too"])
        #expect(RiskCheck.recentUserMessages(transcript: transcript, limit: 1) == ["delete old branches too"])
    }

    @Test func inputCarriesContext() throws {
        let text = try RiskCheck.input(
            for: PermissionRequest(action: "Push", command: "git push -f", reason: "rebased"),
            session: SessionInfo(name: "x", cwd: "~/app"),
            recentUserMessages: ["rebase it"]
        )
        #expect(text.contains(#""recent_user_messages":["rebase it"]"#))
        #expect(text.contains(#""cwd":"~/app""#))
    }
}
