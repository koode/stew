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

    @Test func offersTheDefaultAndTheNextRelay() {
        #expect(PhoneConfig.offeredRelays == ["https://relay.stewcli.com", "https://relay-next.stewcli.com"])
        #expect(PhoneConfig.offeredRelay("https://relay-next.stewcli.com") == PhoneConfig.nextRelay)
        #expect(PhoneConfig.offeredRelay(" https://Relay.stewcli.com/ ") == PhoneConfig.defaultRelay)
    }

    @Test func otherRelaysAreNotOfferedButStillLoad() throws {
        #expect(PhoneConfig.offeredRelay("http://localhost:4000") == nil)
        #expect(PhoneConfig.offeredRelay("https://relay.stewcli.com.example.org") == nil)
        let config = try JSONDecoder().decode(StewConfig.self, from: Data(#"{"phone":{"relay":"http://localhost:4000"}}"#.utf8))
        #expect(config.phone.relay == "http://localhost:4000")
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
        #expect(!PushPolicy.shouldPush(source: .caller, config: config, openFor: 9, presence: away))
        #expect(PushPolicy.shouldPush(source: .caller, config: config, openFor: 10, presence: away))
        #expect(!PushPolicy.shouldPush(source: .caller, config: config, openFor: 30, presence: present))
        #expect(PushPolicy.shouldPush(source: .caller, config: config, openFor: 30, presence: locked))
    }

    @Test func alwaysAndNever() {
        #expect(PushPolicy.shouldPush(source: .caller, config: PhoneConfig(push: "always"), openFor: 10, presence: present))
        #expect(!PushPolicy.shouldPush(source: .caller, config: PhoneConfig(push: "always"), openFor: 5, presence: present))
        #expect(!PushPolicy.shouldPush(source: .caller, config: PhoneConfig(push: "never"), openFor: 600, presence: locked))
    }

    @Test func stewsOwnNoticesStayOnTheMac() {
        let always = PhoneConfig(push: "always")
        #expect(PushPolicy.shouldPush(source: .caller, config: always, openFor: 600, presence: locked))
        #expect(!PushPolicy.shouldPush(source: .stew, config: always, openFor: 600, presence: locked))
        #expect(!PushPolicy.shouldPush(source: .stew, config: PhoneConfig(), openFor: 600, presence: away))
    }

    @Test func aRequestAnsweredOnTheMacNeverGoes() {
        let always = PhoneConfig(push: "always")
        #expect(!PushPolicy.shouldPush(source: .caller, config: always, openFor: 600, presence: locked, engagedOnMac: true))
        #expect(!PushPolicy.shouldPush(source: .caller, config: PhoneConfig(), openFor: 600, presence: away, engagedOnMac: true))
    }

    @Test func needsItemsGoOutAfterTheWaitEvenWhileSomeoneIsAtTheMac() {
        #expect(!PushPolicy.shouldPushNeeds(config: PhoneConfig(), openFor: 9))
        #expect(PushPolicy.shouldPushNeeds(config: PhoneConfig(), openFor: 10))
        #expect(PushPolicy.shouldPushNeeds(config: PhoneConfig(push: "always"), openFor: 10))
        #expect(!PushPolicy.shouldPushNeeds(config: PhoneConfig(push: "never"), openFor: 600))
    }

    @Test func noWaitSendsAtOnce() {
        let instant = PhoneConfig(after: 0)
        #expect(PushPolicy.shouldPush(source: .caller, config: instant, openFor: 0, presence: away))
        #expect(!PushPolicy.shouldPush(source: .caller, config: instant, openFor: 0, presence: present))
        #expect(PushPolicy.shouldPushNeeds(config: instant, openFor: 0))
    }
}
