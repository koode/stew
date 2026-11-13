import Foundation
import Testing
@testable import StewCore

@Suite struct PhoneConfigTests {
    private let away = MacPresence(idleSeconds: 300, screenLocked: false)
    private let present = MacPresence(idleSeconds: 3, screenLocked: false)
    private let locked = MacPresence(idleSeconds: 3, screenLocked: true)

    @Test func defaults() throws {
        let config = try JSONDecoder().decode(StewConfig.self, from: Data("{}".utf8))
        #expect(config.phone == PhoneConfig())
        #expect(config.phone.mode == .away)
        #expect(config.phone.after == 10)
        #expect(config.phone.idleAfter == 120)
        #expect(config.phone.relay == "https://relay.stewcli.com")
    }

    @Test func partialPhoneObjectKeepsOtherDefaults() throws {
        let config = try JSONDecoder().decode(StewConfig.self, from: Data(#"{"phone":{"push":"always"}}"#.utf8))
        #expect(config.phone.mode == .always)
        #expect(config.phone.after == 10)
    }

    @Test func unknownModeFallsBackToAway() {
        #expect(PhoneConfig(push: "sometimes").mode == .away)
    }

    @Test func awayNeedsIdleOrLockAndTheWait() {
        let config = PhoneConfig()
        #expect(!PushPolicy.shouldPush(config: config, openFor: 9, presence: away))
        #expect(PushPolicy.shouldPush(config: config, openFor: 10, presence: away))
        #expect(!PushPolicy.shouldPush(config: config, openFor: 30, presence: present))
        #expect(PushPolicy.shouldPush(config: config, openFor: 30, presence: locked))
    }

    @Test func alwaysAndNever() {
        #expect(PushPolicy.shouldPush(config: PhoneConfig(push: "always"), openFor: 10, presence: present))
        #expect(!PushPolicy.shouldPush(config: PhoneConfig(push: "always"), openFor: 5, presence: present))
        #expect(!PushPolicy.shouldPush(config: PhoneConfig(push: "never"), openFor: 600, presence: locked))
    }

    @Test func needsItemsGoOutAfterTheWaitEvenWhileSomeoneIsAtTheMac() {
        #expect(!PushPolicy.shouldPushNeeds(config: PhoneConfig(), openFor: 9))
        #expect(PushPolicy.shouldPushNeeds(config: PhoneConfig(), openFor: 10))
        #expect(PushPolicy.shouldPushNeeds(config: PhoneConfig(push: "always"), openFor: 10))
        #expect(!PushPolicy.shouldPushNeeds(config: PhoneConfig(push: "never"), openFor: 600))
    }

    @Test func noWaitSendsAtOnce() {
        let instant = PhoneConfig(after: 0)
        #expect(PushPolicy.shouldPush(config: instant, openFor: 0, presence: away))
        #expect(!PushPolicy.shouldPush(config: instant, openFor: 0, presence: present))
        #expect(PushPolicy.shouldPushNeeds(config: instant, openFor: 0))
    }
}
