import Foundation
import Testing
import StewCore
@testable import StewLink

private let received = Date(timeIntervalSince1970: 1_800_000_000)

private func severityRequest(_ severity: Severity?, confirmation: PhoneConfirmation?, extendBy: Double? = 120) -> LinkRequest {
    LinkRequest(
        requestId: "request1",
        macName: "Studio",
        request: StewRequest(
            session: SessionInfo(name: "stew-build", id: "abc", cwd: "/Users/someone/Projects/stew"),
            prompt: .permission(PermissionRequest(action: "Clean up downloads", command: "rm -rf ~/Downloads", reason: "Disk is full."))
        ),
        receivedAt: received,
        deadline: received.addingTimeInterval(60),
        queued: false,
        extendBy: extendBy,
        hardDeny: false,
        risk: severity.map { RiskAssessment(verdict: .allow, risk: .high, rule: nil, summary: "Deletes Downloads.", severity: $0, reversibility: "Deletes files permanently; no undo.") },
        confirmation: confirmation
    )
}

@Suite struct SeverityPresentationTests {
    @Test func notificationShowsTheChipAndTheLine() {
        let content = LinkPresentation.notification(for: severityRequest(.critical, confirmation: .hold), pairingId: "pair")
        #expect(content.body.hasPrefix("Critical risk · Deletes files permanently; no undo.\nClean up downloads"))
        let plain = LinkPresentation.notification(for: severityRequest(nil, confirmation: nil), pairingId: "pair")
        #expect(plain.body.hasPrefix("Clean up downloads"))
    }

    @Test func confirmationReplacesInlineApproveWithReview() {
        let request = severityRequest(.high, confirmation: .confirm)
        let roles = LinkPresentation.actions(request).map(\.role)
        #expect(roles == [.review, .deny, .moreTime])
        #expect(LinkPresentation.categoryIdentifier(request) == LinkPresentation.reviewCategory)
        #expect(LinkPresentation.categoryIdentifier(severityRequest(.high, confirmation: .confirm, extendBy: nil)) == LinkPresentation.reviewCategory + ".noTime")
        // A stale Approve action from an older category answers nothing.
        #expect(LinkPresentation.choice(forAction: LinkPresentation.approveAction, typedText: nil, request: request) == nil)
    }

    @Test func lowAndMediumKeepInlineApprove() {
        for severity in [Severity.low, .medium] {
            let request = severityRequest(severity, confirmation: nil)
            #expect(LinkPresentation.actions(request).first?.role == .approve)
            #expect(LinkPresentation.choice(forAction: LinkPresentation.approveAction, typedText: nil, request: request) == .approve)
        }
    }

    @Test func olderPhonesIgnoreTheNewFields() throws {
        let request = severityRequest(.critical, confirmation: .hold)
        let data = try JSONEncoder().encode(request)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["confirmation"] as? String == "hold")
        // A Mac from before severity sends neither field.
        var older = object
        older["confirmation"] = nil
        let decoded = try JSONDecoder().decode(LinkRequest.self, from: try JSONSerialization.data(withJSONObject: older))
        #expect(decoded.confirmation == nil)
        let answer = try JSONDecoder().decode(LinkAnswer.self, from: Data(#"{"requestId":"r","choice":{"approve":{}},"phoneName":"p","answeredAt":0}"#.utf8))
        #expect(answer.confirmed == nil)
    }
}
