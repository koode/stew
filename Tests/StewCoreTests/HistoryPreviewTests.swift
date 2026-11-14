import Foundation
import Testing
@testable import StewCore

private let session = SessionInfo(name: "deploy job", id: "s1", cwd: "/work/app")
private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let token = "ghp_abcdefghijklmnopqrstuvwxyz0123456789" // gitleaks:allow (test fixture)

private func clock(_ date: Date) -> String {
    "+\(Int(date.timeIntervalSince(start) / 60))m"
}

@Suite struct HistoryRequestCopyTests {
    @Test func keepsTheRequestMaskedAndWithoutItsRoute() {
        let request = StewRequest(
            session: session,
            prompt: .permission(PermissionRequest(action: "Deploy", command: "deploy --token \(token)", reason: "release day")),
            timeout: 60, maxWait: 600, origin: RequestOrigin(agentID: "agent-1", toolName: "Bash", callKey: "{\"command\":\"deploy\"}")
        )
        let recorded = HistoryEntry.record(request, received: start, response: StewResponse(status: .approved), ended: start, answeredOn: "Studio")
        guard case .permission(let kept) = recorded.request?.prompt else {
            Issue.record("no permission kept")
            return
        }
        #expect(kept.command == "deploy --token ••••")
        #expect(kept.reason == "release day")
        #expect(recorded.request?.origin == nil)
        #expect(recorded.request?.timeout == nil)
        #expect(recorded.request?.maxWait == nil)
        #expect(recorded.request?.session == session)
        #expect(String(decoding: try! History.line(recorded), as: UTF8.self).contains(token) == false)
    }

    @Test func dropsTheDefaultOfASecretInput() {
        let request = StewRequest(session: session, prompt: .input(InputRequest(question: "Key?", defaultText: "hunter2", secret: true)))
        let recorded = HistoryEntry.record(request, received: start, response: StewResponse(status: .answered, text: "hunter2"), ended: start)
        #expect(String(decoding: try! History.line(recorded), as: UTF8.self).contains("hunter2") == false)
        guard case .input(let kept) = recorded.request?.prompt else {
            Issue.record("no input kept")
            return
        }
        #expect(kept.defaultText == nil)
        #expect(kept.secret)
    }

    @Test func masksNeedsCommands() {
        let item = NeedsItem(id: "n1", created: start, session: session, needs: NeedsRequest(title: "Log in", commands: [NeedsCommand(command: "login --token \(token)")]))
        let recorded = HistoryEntry.record(item, outcome: .done, note: nil, ended: start, answeredOn: "Studio")
        guard case .needs(let kept) = recorded.request?.prompt else {
            Issue.record("no needs kept")
            return
        }
        #expect(kept.commands.map(\.command) == ["login --token ••••"])
        #expect(recorded.answeredOn == "Studio")
    }

    @Test func noDeviceForATimeoutOrACallerThatLeft() {
        let request = StewRequest(session: session, prompt: .notify(NotifyRequest(title: "Done")))
        #expect(HistoryEntry.record(request, received: start, response: StewResponse(status: .timeout), ended: start, answeredOn: "Studio").answeredOn == nil)
        #expect(HistoryEntry.record(request, received: start, response: nil, ended: start, answeredOn: "Studio").answeredOn == nil)
        #expect(HistoryEntry.record(request, received: start, response: StewResponse(status: .acknowledged), ended: start, answeredOn: "Studio").answeredOn == "Studio")
    }

    @Test func readsLinesFromBeforeTheRequestWasKept() {
        let line = #"{"command":"ls","detail":"why","ended":"2027-01-15T08:00:00Z","id":"6F1D3C7A-1B2C-4D5E-8F90-A1B2C3D4E5F6","kind":"permission","outcome":"approved","received":"2027-01-15T07:59:00Z","session":"s","summary":"List"}"#
        let entries = History.parse(Data(line.utf8))
        #expect(entries.count == 1)
        #expect(entries.first?.request == nil)
        #expect(entries.first?.answeredOn == nil)
    }
}

@Suite struct HistoryPreviewRequestTests {
    @Test func rebuildsAPermissionFromAnOldEntry() {
        let entry = HistoryEntry(
            received: start, ended: start, session: "s", cwd: "/work", kind: "permission", summary: "List files",
            command: "ls -la", detail: "To see them", outcome: .approved
        )
        #expect(entry.previewRequest.session == SessionInfo(name: "s", cwd: "/work"))
        #expect(entry.previewRequest.prompt == .permission(PermissionRequest(action: "List files", command: "ls -la", reason: "To see them")))
    }

    @Test func rebuildsQuestionsFromTheirDetail() {
        let recorded = HistoryEntry.record(
            StewRequest(session: session, prompt: .question(QuestionSet(questions: [
                Question(question: "Which database?", header: "DB", options: [
                    QuestionOption(label: "Postgres", description: "Relational"),
                    QuestionOption(label: "SQLite", description: "Embedded"),
                ]),
                Question(question: "Which cache?", header: "Cache", options: [QuestionOption(label: "Redis", description: "")]),
            ]))),
            received: start, response: nil, ended: start
        )
        var old = recorded
        old.request = nil
        guard case .question(let set) = old.previewRequest.prompt else {
            Issue.record("not a question")
            return
        }
        #expect(set.questions.map(\.question) == ["Which database?", "Which cache?"])
        #expect(set.questions.map { $0.options.map(\.label) } == [["Postgres", "SQLite"], ["Redis"]])
    }

    @Test func prefersTheKeptRequest() {
        let request = StewRequest(session: session, prompt: .notify(NotifyRequest(title: "Built", body: "in 3 s", level: .success)), wait: false)
        let recorded = HistoryEntry.record(request, received: start, response: StewResponse(status: .acknowledged), ended: start)
        #expect(recorded.previewRequest == request)
    }

    @Test func rebuildsOtherKinds() {
        func old(_ kind: String, command: String? = nil, secret: Bool? = nil) -> HistoryEntry {
            HistoryEntry(
                received: start, ended: start, session: "s", cwd: nil, kind: kind, summary: "Title",
                command: command, detail: "Details", outcome: .done, secret: secret
            )
        }
        #expect(old("notify").previewRequest.prompt == .notify(NotifyRequest(title: "Title", body: "Details")))
        #expect(old("input", secret: true).previewRequest.prompt == .input(InputRequest(question: "Title", why: "Details", secret: true)))
        #expect(old("needs", command: "a\nb").previewRequest.prompt == .needs(NeedsRequest(
            title: "Title", why: "Details", commands: [NeedsCommand(command: "a"), NeedsCommand(command: "b")]
        )))
    }
}

@Suite struct HistoryOutcomeLineTests {
    @Test func saysWhatHappenedWhenAndWhere() {
        var entry = HistoryEntry(
            received: start, ended: start.addingTimeInterval(120), session: "s", cwd: nil, kind: "permission", summary: "x",
            command: nil, detail: nil, outcome: .approved, answeredOn: "Studio"
        )
        #expect(entry.outcomeLine(timeText: clock) == "Approved +2m on Studio")
        entry.outcome = .timedOut
        entry.answeredOn = nil
        #expect(entry.outcomeLine(timeText: clock) == "Timed out +2m")
        entry.late = LateOutcome(answered: start.addingTimeInterval(600), outcome: .denied, message: "m", answeredOn: "Sam's iPhone")
        #expect(entry.outcomeLine(timeText: clock) == "Denied late +10m on Sam's iPhone")
    }
}

@Suite struct QuestionFlowRestoringTests {
    private let questions = [
        Question(question: "Ship?", header: "", options: [
            QuestionOption(label: "Yes", description: ""),
            QuestionOption(label: "Yes, ship it", description: ""),
            QuestionOption(label: "No", description: ""),
        ]),
        Question(question: "Extras?", header: "", options: [
            QuestionOption(label: "Auth", description: ""),
            QuestionOption(label: "Billing", description: ""),
        ], multiSelect: true),
    ]

    @Test func selectsTheAnsweredOptions() {
        let flow = QuestionFlow.restoring(questions: questions, answers: ["Ship?": "Yes, ship it", "Extras?": "Auth, Billing"])
        #expect(flow.selections == [[1], [0, 1]])
        #expect(flow.otherText == [nil, nil])
        #expect(flow.answers() == ["Ship?": "Yes, ship it", "Extras?": "Auth, Billing"])
    }

    @Test func keepsTypedTextUnderOther() {
        let flow = QuestionFlow.restoring(questions: questions, answers: ["Ship?": "Wait for QA", "Extras?": "Auth, Search"])
        #expect(flow.selections == [[], [0]])
        #expect(flow.otherText == ["Wait for QA", "Search"])
    }

    @Test func leavesUnansweredQuestionsEmpty() {
        let flow = QuestionFlow.restoring(questions: questions, answers: [:])
        #expect(flow.selections == [[], []])
        #expect(!flow.isAnswered(0))
    }
}

@Suite struct UnseenMissedTests {
    @Test func missedSinceHistoryLastShowed() {
        func entry(_ outcome: HistoryEntry.Outcome, minutes: Double) -> HistoryEntry {
            HistoryEntry(
                received: start, ended: start.addingTimeInterval(minutes * 60), session: "s", cwd: nil, kind: "permission",
                summary: "x", command: nil, detail: nil, outcome: outcome
            )
        }
        let old = entry(.timedOut, minutes: 1)
        let new = entry(.timedOut, minutes: 10)
        let later = entry(.later, minutes: 11)
        var answered = entry(.timedOut, minutes: 12)
        answered.late = LateOutcome(answered: start, outcome: .approved, message: "m")
        let approved = entry(.approved, minutes: 13)
        let entries = [old, new, later, answered, approved]
        #expect(History.unseenMissedIDs(entries, seenAt: start.addingTimeInterval(5 * 60)) == [new.id, later.id])
        #expect(History.unseenMissedIDs(entries, seenAt: nil) == [old.id, new.id, later.id])
        #expect(MenuBarBadge.unseenMissed(entries, seenAt: nil) == 3)
    }
}
