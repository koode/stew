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

@Suite struct AcknowledgeTests {
    @Test func okOnANotificationSendsDone() {
        let notify = request(.notify(NotifyRequest(title: "Tests passed", level: .success)))
        #expect(LinkPresentation.choice(forAction: LinkPresentation.acknowledgeAction, typedText: nil, request: notify) == .done)
        #expect(LinkRefusal.beforeSending(.done, for: notify, now: received) == nil)
    }

    @Test func okFitsNothingButANotification() {
        let needs = request(.needs(NeedsRequest(title: "Log in")))
        let permission = request(blocked(explained: false), deadline: received.addingTimeInterval(60))
        #expect(LinkPresentation.choice(forAction: LinkPresentation.acknowledgeAction, typedText: nil, request: needs) == nil)
        #expect(LinkPresentation.choice(forAction: LinkPresentation.acknowledgeAction, typedText: nil, request: permission) == nil)
        // Done on a notification from a notification action of a needs item stays a needs answer.
        #expect(LinkPresentation.choice(forAction: LinkPresentation.doneAction, typedText: nil, request: request(.notify(NotifyRequest(title: "Done")))) == nil)
    }
}
