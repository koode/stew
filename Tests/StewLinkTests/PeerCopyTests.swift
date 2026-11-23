import Foundation
import Testing
import StewCore
@testable import StewLink

private let session = SessionInfo(name: "api")

private func permission() -> StewRequest {
    StewRequest(session: session, prompt: .permission(PermissionRequest(action: "Deploy", reason: "asked")))
}

@Test func panelAnswersToAPermissionGoBackAsThePhonesWould() {
    #expect(PeerCopy.choice(for: StewResponse(status: .approved), to: permission(), flow: nil) == .approve)
    #expect(PeerCopy.choice(for: StewResponse(status: .denied, note: "no"), to: permission(), flow: nil) == .deny)
    // Esc or a time-out here is no answer: the request stays open on the Mac that asked.
    #expect(PeerCopy.choice(for: StewResponse(status: .dismissed), to: permission(), flow: nil) == nil)
    #expect(PeerCopy.choice(for: StewResponse(status: .timeout), to: permission(), flow: nil) == nil)
}

@Test func typedAnswersKeepTheirKind() {
    let plain = StewRequest(session: session, prompt: .input(InputRequest(question: "Domain?")))
    let secret = StewRequest(session: session, prompt: .input(InputRequest(question: "Token?", secret: true)))
    #expect(PeerCopy.choice(for: StewResponse(status: .answered, text: "example.com"), to: plain, flow: nil) == .text("example.com"))
    #expect(PeerCopy.choice(for: StewResponse(status: .answered, text: "s3cret"), to: secret, flow: nil) == .secret("s3cret"))
    #expect(PeerCopy.choice(for: StewResponse(status: .later), to: secret, flow: nil) == .enterLater)
}

@Test func questionAnswersComeFromThePanelsSelections() throws {
    let set = QuestionSet(questions: [
        Question(question: "Which?", header: "Pick", options: [QuestionOption(label: "A", description: ""), QuestionOption(label: "B", description: "")]),
        Question(question: "And?", header: "More", options: [QuestionOption(label: "C", description: ""), QuestionOption(label: "D", description: "")], multiSelect: true),
    ])
    var flow = QuestionFlow(questions: set.questions)
    _ = flow.choose(1)
    flow.go(to: 1)
    _ = flow.choose(0)
    _ = flow.choose(1)
    let request = StewRequest(session: session, prompt: .question(set))
    let choice = try #require(PeerCopy.choice(for: StewResponse(status: .answered), to: request, flow: flow))
    #expect(choice == .answers([LinkQuestionAnswer(selected: [1]), LinkQuestionAnswer(selected: [0, 1])]))
    // The Mac that asked rebuilds the same answers from them.
    guard case .answers(let answers) = choice else { return }
    #expect(QuestionFlow(set: set, linkAnswers: answers)?.selections == flow.selections)
}

@Test func needsItemsStayWithTheirMac() {
    #expect(!PeerCopy.shows(StewRequest(session: session, prompt: .needs(NeedsRequest(title: "Sign in")), wait: false)))
    #expect(PeerCopy.shows(permission()))
}

@Test func aMacRegistersWithoutAPushToken() throws {
    let identity = LinkIdentity()
    let hello = LinkEnvelope(pairingId: "p", kind: .hello, sender: .phone, requestId: "pairing", messageId: "m", expiresAt: 0)
    let registration = RelayRegistration(registrationToken: "t", deviceToken: nil, environment: nil, phoneKeys: identity.publicKeys, hello: hello)
    let json = try #require(try JSONSerialization.jsonObject(with: LinkJSON.encode(registration)) as? [String: Any])
    #expect(json["deviceToken"] == nil)
    #expect(json["environment"] == nil)
}

@Test func theHelloSaysWhenTheDeviceIsAMac() throws {
    let keys = LinkIdentity().publicKeys
    let mac = try LinkJSON.decode(LinkHello.self, from: LinkJSON.encode(LinkHello(phoneName: "Studio", phoneKeys: keys, isMac: true)))
    #expect(mac.isMac == true)
    // The iPhone app sends no such field.
    let phone = try JSONSerialization.jsonObject(with: LinkJSON.encode(LinkHello(phoneName: "iPhone", phoneKeys: keys))) as? [String: Any]
    #expect(phone?["isMac"] == nil)
}

@Test func theHandedOverCodeTravelsAsAChoice() throws {
    let choice = LinkChoice.peerLink("stew://pair?code=abc")
    #expect(try LinkJSON.decode(LinkChoice.self, from: LinkJSON.encode(choice)) == choice)
    #expect(LinkPeer.requestId == "peer-link")
}
