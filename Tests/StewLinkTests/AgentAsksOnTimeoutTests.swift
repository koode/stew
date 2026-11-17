import Foundation
import Testing
import StewCore
@testable import StewLink

private let received = Date(timeIntervalSince1970: 1_800_000_000)

private func codexApproval(agentAsksOnTimeout: Bool?) -> LinkRequest {
    LinkRequest(
        requestId: "request1",
        macName: "Studio",
        request: StewRequest(
            session: SessionInfo(name: "web-app", id: "019a", cwd: "/tmp", agent: .codex),
            prompt: .permission(PermissionRequest(action: "Run a shell command", command: "pnpm add zod", reason: "No network")),
            origin: RequestOrigin(agentAsksOnTimeout: agentAsksOnTimeout)
        ),
        receivedAt: received,
        deadline: received.addingTimeInterval(60),
        queued: false,
        extendBy: 60,
        hardDeny: false,
        risk: nil,
        agentAsksOnTimeout: agentAsksOnTimeout
    )
}

@Suite struct AgentAsksOnTimeoutTests {
    @Test func theFieldTravelsAndOlderPayloadsLeaveItOut() throws {
        let encoded = try JSONEncoder().encode(codexApproval(agentAsksOnTimeout: true))
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["agentAsksOnTimeout"] as? Bool == true)
        #expect(try JSONDecoder().decode(LinkRequest.self, from: encoded).agentAsksOnTimeout == true)

        // A request without the flag, as an older Mac sends it, has no key at all.
        let without = try JSONEncoder().encode(codexApproval(agentAsksOnTimeout: nil))
        let plain = try #require(try JSONSerialization.jsonObject(with: without) as? [String: Any])
        #expect(plain["agentAsksOnTimeout"] == nil)
        #expect(try JSONDecoder().decode(LinkRequest.self, from: without).agentAsksOnTimeout == nil)
    }

    @Test func anOlderPhoneDecodesTheRequestAndIgnoresTheField() throws {
        // The fields an older phone's LinkRequest knows, with the new one beside them.
        struct OlderLinkRequest: Decodable {
            var requestId: String
            var macName: String
            var request: StewRequest
            var deadline: Date?
            var hardDeny: Bool
        }
        let encoded = try JSONEncoder().encode(codexApproval(agentAsksOnTimeout: true))
        let older = try JSONDecoder().decode(OlderLinkRequest.self, from: encoded)
        #expect(older.requestId == "request1")
        #expect(!older.hardDeny)
    }

    @Test func aTimedOutCodexApprovalOffersNoLateAnswer() {
        let codex = codexApproval(agentAsksOnTimeout: true)
        #expect(!LinkPresentation.canAnswerLate(codex))
        let resolved = LinkResolved(requestId: "request1", outcome: .timedOut)
        let closed = LinkPresentation.closedNotification(resolved, request: codex, macName: "Studio", pairingId: "pair")
        #expect(closed.body == "Timed out")
        // The phone refuses a late Approve before sending it.
        #expect(LinkRefusal.beforeSending(.approve, for: codex, now: received.addingTimeInterval(120))?.hasPrefix("Too late") == true)

        // The same request from a Mac without the field: answerable late, as before.
        let fromOlderMac = codexApproval(agentAsksOnTimeout: nil)
        #expect(LinkPresentation.canAnswerLate(fromOlderMac))
        #expect(LinkPresentation.closedNotification(resolved, request: fromOlderMac, macName: "Studio", pairingId: "pair").body == "Timed out. Open stew to answer late.")
    }
}

@Suite struct AgentAsksOnTimeoutWordingTests {
    @Test func codexIsNotToldItAsksInItsOwnPrompt() {
        let time: (Date) -> String = { _ in "10:00" }
        #expect(LinkRefusal.tooLate(macName: "Studio", deadline: received, agent: .codex, agentAsksOnTimeout: true, time: time)
            == "Too late: the request on Studio timed out at 10:00. Codex asks in its own prompt instead.")
        #expect(LinkRefusal.closed(.timedOut, macName: "Studio", agent: .codex, agentAsksOnTimeout: true)
            == "Too late: the request on Studio timed out. Codex asks in its own prompt instead.")
        // Other requests, and Codex's own stew calls, keep the timeout note wording.
        #expect(LinkRefusal.closed(.timedOut, macName: "Studio", agent: .codex)
            == "Too late: the request on Studio timed out. Codex was told you did not respond in time.")
        #expect(LinkRefusal.tooLate(macName: "Studio", deadline: received, time: time)
            == "Too late: the request on Studio timed out at 10:00. Claude was told you did not respond in time.")
    }

    @Test func thePhoneSaysSoBeforeSendingALateAnswer() {
        let refusal = LinkRefusal.beforeSending(.approve, for: codexApproval(agentAsksOnTimeout: true), now: received.addingTimeInterval(120))
        #expect(refusal?.hasSuffix("Codex asks in its own prompt instead.") == true)
    }
}
