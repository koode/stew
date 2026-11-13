import Foundation
import Testing
@testable import StewCore

@Suite struct ViewingPauseTests {
    private let opened = Date(timeIntervalSince1970: 1_800_000_000)
    private let cap: TimeInterval = 15 * 60

    private func pause() -> ViewingPause {
        ViewingPause(phoneName: "Abby's iPhone", pairingId: "pair1", started: opened)
    }

    @Test func pausesUntilTheCapWhileOpen() {
        let viewing = pause()
        #expect(viewing.isActive(at: opened.addingTimeInterval(cap - 1), cap: cap))
        #expect(!viewing.isActive(at: opened.addingTimeInterval(cap), cap: cap))
        #expect(viewing.reachedCap(at: opened.addingTimeInterval(cap), cap: cap))
    }

    @Test func leavingEndsItAfterTheGrace() {
        var viewing = pause()
        let leftAt = opened.addingTimeInterval(60)
        viewing.left(at: leftAt, pairingId: "pair1")
        #expect(viewing.isActive(at: leftAt.addingTimeInterval(ViewingPause.grace - 1), cap: cap))
        #expect(!viewing.isActive(at: leftAt.addingTimeInterval(ViewingPause.grace), cap: cap))
        // Ending after "left" resumes the clock; it is not the cap.
        #expect(!viewing.reachedCap(at: leftAt.addingTimeInterval(ViewingPause.grace), cap: cap))
    }

    @Test func graceNeverRunsPastTheCap() {
        var viewing = pause()
        viewing.left(at: opened.addingTimeInterval(cap - 5), pairingId: "pair1")
        #expect(viewing.endsAt(cap: cap) == opened.addingTimeInterval(cap))
    }

    @Test func reopeningExtendsWithinTheCapOnly() {
        var viewing = pause()
        viewing.left(at: opened.addingTimeInterval(60), pairingId: "pair1")
        viewing.viewed(at: opened.addingTimeInterval(120), phoneName: "Abby's iPhone", pairingId: "pair1", cap: cap)
        #expect(viewing.leftAt == nil)
        #expect(viewing.endsAt(cap: cap) == opened.addingTimeInterval(cap))

        viewing.left(at: opened.addingTimeInterval(200), pairingId: "pair1")
        viewing.viewed(at: opened.addingTimeInterval(cap + 10), phoneName: "Abby's iPhone", pairingId: "pair1", cap: cap)
        #expect(viewing.leftAt != nil)
        #expect(!viewing.isActive(at: opened.addingTimeInterval(cap + 10), cap: cap))
    }

    @Test func onlyThePhoneViewingCanLeave() {
        var viewing = pause()
        viewing.left(at: opened.addingTimeInterval(60), pairingId: "other")
        #expect(viewing.leftAt == nil)
    }

    @Test func aSecondPhoneTakesOverTheView() {
        var viewing = pause()
        viewing.viewed(at: opened.addingTimeInterval(30), phoneName: "Sam's iPhone", pairingId: "pair2", cap: cap)
        #expect(viewing.phoneName == "Sam's iPhone")
        #expect(viewing.started == opened)
    }

    @Test func capNoteSaysWhy() {
        #expect(ViewingPause.capNote(phoneName: "Abby's iPhone", cap: cap)
            == "The request was open on the user's iPhone (Abby's iPhone) for 15 minutes without an answer, the longest stew pauses the clock for.")
    }

    @Test func capIsASettingWithADefault() throws {
        #expect(PhoneConfig().viewingCap == 900)
        let config = try JSONDecoder().decode(PhoneConfig.self, from: Data(#"{"viewingCap":300}"#.utf8))
        #expect(config.viewingCap == 300)
        #expect(try JSONDecoder().decode(PhoneConfig.self, from: Data("{}".utf8)).viewingCap == 900)
    }
}
