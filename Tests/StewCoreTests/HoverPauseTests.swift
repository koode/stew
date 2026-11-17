import Foundation
import Testing
@testable import StewCore

@Suite struct HoverPauseTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let request = UUID()

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    @Test func restingOnTheCardPausesAfterTheDelay() {
        var hover = HoverPause()
        hover.entered(at: at(0), requestID: request)
        #expect(!hover.isPausing(request, at: at(0.4)))
        #expect(hover.pausesAt(after: at(0.4)) == at(0.5))
        #expect(hover.isPausing(request, at: at(0.5)))
        #expect(hover.pausesAt(after: at(0.5)) == nil)
        // Repeated "entered" calls keep the first moment.
        hover.entered(at: at(0.4), requestID: request)
        #expect(hover.isPausing(request, at: at(0.5)))
    }

    @Test func aPointerPassingOverNeverPauses() {
        var hover = HoverPause()
        hover.entered(at: at(0), requestID: request)
        hover.exited()
        #expect(!hover.isPausing(request, at: at(1)))
        #expect(hover.pausesAt(after: at(0.2)) == nil)
    }

    @Test func anotherRequestAtTheFrontIsNotPaused() {
        var hover = HoverPause()
        hover.entered(at: at(0), requestID: request)
        #expect(!hover.isPausing(UUID(), at: at(2)))
    }

    @Test func leavingResumesWithTheTimeLeft() {
        var hover = HoverPause()
        let deadline = at(60)
        hover.entered(at: at(10), requestID: request)
        #expect(hover.isPausing(request, at: at(10.5)))
        let remaining = RequestClock.remaining(until: deadline, at: at(10.5))
        #expect(remaining == 49.5)
        hover.exited()
        #expect(!hover.isPausing(request, at: at(30)))
        #expect(RequestClock.resumed(remaining: remaining, at: at(30), hardLimit: nil) == at(79.5))
    }

    @Test func theHardLimitStillEndsAPausedClock() {
        // Paused with 50 s left, but the caller's hard limit comes 20 s after the resume.
        #expect(RequestClock.resumed(remaining: 50, at: at(100), hardLimit: at(120)) == at(120))
        // A hard limit already passed during the pause ends it at once.
        #expect(RequestClock.resumed(remaining: 50, at: at(100), hardLimit: at(90)) == at(90))
        #expect(RequestClock.remaining(until: at(90), at: at(100)) == 0)
    }
}
