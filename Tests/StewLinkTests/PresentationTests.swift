import Foundation
import Testing
import StewCore
@testable import StewLink

private let received = Date(timeIntervalSince1970: 1_800_000_000)
private let deadline = received.addingTimeInterval(60)
private let clock: @Sendable (Date) -> String = { "T+\(Int($0.timeIntervalSince(received)))" }

private func linkRequest(
    _ prompt: Prompt,
    hardDeny: Bool = false,
    deadline: Date? = deadline,
    queued: Bool = false,
    extendBy: Double? = 120,
    risk: RiskAssessment? = nil,
    sessionID: String? = "abc"
) -> LinkRequest {
    LinkRequest(
        requestId: "request1",
        macName: "Studio",
        request: StewRequest(session: SessionInfo(name: "stew-build", id: sessionID, cwd: "/Users/someone/Projects/stew"), prompt: prompt),
        receivedAt: received,
        deadline: deadline,
        queued: queued,
        extendBy: extendBy,
        hardDeny: hardDeny,
        risk: risk
    )
}

private let permission = Prompt.permission(PermissionRequest(
    action: "Deploy the site",
    command: "API_KEY=sk-abcdefghijklmnopqrstuv npm run deploy", // gitleaks:allow (test fixture)
    reason: "The fix is merged."
))

private let singleQuestion = Prompt.question(QuestionSet(questions: [
    Question(question: "Which database?", header: "DB", options: [
        QuestionOption(label: "Postgres", description: ""),
        QuestionOption(label: "SQLite", description: ""),
    ]),
]))

private let twoQuestions = Prompt.question(QuestionSet(questions: [
    Question(question: "Which database?", header: "DB", options: [QuestionOption(label: "A", description: ""), QuestionOption(label: "B", description: "")]),
    Question(question: "Which cache?", header: "Cache", options: [QuestionOption(label: "C", description: ""), QuestionOption(label: "D", description: "")]),
]))

@Suite struct PresentationTests {
    @Test func permissionShowsWhatThePanelShowsWithSecretsMasked() {
        let content = LinkPresentation.notification(for: linkRequest(permission), pairingId: "pair", time: clock)
        #expect(content.title == "stew-build")
        #expect(content.subtitle == "Permission request · ~/Projects/stew")
        #expect(content.body == "Deploy the site\n$ API_KEY=•••• npm run deploy\nWhy: The fix is merged.\nStudio · answer by T+60")
        #expect(content.categoryIdentifier == "stew.permission")
        #expect(content.actions.map(\.identifier) == ["approve", "deny", "moreTime"])
        #expect(content.actions[0].requiresAuthentication)
        #expect(content.actions[2].title == "More time (+2 min)")
        #expect(content.threadIdentifier == "pair")
    }

    @Test func hardDenyOffersNoApprove() {
        let content = LinkPresentation.notification(for: linkRequest(permission, hardDeny: true), pairingId: "pair", time: clock)
        #expect(content.categoryIdentifier == "stew.permission.macOnly")
        #expect(!content.actions.contains { $0.role == .approve })
        #expect(content.body.hasPrefix("Auto mode never allows this. Approve it on your Mac"))
        #expect(LinkPresentation.choice(forAction: "approve", typedText: nil, request: linkRequest(permission, hardDeny: true)) == nil)
    }

    @Test func noTimeLimitOffersNoMoreTime() {
        let request = linkRequest(permission, deadline: nil, extendBy: nil)
        #expect(LinkPresentation.categoryIdentifier(request) == "stew.permission.noTime")
        #expect(LinkPresentation.actions(request).map(\.identifier) == ["approve", "deny"])
        #expect(LinkPresentation.notification(for: request, pairingId: "pair", time: clock).body.hasSuffix("\nStudio"))
    }

    @Test func queuedRequestSaysSo() {
        let request = linkRequest(permission, deadline: nil, queued: true)
        #expect(LinkPresentation.notification(for: request, pairingId: "pair", time: clock).body.hasSuffix("Studio · waits behind another request"))
    }

    @Test func blockedCallNamesItsCategoryAndLastMessage() {
        let blocked = BlockedCall(toolName: "Bash", category: "Destructive", reason: "r", hardDeny: false, projectRoot: "/tmp", suggestions: [])
        let prompt = Prompt.permission(PermissionRequest(action: "Run rm", command: "rm -rf build", reason: "Cleaning", blocked: blocked))
        let body = LinkPresentation.notification(for: linkRequest(prompt), pairingId: "pair", time: clock).body
        #expect(body.hasPrefix("Auto mode blocked this · Destructive\nRun rm\n$ rm -rf build\nClaude's last message: Cleaning"))
    }

    @Test func singleQuestionGetsOptionsAndOther() {
        let request = linkRequest(singleQuestion)
        let content = LinkPresentation.notification(for: request, pairingId: "pair", time: clock)
        #expect(content.categoryIdentifier == "stew.question.request1")
        #expect(content.actions.map(\.title) == ["Postgres", "SQLite", "Other…", "More time (+2 min)"])
        #expect(content.actions.first { $0.role == .other }?.textPlaceholder != nil)
        #expect(LinkPresentation.choice(forAction: "option.1", typedText: nil, request: request) == .answers([LinkQuestionAnswer(selected: [1])]))
        #expect(LinkPresentation.choice(forAction: "other", typedText: "  MySQL ", request: request) == .answers([LinkQuestionAnswer(selected: [], other: "MySQL")]))
        #expect(LinkPresentation.choice(forAction: "other", typedText: "  ", request: request) == nil)
        #expect(LinkPresentation.choice(forAction: "option.7", typedText: nil, request: request) == nil)
    }

    @Test func severalQuestionsAnswerInTheApp() {
        let content = LinkPresentation.notification(for: linkRequest(twoQuestions), pairingId: "pair", time: clock)
        #expect(content.categoryIdentifier == "stew.question.inApp")
        #expect(content.actions.map(\.role) == [.moreTime])
        #expect(content.body.contains("Open stew to answer 2 questions."))
    }

    @Test func notifyHasOnlyOK() {
        let prompt = Prompt.notify(NotifyRequest(title: "Tests passed", body: "212 of 212", level: .success))
        let content = LinkPresentation.notification(for: linkRequest(prompt, deadline: nil, extendBy: nil), pairingId: "pair", time: clock)
        #expect(content.title == "Tests passed")
        #expect(content.subtitle == "Done · stew-build")
        #expect(content.body == "212 of 212\nStudio")
        #expect(content.categoryIdentifier == LinkPresentation.notifyCategory)
        #expect(content.actions.map(\.identifier) == [LinkPresentation.acknowledgeAction])
        #expect(content.actions.map(\.title) == ["OK"])
        #expect(content.actions.map(\.role) == [.acknowledge])
        #expect(content.actions.allSatisfy { !$0.requiresAuthentication && !$0.isDestructive })
    }

    @Test func needsItemShowsWhatThePanelShowsWithDoneAndNotNow() {
        let needs = NeedsRequest(
            title: "Log in to the registry",
            why: "The publish step needs a token.",
            steps: ["Open the terminal", "Run the command"],
            commands: [NeedsCommand(command: "NPM_TOKEN=sk-abcdefghijklmnopqrstuv pnpm login")] // gitleaks:allow (test fixture)
        )
        let request = linkRequest(.needs(needs), deadline: nil, extendBy: nil)
        let content = LinkPresentation.notification(for: request, pairingId: "pair", time: clock)
        #expect(content.title == "Log in to the registry")
        #expect(content.subtitle == "Needs you · stew-build")
        #expect(content.body == "The publish step needs a token.\n1. Open the terminal\n2. Run the command\n$ NPM_TOKEN=•••• pnpm login\nStudio")
        #expect(content.categoryIdentifier == "stew.needs")
        #expect(content.actions.map(\.title) == ["Done", "Not now"])
        #expect(content.actions.allSatisfy { action in !action.requiresAuthentication })
        #expect(LinkPresentation.choice(forAction: "done", typedText: nil, request: request) == .done)
        #expect(LinkPresentation.choice(forAction: "notNow", typedText: nil, request: request) == nil)
        #expect(LinkPresentation.choice(forAction: "done", typedText: nil, request: linkRequest(permission)) == nil)
        #expect(LinkRefusal.beforeSending(.done, for: request, now: received) == nil)
        #expect(LinkRefusal.beforeSending(.approve, for: request, now: received) != nil)
        var history = PhoneHistory()
        history.record(request, pairingId: "pair")
        #expect(history.entries[0].command == "NPM_TOKEN=•••• pnpm login")
        #expect(history.entries[0].kindTitle == "Needs you")
        #expect(LinkPresentation.needsRequestId("ab12cd34") == "needs-ab12cd34")
    }

    @Test func needsItemWithItsOwnAnswersOffersThemAsActions() {
        let needs = NeedsRequest(title: "Sign in to App Store Connect", doneLabel: "Signed in", answers: ["Can't sign in", "Use another account"])
        let request = linkRequest(.needs(needs), deadline: nil, extendBy: nil)
        let content = LinkPresentation.notification(for: request, pairingId: "pair", time: clock)
        #expect(content.categoryIdentifier == "stew.needs.request1")
        #expect(content.actions.map(\.identifier) == ["done", "answer.0", "answer.1", "notNow"])
        #expect(content.actions.map(\.title) == ["Signed in", "Can't sign in", "Use another account", "Not now"])
        #expect(content.actions.allSatisfy { action in !action.requiresAuthentication })
        #expect(LinkPresentation.choice(forAction: "done", typedText: nil, request: request) == .done)
        #expect(LinkPresentation.choice(forAction: "answer.1", typedText: nil, request: request) == .needsAnswer("Use another account"))
        #expect(LinkPresentation.choice(forAction: "answer.2", typedText: nil, request: request) == nil)
        #expect(LinkPresentation.choice(forAction: "answer.0", typedText: nil, request: linkRequest(permission)) == nil)
        #expect(LinkRefusal.beforeSending(.needsAnswer("Can't sign in"), for: request, now: received) == nil)
        #expect(LinkRefusal.beforeSending(.needsAnswer("Gave up"), for: request, now: received) == LinkRefusal.unknownAnswer)
        #expect(LinkRefusal.beforeSending(.needsAnswer("Can't sign in"), for: linkRequest(permission), now: received) != nil)
        // A plain item keeps the shared category, so older registrations still match.
        let plain = linkRequest(.needs(NeedsRequest(title: "Plug in the YubiKey")), deadline: nil, extendBy: nil)
        #expect(LinkPresentation.categoryIdentifier(plain) == "stew.needs")
    }

    @Test func doneKeepsItsWireFormSoOlderMacsAndPhonesAgree() throws {
        let done = try LinkJSON.encode(LinkAnswer(requestId: "needs-1", choice: .done, phoneName: "phone", answeredAt: received))
        #expect(String(decoding: done, as: UTF8.self).contains(#""choice":{"done":{}}"#))
        let other = LinkAnswer(requestId: "needs-1", choice: .needsAnswer("Can't sign in"), note: "later", phoneName: "phone", answeredAt: received)
        #expect(try LinkJSON.decode(LinkAnswer.self, from: try LinkJSON.encode(other)) == other)
        // A Mac's request with labels still decodes where the labels are unknown: the
        // fields are optional, so an older phone reads the item and answers Done.
        let labelled = StewRequest(session: SessionInfo(name: "job"), prompt: .needs(NeedsRequest(title: "Sign in", doneLabel: "Signed in", answers: ["Later"])))
        var object = try #require(try JSONSerialization.jsonObject(with: try JSONEncoder().encode(labelled)) as? [String: Any])
        var needs = try #require(object["needs"] as? [String: Any])
        needs["futureField"] = "ignored"
        object["needs"] = needs
        let decoded = try JSONDecoder().decode(StewRequest.self, from: try JSONSerialization.data(withJSONObject: object))
        #expect(decoded == labelled)
    }

    @Test func shortPath() {
        #expect(LinkPresentation.shortPath("/Users/someone/Projects/x") == "~/Projects/x")
        #expect(LinkPresentation.shortPath("/Users/someone") == "~")
        #expect(LinkPresentation.shortPath("/tmp/x") == "/tmp/x")
    }

    @Test func phoneRefusesLateAndMacOnlyAnswersBeforeSending() {
        let request = linkRequest(permission, sessionID: nil)
        #expect(LinkRefusal.beforeSending(.approve, for: request, now: received) == nil)
        let late = LinkRefusal.beforeSending(.approve, for: request, now: deadline.addingTimeInterval(1))
        #expect(late?.hasPrefix("Too late: the request on Studio timed out at") == true)
        #expect(LinkRefusal.beforeSending(.approve, for: linkRequest(permission, hardDeny: true), now: received) == LinkRefusal.macOnly)
        #expect(LinkRefusal.beforeSending(.deny, for: linkRequest(permission, hardDeny: true), now: received) == nil)
        #expect(LinkRefusal.beforeSending(.moreTime, for: linkRequest(permission, deadline: nil, queued: true), now: received) == LinkRefusal.clockNotStarted)
        #expect(LinkRefusal.beforeSending(.approve, for: linkRequest(singleQuestion), now: received) != nil)
    }

    @Test func lateAnswersPassForAKnownSession() {
        let afterDeadline = deadline.addingTimeInterval(1)
        let request = linkRequest(permission)
        #expect(LinkPresentation.canAnswerLate(request))
        #expect(LinkPresentation.isOverdue(request, now: afterDeadline))
        #expect(!LinkPresentation.isOverdue(request, now: received))
        #expect(LinkRefusal.beforeSending(.approve, for: request, now: afterDeadline) == nil)
        #expect(LinkRefusal.beforeSending(.deny, for: request, now: afterDeadline) == nil)
        #expect(LinkRefusal.beforeSending(.answers([LinkQuestionAnswer(selected: [0])]), for: linkRequest(singleQuestion), now: afterDeadline) == nil)
        // More time cannot bring a timed-out request back, and the Mac's rules still hold.
        #expect(LinkRefusal.beforeSending(.moreTime, for: request, now: afterDeadline)?.hasPrefix("Too late") == true)
        #expect(LinkRefusal.beforeSending(.approve, for: linkRequest(permission, hardDeny: true), now: afterDeadline) == LinkRefusal.macOnly)
        // Without a session id there is nobody to give a late answer to.
        #expect(!LinkPresentation.canAnswerLate(linkRequest(permission, sessionID: nil)))
        // A secret is never answered from the phone, late or not.
        let secret = linkRequest(.input(InputRequest(question: "OTP?", secret: true)))
        #expect(!LinkPresentation.canAnswerLate(secret))
        #expect(LinkRefusal.beforeSending(.enterLater, for: secret, now: afterDeadline)?.hasPrefix("Too late") == true)
    }

    @Test func lateResultRoundTrips() throws {
        let result = LinkResult(requestId: "request1", accepted: true, message: "Sent as a late answer.", late: true)
        #expect(try LinkJSON.decode(LinkResult.self, from: LinkJSON.encode(result)) == result)
        // A Mac without late answers sends no flag.
        let older = try LinkJSON.decode(LinkResult.self, from: Data(#"{"requestId":"request1","accepted":true,"message":"Approved."}"#.utf8))
        #expect(older.late == nil)
    }

    @Test func outcomeLabelsMatchTheMac() {
        #expect(LinkOutcome.allCases.map(\.label) == [
            "Approved", "Denied", "Answered", "Timed out", "Dismissed", "Answered on Mac",
            "Done", "Resolved by Claude", "Answered in session", "Moved on", "Enter later",
        ])
        #expect(LinkOutcome.allCases.filter(\.isMissed) == [.timedOut])
    }
}

@Suite struct PhoneHistoryTests {
    @Test func recordsMaskedAndResolvesOnce() {
        var history = PhoneHistory()
        history.record(linkRequest(permission), pairingId: "pair")
        #expect(history.entries.count == 1)
        #expect(history.entries[0].command == "API_KEY=•••• npm run deploy")
        #expect(history.open.count == 1)
        history.resolve(requestId: "request1", pairingId: "pair", outcome: .approved, at: received.addingTimeInterval(5))
        history.resolve(requestId: "request1", pairingId: "pair", outcome: .answeredOnMac, at: received.addingTimeInterval(6))
        #expect(history.entries[0].outcome == .approved)
        #expect(history.open.isEmpty)
    }

    @Test func updateRefreshesTheDeadlineWithoutADuplicate() {
        var history = PhoneHistory()
        history.record(linkRequest(permission, deadline: nil, queued: true), pairingId: "pair")
        history.record(linkRequest(permission, deadline: deadline), pairingId: "pair")
        #expect(history.entries.count == 1)
        #expect(history.entries[0].deadline == deadline)
    }

    @Test func overdueBecomesMissed() {
        var history = PhoneHistory()
        history.record(linkRequest(permission), pairingId: "pair")
        history.record(linkRequest(singleQuestion, deadline: nil), pairingId: "other")
        history.markOverdue(now: deadline.addingTimeInterval(1))
        #expect(history.closed(missedOnly: true).map(\.pairingId) == ["pair"])
        #expect(history.open.map(\.pairingId) == ["other"])
    }

    @Test func missedFilterAndRetention() {
        var history = PhoneHistory()
        history.record(linkRequest(permission), pairingId: "first")
        history.record(linkRequest(permission), pairingId: "second")
        history.resolve(requestId: "request1", pairingId: "first", outcome: .timedOut, at: deadline)
        history.resolve(requestId: "request1", pairingId: "second", outcome: .denied, at: deadline)
        #expect(history.closed(missedOnly: false).count == 2)
        #expect(history.closed(missedOnly: true).map(\.pairingId) == ["first"])
        history.prune(now: received.addingTimeInterval(29 * 24 * 3600))
        #expect(history.entries.count == 2)
        history.prune(now: received.addingTimeInterval(31 * 24 * 3600))
        #expect(history.entries.isEmpty)
    }

    @Test func unpairRemovesThatMacsHistory() {
        var history = PhoneHistory()
        history.record(linkRequest(permission), pairingId: "first")
        history.record(linkRequest(permission), pairingId: "second")
        history.removeAll(pairingId: "first")
        #expect(history.entries.map(\.pairingId) == ["second"])
    }
}

@Suite struct PhoneAnswerTests {
    private let set = QuestionSet(questions: [
        Question(question: "Which DB?", header: "DB", options: [
            QuestionOption(label: "Postgres", description: ""),
            QuestionOption(label: "SQLite", description: "", preview: "embedded"),
        ]),
        Question(question: "Which extras?", header: "Extras", options: [
            QuestionOption(label: "Auth", description: ""),
            QuestionOption(label: "Billing", description: ""),
            QuestionOption(label: "Search", description: ""),
        ], multiSelect: true),
    ])

    @Test func rebuildsLikeThePanel() throws {
        let flow = try #require(QuestionFlow(set: set, linkAnswers: [
            LinkQuestionAnswer(selected: [1]),
            LinkQuestionAnswer(selected: [2, 0, 2]),
        ]))
        #expect(flow.answers() == ["Which DB?": "SQLite", "Which extras?": "Auth, Search"])
        #expect(flow.annotations()["Which DB?"]?.preview == "embedded")
    }

    @Test func otherTextAnswers() throws {
        let flow = try #require(QuestionFlow(set: set, linkAnswers: [
            LinkQuestionAnswer(selected: [], other: "MySQL"),
            LinkQuestionAnswer(selected: [1], other: "Mail"),
        ]))
        #expect(flow.answers() == ["Which DB?": "MySQL", "Which extras?": "Billing, Mail"])
    }

    @Test func refusesIncompleteOrInvalid() {
        #expect(QuestionFlow(set: set, linkAnswers: [LinkQuestionAnswer(selected: [0])]) == nil)
        #expect(QuestionFlow(set: set, linkAnswers: [LinkQuestionAnswer(selected: [0]), LinkQuestionAnswer(selected: [])]) == nil)
        #expect(QuestionFlow(set: set, linkAnswers: [LinkQuestionAnswer(selected: [5]), LinkQuestionAnswer(selected: [0])]) == nil)
        #expect(QuestionFlow(set: set, linkAnswers: [LinkQuestionAnswer(selected: [0, 1]), LinkQuestionAnswer(selected: [0])]) == nil)
    }
}

struct TimeSensitiveTests {
    @Test func requestsWithATimeLimitAreTimeSensitive() {
        #expect(LinkPresentation.hasDeadline(.permission(PermissionRequest(action: "Push", reason: "Ship it"))))
        #expect(LinkPresentation.hasDeadline(.input(InputRequest(question: "Which domain?"))))
        #expect(!LinkPresentation.hasDeadline(.needs(NeedsRequest(title: "Log in to npm"))))
        #expect(!LinkPresentation.hasDeadline(.notify(NotifyRequest(title: "Done"))))
    }
}
