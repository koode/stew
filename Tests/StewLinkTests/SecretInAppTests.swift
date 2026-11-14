import Foundation
import Testing
import StewCore
@testable import StewLink

private let received = Date(timeIntervalSince1970: 1_800_000_000)
private let clock: @Sendable (Date) -> String = { "T+\(Int($0.timeIntervalSince(received)))" }
private let token = InputRequest(question: "Deploy token?", pattern: "[a-z0-9-]+", format: "lowercase letters, digits and dashes", secret: true)

private func secretRequest(_ input: InputRequest = token, inApp: Bool? = true, sessionID: String? = "abc", deadline: Date? = received.addingTimeInterval(60)) -> LinkRequest {
    LinkRequest(
        requestId: "request1",
        macName: "Studio",
        request: StewRequest(session: SessionInfo(name: "stew-build", id: sessionID, cwd: "/tmp"), prompt: .input(input)),
        receivedAt: received,
        deadline: deadline,
        queued: false,
        extendBy: deadline == nil ? nil : 120,
        hardDeny: false,
        risk: nil,
        secretInApp: inApp
    )
}

@Suite struct SecretInAppTests {
    @Test func notificationOffersTheAppNeverAField() {
        let content = LinkPresentation.notification(for: secretRequest(), pairingId: "pair", time: clock)
        #expect(content.body == "Deploy token?\nEnter it on your Mac or in the stew app.\nStudio · answer by T+60")
        #expect(content.categoryIdentifier == "stew.secret.app")
        #expect(content.actions.map(\.identifier) == ["enterInApp", "enterSoon", "enterLater"])
        #expect(content.actions.map(\.title) == ["Enter in app", "Give me 5 min", "I'll enter it later"])
        #expect(content.actions.first?.role == .enterInApp)
        // No action has a text field: a notification cannot hide what is typed.
        #expect(content.actions.allSatisfy { $0.textPlaceholder == nil && !$0.requiresAuthentication })
        #expect(LinkPresentation.choice(forAction: "enterInApp", typedText: "x", request: secretRequest()) == nil)
    }

    @Test func anOlderMacKeepsTheMacOnlyText() {
        let older = secretRequest(inApp: nil)
        #expect(!LinkPresentation.takesSecretInApp(older))
        #expect(LinkPresentation.categoryIdentifier(older) == "stew.secret")
        #expect(LinkPresentation.actions(older).map(\.identifier) == ["enterSoon", "enterLater"])
        #expect(LinkRefusal.beforeSending(.secret("abc"), for: older, now: received) == LinkRefusal.secretOnMac)
        #expect(!LinkPresentation.canAnswerLate(older))
    }

    @Test func theSecretIsCheckedLikeOnTheMac() {
        let request = secretRequest()
        #expect(LinkRefusal.beforeSending(.secret("abc-123"), for: request, now: received) == nil)
        #expect(LinkRefusal.beforeSending(.secret(""), for: request, now: received) == LinkRefusal.emptyAnswer)
        let mismatch = LinkRefusal.beforeSending(.secret("NOT VALID"), for: request, now: received)
        #expect(mismatch == "Not in the expected format. Expected: lowercase letters, digits and dashes")
        #expect(mismatch?.contains("NOT VALID") == false)
        // A plain reply to a secret is still refused, and a secret for a plain input too.
        #expect(LinkRefusal.beforeSending(.text("abc"), for: request, now: received) == LinkRefusal.secretOnMac)
        #expect(LinkRefusal.secretRefusal("abc", for: InputRequest(question: "Domain?")) == LinkRefusal.notASecret)
    }

    @Test func aSecretCanBeAnsweredLateFromTheApp() {
        let request = secretRequest()
        #expect(LinkPresentation.canAnswerLate(request))
        #expect(LinkRefusal.beforeSending(.secret("abc"), for: request, now: received.addingTimeInterval(120)) == nil)
        #expect(LinkRefusal.beforeSending(.enterSoon, for: request, now: received.addingTimeInterval(120))?.hasPrefix("Too late") == true)
        // Without a session the late answer has nowhere to go.
        #expect(!LinkPresentation.canAnswerLate(secretRequest(sessionID: nil)))
    }

    @Test func theChoiceAndTheFlagTravel() throws {
        let request = secretRequest()
        #expect(try LinkJSON.decode(LinkRequest.self, from: try LinkJSON.encode(request)).secretInApp == true)
        let answer = LinkAnswer(requestId: "request1", choice: .secret("abc-123"), phoneName: "iPhone", answeredAt: received)
        #expect(try LinkJSON.decode(LinkAnswer.self, from: try LinkJSON.encode(answer)) == answer)
    }
}
