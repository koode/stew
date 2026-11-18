import Foundation
import Testing
@testable import StewCore

struct PhonePlanGateTests {
    private func account(entitled: Bool) -> Account {
        let status: AccountPlanStatus = entitled ? .trial : .expired
        return Account(id: "acc_sample", email: "abby@example.com", plan: AccountPlan(status: status), entitled: entitled)
    }

    @Test func aRelayWithoutPlansAlwaysOffersPairing() {
        #expect(PhonePlanGate.decide(relayRequiresPlan: false, account: nil) == .open)
        #expect(PhonePlanGate.decide(relayRequiresPlan: false, account: account(entitled: false)) == .open)
    }

    @Test func aRelayThatHasNotAnsweredOffersPairing() {
        #expect(PhonePlanGate.decide(relayRequiresPlan: nil, account: nil) == .open)
    }

    @Test func aRelayWithPlansAsksForProWithoutAnEntitledAccount() {
        #expect(PhonePlanGate.decide(relayRequiresPlan: true, account: nil) == .needsPro(signedIn: false))
        #expect(PhonePlanGate.decide(relayRequiresPlan: true, account: account(entitled: false)) == .needsPro(signedIn: true))
        #expect(PhonePlanGate.decide(relayRequiresPlan: true, account: account(entitled: true)) == .open)
    }

    @Test func onlyTheSignedOutMessageMentionsTheTrial() {
        #expect(PhonePlanGate.open.message == nil)
        #expect(PhonePlanGate.needsPro(signedIn: false).message?.contains("free trial") == true)
        #expect(PhonePlanGate.needsPro(signedIn: true).message?.contains("free trial") == false)
    }
}
