import Foundation
import Testing
import StewCore
@testable import StewLink

private let received = Date(timeIntervalSince1970: 1_800_000_000)
private let deadline = received.addingTimeInterval(60)
private let clock: @Sendable (Date) -> String = { "T+\(Int($0.timeIntervalSince(received)))" }

private let domain = InputRequest(question: "Which domain?", why: "The DNS record needs it.", placeholder: "example.com", pattern: "[a-z0-9.-]+\\.[a-z]{2,}")
private let otp = InputRequest(question: "What is the npm one-time password?", why: "npm publish asks for it.", secret: true)

private func linkRequest(_ input: InputRequest, sessionID: String? = "abc", deadline: Date? = deadline, queued: Bool = false) -> LinkRequest {
    LinkRequest(
        requestId: "request1",
        macName: "Studio",
        request: StewRequest(session: SessionInfo(name: "stew-build", id: sessionID, cwd: "/Users/someone/Projects/stew"), prompt: .input(input)),
        receivedAt: received,
        deadline: deadline,
        queued: queued,
        extendBy: deadline == nil && !queued ? nil : 120,
        hardDeny: false,
        risk: nil
    )
}

@Suite struct InputPresentationTests {
    @Test func plainInputRepliesInTheNotification() throws {
        let request = linkRequest(domain)
        let content = LinkPresentation.notification(for: request, pairingId: "pair", time: clock)
        #expect(content.subtitle == "Input · ~/Projects/stew")
        #expect(content.body == "Which domain?\nWhy: The DNS record needs it.\nStudio · answer by T+60")
        #expect(content.categoryIdentifier == "stew.input.request1")
        let reply = try #require(content.actions.first)
        #expect(content.actions.count == 1)
        #expect(reply.identifier == "reply" && reply.title == "Reply" && reply.textPlaceholder == "example.com")
        #expect(!reply.requiresAuthentication)
        #expect(LinkPresentation.choice(forAction: "reply", typedText: "example.com", request: request) == .text("example.com"))
    }

    @Test func phoneRefusesAReplyThatDoesNotMatch() {
        let request = linkRequest(domain)
        #expect(LinkRefusal.beforeSending(.text("example.com"), for: request, now: received) == nil)
        #expect(LinkRefusal.beforeSending(.text("not a domain"), for: request, now: received) == "Not in the expected format. Expected: [a-z0-9.-]+\\.[a-z]{2,}")
        #expect(LinkRefusal.beforeSending(.text("  "), for: request, now: received) == LinkRefusal.emptyAnswer)
        #expect(LinkRefusal.beforeSending(.text("example.com"), for: request, now: deadline.addingTimeInterval(1))?.hasPrefix("Too late") == true)
    }

    @Test func secretOffersNoTextFieldOnlyTheMacChoices() {
        let request = linkRequest(otp)
        let content = LinkPresentation.notification(for: request, pairingId: "pair", time: clock)
        #expect(content.subtitle == "Secret · ~/Projects/stew")
        #expect(content.body == "What is the npm one-time password?\nWhy: npm publish asks for it.\nEnter it on your Mac.\nStudio · answer by T+60")
        #expect(content.categoryIdentifier == "stew.secret")
        #expect(content.actions.map(\.identifier) == ["enterSoon", "enterLater"])
        #expect(content.actions.map(\.title) == ["Give me 5 min", "I'll enter it later"])
        #expect(content.actions.allSatisfy { $0.textPlaceholder == nil && !$0.requiresAuthentication })
        #expect(LinkPresentation.choice(forAction: "reply", typedText: "x", request: request) == nil)
        #expect(LinkPresentation.choice(forAction: "enterSoon", typedText: nil, request: request) == .enterSoon)
        #expect(LinkPresentation.choice(forAction: "enterLater", typedText: nil, request: request) == .enterLater)
        #expect(LinkRefusal.beforeSending(.text("x"), for: request, now: received) == LinkRefusal.secretOnMac)
        #expect(LinkRefusal.beforeSending(.enterSoon, for: request, now: received) == nil)
        #expect(LinkRefusal.beforeSending(.enterLater, for: request, now: received) == nil)
    }

    @Test func secretChoicesFollowTheClockAndTheSession() {
        let noClock = linkRequest(otp, deadline: nil)
        #expect(LinkPresentation.actions(noClock).map(\.identifier) == ["enterLater"])
        #expect(LinkPresentation.categoryIdentifier(noClock) == "stew.secret.noTime")
        #expect(LinkRefusal.beforeSending(.enterSoon, for: linkRequest(otp, deadline: nil, queued: true), now: received) == LinkRefusal.clockNotStarted)
        let noSession = linkRequest(otp, sessionID: nil)
        #expect(LinkPresentation.actions(noSession).map(\.identifier) == ["enterSoon"])
        #expect(LinkPresentation.categoryIdentifier(noSession) == "stew.secret.noLater")
        #expect(LinkPresentation.choice(forAction: "enterLater", typedText: nil, request: noSession) == nil)
    }

    @Test func questionAndWhyAreMaskedOnThePhone() {
        let leaky = InputRequest(question: "Is API_KEY=sk-abcdefghijklmnopqrstuv still valid?", secret: true) // gitleaks:allow (test fixture)
        let body = LinkPresentation.notification(for: linkRequest(leaky), pairingId: "pair", time: clock).body
        #expect(body.hasPrefix("Is API_KEY=•••• still valid?"))
    }
}

@Suite struct InputWireCompatibilityTests {
    @Test func linkRequestAndChoicesRoundTrip() throws {
        let request = linkRequest(domain)
        #expect(try LinkJSON.decode(LinkRequest.self, from: try LinkJSON.encode(request)) == request)
        for choice in [LinkChoice.text("example.com"), .enterSoon, .enterLater] {
            let answer = LinkAnswer(requestId: "request1", choice: choice, phoneName: "iPhone", answeredAt: received)
            #expect(try LinkJSON.decode(LinkAnswer.self, from: try LinkJSON.encode(answer)) == answer)
        }
        let resolved = LinkResolved(requestId: "request1", outcome: .later, resolvedAt: received)
        #expect(try LinkJSON.decode(LinkResolved.self, from: try LinkJSON.encode(resolved)) == resolved)
    }

    /// An iPhone app from before `input` decodes requests with this switch. It must fail
    /// with a decoding error it already handles (the notification keeps the relay's
    /// generic text, the Requests list skips it), not crash.
    @Test func anOlderPhoneFailsCleanlyOnTheNewKind() throws {
        let data = try LinkJSON.encode(linkRequest(otp))
        #expect(throws: DecodingError.self) { try LinkJSON.decode(OlderLinkRequest.self, from: data) }
        // Everything an older phone already knows still decodes as before.
        let permission = LinkRequest(
            requestId: "request2", macName: "Studio",
            request: StewRequest(session: SessionInfo(name: "x"), prompt: .permission(PermissionRequest(action: "Deploy", reason: "Merged"))),
            receivedAt: received, deadline: deadline, queued: false, extendBy: 120, hardDeny: false, risk: nil
        )
        #expect(try LinkJSON.decode(OlderLinkRequest.self, from: try LinkJSON.encode(permission)).request.kind == "permission")
    }

    @Test func secretRequestCarriesNoValue() throws {
        let json = String(decoding: try LinkJSON.encode(linkRequest(otp)), as: UTF8.self)
        #expect(!json.contains("\"default\""))
        #expect(json.contains("\"secret\":true"))
    }
}

/// The request decoding of the iPhone app before `input`: the same keys, and a switch
/// that knows four kinds.
private struct OlderLinkRequest: Decodable {
    var requestId: String
    var request: OlderStewRequest
}

private struct OlderStewRequest: Decodable {
    var kind: String

    private enum CodingKeys: String, CodingKey { case kind, permission, notify, question, needs }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "permission": _ = try container.decode(PermissionRequest.self, forKey: .permission)
        case "notify": _ = try container.decode(NotifyRequest.self, forKey: .notify)
        case "question": _ = try container.decode(QuestionSet.self, forKey: .question)
        case "needs": _ = try container.decode(NeedsRequest.self, forKey: .needs)
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown kind \(kind)")
        }
    }
}
