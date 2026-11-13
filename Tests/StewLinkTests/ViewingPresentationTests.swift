import Foundation
import Testing
import StewCore
@testable import StewLink

private let received = Date(timeIntervalSince1970: 1_800_000_000)

private func request(_ prompt: Prompt, deadline: Date? = received.addingTimeInterval(60), extendBy: Double? = 120) -> LinkRequest {
    LinkRequest(
        requestId: "request1",
        macName: "Studio",
        request: StewRequest(session: SessionInfo(name: "stew-build", id: "abc", cwd: "/tmp"), prompt: prompt),
        receivedAt: received,
        deadline: deadline,
        queued: false,
        extendBy: extendBy,
        hardDeny: false,
        risk: nil
    )
}

private let single = Prompt.question(QuestionSet(questions: [
    Question(question: "Which database?", header: "DB", options: [
        QuestionOption(label: "Postgres", description: ""),
        QuestionOption(label: "SQLite", description: ""),
    ]),
]))

private let several = Prompt.question(QuestionSet(questions: [
    Question(question: "Which database?", header: "DB", options: [QuestionOption(label: "Postgres", description: ""), QuestionOption(label: "SQLite", description: "")]),
    Question(question: "Which cache?", header: "Cache", options: [QuestionOption(label: "Redis", description: ""), QuestionOption(label: "None", description: "")]),
]))

private let domain = Prompt.input(InputRequest(question: "Which domain?"))

@Suite struct QuestionMoreTimeTests {
    @Test func singleQuestionOffersMoreTime() {
        let roles = LinkPresentation.actions(request(single)).map(\.role)
        #expect(roles == [.option(0), .option(1), .other, .moreTime])
        #expect(LinkPresentation.actions(request(single, extendBy: nil)).map(\.role) == [.option(0), .option(1), .other])
    }

    @Test func questionsAnsweredInTheAppOfferMoreTime() {
        #expect(LinkPresentation.actions(request(several)).map(\.role) == [.moreTime])
        #expect(LinkPresentation.categoryIdentifier(request(several)) == "stew.question.inApp")
        #expect(LinkPresentation.categoryIdentifier(request(several, extendBy: nil)) == "stew.question.inApp.noTime")
        #expect(LinkPresentation.actions(request(several, extendBy: nil)).isEmpty)
    }

    @Test func inputOffersMoreTime() {
        #expect(LinkPresentation.actions(request(domain)).map(\.role) == [.reply, .moreTime])
        #expect(LinkPresentation.actions(request(domain, extendBy: nil)).map(\.role) == [.reply])
    }

    @Test func moreTimeNeedsNoFaceID() {
        let moreTime = LinkPresentation.actions(request(single)).first { $0.role == .moreTime }
        #expect(moreTime?.requiresAuthentication == false)
        #expect(LinkPresentation.choice(forAction: LinkPresentation.moreTimeAction, typedText: nil, request: request(single)) == .moreTime)
        #expect(LinkRefusal.beforeSending(.moreTime, for: request(single), now: received) == nil)
    }
}

@Suite struct ViewingPresentationTests {
    @Test func viewingIsNotAnAnswer() {
        let overdue = request(single)
        // Past the deadline, viewing is too late like More time, never a late answer.
        #expect(LinkRefusal.beforeSending(.viewing, for: overdue, now: received.addingTimeInterval(61)) != nil)
        #expect(LinkRefusal.beforeSending(.viewing, for: overdue, now: received) == nil)
        #expect(LinkRefusal.beforeSending(.left, for: overdue, now: received) == nil)
    }

    @Test func texts() {
        #expect(LinkPresentation.viewingPaused == "No rush: the clock is paused while you answer.")
        #expect(LinkPresentation.viewingOn("Abby's iPhone") == "Viewing on Abby's iPhone")
    }

    @Test func viewingTravelsAndOlderMacsLeaveItOut() throws {
        var paused = request(single)
        paused.viewingOn = "Abby's iPhone"
        let decoded = try JSONDecoder().decode(LinkRequest.self, from: try JSONEncoder().encode(paused))
        #expect(decoded.viewingOn == "Abby's iPhone")
        let answer = LinkAnswer(requestId: "request1", choice: .viewing, phoneName: "Abby's iPhone")
        #expect(try JSONDecoder().decode(LinkAnswer.self, from: try JSONEncoder().encode(answer)).choice == .viewing)
    }
}
