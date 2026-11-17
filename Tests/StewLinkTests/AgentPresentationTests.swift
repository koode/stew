import Foundation
import Testing
import StewCore
@testable import StewLink

private let received = Date(timeIntervalSince1970: 1_800_000_000)

private func request(agent: CodingAgent?, blocked: Bool = false) -> LinkRequest {
    let call = BlockedCall(toolName: "Bash", category: "Destructive", reason: "[Destructive]", hardDeny: false, projectRoot: "/tmp", suggestions: [])
    return LinkRequest(
        requestId: "request1",
        macName: "Studio",
        request: StewRequest(
            session: SessionInfo(name: "web-app", id: "019a", cwd: "/tmp", agent: agent),
            prompt: .permission(PermissionRequest(action: "Run a shell command", command: "pnpm add zod", reason: "No network", blocked: blocked ? call : nil))
        ),
        receivedAt: received,
        deadline: received.addingTimeInterval(60),
        queued: false,
        extendBy: 60,
        hardDeny: false,
        risk: nil
    )
}

@Suite struct AgentPresentationTests {
    @Test func phoneTextsNameTheAgentThatAsked() {
        let time: (Date) -> String = { _ in "10:00" }
        #expect(LinkRefusal.tooLate(macName: "Studio", deadline: received, agent: .codex, time: time)
            == "Too late: the request on Studio timed out at 10:00. Codex was told you did not respond in time.")
        #expect(LinkRefusal.tooLate(macName: "Studio", deadline: received, time: time)
            == "Too late: the request on Studio timed out at 10:00. Claude was told you did not respond in time.")
        #expect(LinkRefusal.closed(.movedOn, macName: "Studio", agent: .codex) == "Codex moved on from this.")
        #expect(LinkRefusal.closed(.answeredInSession, macName: "Studio", agent: .codex) == "You already answered this in the Codex session.")
        #expect(LinkRefusal.closed(.resolvedByClaude, macName: "Studio") == "Claude saw that this is done.")
        #expect(LinkRefusal.lateAnswerDetail(for: .codex) == "The request had timed out. Codex gets this answer at its next step, in place of the timeout.")
        #expect(LinkRefusal.lateAnswerDetail == LinkRefusal.lateAnswerDetail(for: .claudeCode))
        #expect(LinkOutcome.resolvedByClaude.label(for: .codex) == "Resolved by Codex")
        #expect(LinkOutcome.resolvedByClaude.label == "Resolved by Claude")
    }

    @Test func aTimedOutCodexRequestSaysCodexOnThePhone() {
        let late = request(agent: .codex)
        let answer = LinkRefusal.beforeSending(.moreTime, for: late, now: received.addingTimeInterval(120))
        #expect(answer == "Too late: the request on Studio timed out at \(received.addingTimeInterval(60).formatted(date: .omitted, time: .shortened)). Codex was told you did not respond in time.")
    }

    @Test func theClosedNotificationNamesTheAgent() {
        let resolved = LinkResolved(requestId: "request1", outcome: .movedOn)
        let content = LinkPresentation.closedNotification(resolved, request: request(agent: .codex), macName: "Studio", pairingId: "pair")
        #expect(content.body == "Moved on")
        let needsLine = LinkPresentation.closedLine(LinkResolved(requestId: "x", outcome: .resolvedByClaude), macName: "Studio", agent: .codex)
        #expect(needsLine == "Resolved by Codex")
    }

    @Test func aBlockedCallNamesTheAgentsLastMessage() {
        let claude = LinkPresentation.notification(for: request(agent: nil, blocked: true), pairingId: "pair") { _ in "10:00" }
        #expect(claude.body.contains("Claude's last message: No network"))
        let codex = LinkPresentation.notification(for: request(agent: .codex), pairingId: "pair") { _ in "10:00" }
        #expect(codex.body.contains("Why: No network"))
    }
}
