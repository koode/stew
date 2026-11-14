import Foundation
import Testing
import StewCore
@testable import StewLink

private let received = Date(timeIntervalSince1970: 1_800_000_000)

private func permissionRequest(sessionId: String? = "abc") -> LinkRequest {
    LinkRequest(
        requestId: "request1",
        macName: "Studio",
        request: StewRequest(
            session: SessionInfo(name: "stew-build", id: sessionId, cwd: "/tmp"),
            prompt: .permission(PermissionRequest(action: "Deploy the relay", reason: "Testing"))
        ),
        receivedAt: received,
        deadline: received.addingTimeInterval(60),
        queued: false,
        extendBy: 120,
        hardDeny: false,
        risk: nil
    )
}

@Suite struct ClosedNotificationTests {
    @Test func linesNameWhereItWasAnswered() {
        func line(_ outcome: LinkOutcome, on phone: String? = nil, here: Bool? = nil) -> String {
            LinkPresentation.closedLine(LinkResolved(requestId: "request1", outcome: outcome, answeredOn: phone, answeredHere: here), macName: "Studio")
        }
        #expect(line(.answeredOnMac) == "Answered on Studio")
        #expect(line(.approved, on: "Sam's iPhone", here: false) == "Approved on Sam's iPhone")
        #expect(line(.denied, on: "Sam's iPhone", here: true) == "Denied on this iPhone")
        #expect(line(.answered, on: "Sam's iPhone", here: false) == "Answered on Sam's iPhone")
        #expect(line(.done, on: "Sam's iPhone", here: false) == "Marked done on Sam's iPhone")
        #expect(line(.timedOut) == "Timed out")
        #expect(line(.dismissed) == "Dismissed on Studio")
        #expect(line(.later) == "Waiting for you to enter it later")
        #expect(line(.resolvedByClaude) == "Resolved by Claude")
        // A Mac from before answeredOn: the outcome alone, never a guessed device.
        #expect(line(.approved) == "Approved")
        #expect(line(.done) == "Marked done")
    }

    @Test func timedOutSaysWhenTheAppCanStillAnswer() {
        let resolved = LinkResolved(requestId: "request1", outcome: .timedOut)
        let late = LinkPresentation.closedNotification(resolved, request: permissionRequest(), macName: "Studio", pairingId: "pair")
        #expect(late.body == "Timed out. Open stew to answer late.")
        let noSession = LinkPresentation.closedNotification(resolved, request: permissionRequest(sessionId: nil), macName: "Studio", pairingId: "pair")
        #expect(noSession.body == "Timed out")
    }

    @Test func replacesTheRequestWithoutActionsOrSound() {
        let request = permissionRequest()
        let original = LinkPresentation.notification(for: request, pairingId: "pair")
        let closed = LinkPresentation.closedNotification(
            LinkResolved(requestId: "request1", outcome: .answeredOnMac),
            request: request,
            macName: "Studio",
            pairingId: "pair"
        )
        #expect(closed.title == original.title)
        #expect(closed.subtitle == original.subtitle)
        #expect(closed.body == "Answered on Studio")
        #expect(closed.categoryIdentifier == LinkPresentation.closedCategory)
        #expect(closed.categoryIdentifier == "stew.closed")
        #expect(closed.actions.isEmpty)
        #expect(closed.passive)
        #expect(!closed.timeSensitive)
        #expect(closed.requestId == "request1")
        #expect(closed.threadIdentifier == "pair")
    }

    @Test func unknownRequestGetsAGenericTitle() {
        let closed = LinkPresentation.closedNotification(LinkResolved(requestId: "request9", outcome: .dismissed), request: nil, macName: "Studio", pairingId: "pair")
        #expect(closed.title == "stew")
        #expect(closed.subtitle == "Studio")
        #expect(closed.body == "Dismissed on Studio")
    }

    @Test func olderPhonesReadTheNewFields() throws {
        let resolved = LinkResolved(requestId: "request1", outcome: .approved, answeredOn: "Sam's iPhone", answeredHere: false)
        let decoded = try JSONDecoder().decode(LinkResolved.self, from: try JSONEncoder().encode(resolved))
        #expect(decoded == resolved)
        let older = try JSONDecoder().decode(LinkResolved.self, from: Data(#"{"requestId":"request1","outcome":"approved","resolvedAt":0}"#.utf8))
        #expect(older.answeredOn == nil)
        #expect(older.answeredHere == nil)
    }
}
