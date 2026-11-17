import Foundation
import Testing
import StewCore
@testable import StewLink

private let received = Date(timeIntervalSince1970: 1_800_000_000)

private func request(_ prompt: Prompt, risk: RiskAssessment? = nil, deadline: Date? = nil, explaining: Bool? = nil) -> LinkRequest {
    LinkRequest(
        requestId: "request1",
        macName: "Studio",
        request: StewRequest(session: SessionInfo(name: "stew-build", id: "abc", cwd: "/Users/someone/Projects/stew"), prompt: prompt),
        receivedAt: received,
        deadline: deadline,
        queued: false,
        extendBy: deadline == nil ? nil : 120,
        hardDeny: false,
        risk: risk,
        explaining: explaining
    )
}

private let explanation = RiskAssessment(
    verdict: .softDeny, risk: .high, rule: nil,
    summary: "Force-pushes over the shared main branch.",
    severity: .high, reversibility: "Others lose their commits; hard to undo.",
    riskyPart: "--force"
)

private func blocked(explained: Bool) -> Prompt {
    .permission(PermissionRequest(
        action: "Push to main",
        command: "git push --force origin main",
        reason: "Claude's last message",
        blocked: BlockedCall(
            toolName: "Bash", category: "Destructive or Unwanted Actions", reason: "[Destructive or Unwanted Actions]",
            hardDeny: false, projectRoot: "/Users/someone/Projects/stew", suggestions: [],
            explanation: explained ? explanation : nil
        )
    ))
}

@Suite struct BlockedExplanationTests {
    @Test func blockedCallTakesTheExplanationAsItsAssessment() {
        #expect(LinkPresentation.assessment(request(blocked(explained: true))) == explanation)
        #expect(LinkPresentation.assessment(request(blocked(explained: false))) == nil)
        let checked = RiskAssessment(verdict: .allow, risk: .low, rule: nil, summary: "Reads a file.")
        #expect(LinkPresentation.assessment(request(blocked(explained: true), risk: checked)) == checked)
    }

    @Test func notificationOfAnExplainedBlockShowsWhatIsRisky() {
        let content = LinkPresentation.notification(for: request(blocked(explained: true), deadline: received.addingTimeInterval(60)), pairingId: "pair")
        let lines = content.body.components(separatedBy: "\n")
        #expect(lines.prefix(4) == [
            "Auto mode blocked this · Destructive or Unwanted Actions",
            "Force-pushes over the shared main branch.",
            "High risk · Others lose their commits; hard to undo.",
            "Push to main",
        ])
        let unexplained = LinkPresentation.notification(for: request(blocked(explained: false), deadline: received.addingTimeInterval(60)), pairingId: "pair")
        #expect(unexplained.body.components(separatedBy: "\n").prefix(2) == ["Auto mode blocked this · Destructive or Unwanted Actions", "Push to main"])
    }

    @Test func explanationAndExplainingSurviveTheEnvelope() throws {
        let sent = request(blocked(explained: true), deadline: received.addingTimeInterval(60), explaining: true)
        let decoded = try LinkJSON.decode(LinkRequest.self, from: LinkJSON.encode(sent))
        #expect(decoded == sent)
        #expect(decoded.explaining == true)
        guard case .permission(let permission) = decoded.request.prompt else { Issue.record("not a permission"); return }
        #expect(permission.blocked?.explanation?.riskyPart == "--force")
    }

    @Test func requestFromAnOlderMacDecodesWithoutTheNewFields() throws {
        var object = try #require(JSONSerialization.jsonObject(with: LinkJSON.encode(request(blocked(explained: false)))) as? [String: Any])
        object["explaining"] = nil
        #expect(object.keys.contains("explaining") == false)
        let decoded = try LinkJSON.decode(LinkRequest.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.explaining == nil)
        #expect(LinkPresentation.assessment(decoded) == nil)
    }
}
