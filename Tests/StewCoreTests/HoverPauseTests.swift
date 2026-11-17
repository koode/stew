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
        #expect(hover.nextChange(after: at(0.4)) == at(0.5))
        #expect(hover.isPausing(request, at: at(0.5)))
        // Once paused, the next change is the cap.
        #expect(hover.nextChange(after: at(0.5)) == at(0.5 + HoverPause.cap))
        // Repeated "entered" calls keep the first moment.
        hover.entered(at: at(0.4), requestID: request)
        #expect(hover.isPausing(request, at: at(0.5)))
    }

    @Test func aPointerPassingOverNeverPauses() {
        var hover = HoverPause()
        hover.entered(at: at(0), requestID: request)
        hover.exited(at: at(0.2))
        #expect(!hover.isPausing(request, at: at(1)))
        #expect(hover.nextChange(after: at(0.2)) == nil)
        #expect(hover.pausedTotal(at: at(1)) == 0)
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
        hover.exited(at: at(30))
        #expect(!hover.isPausing(request, at: at(30)))
        #expect(RequestClock.resumed(remaining: remaining, at: at(30), hardLimit: nil) == at(79.5))
    }

    @Test func hoveringPausesOneRequestForAtMostTheCapInAll() {
        var hover = HoverPause()
        hover.entered(at: at(0), requestID: request)
        hover.exited(at: at(4.5))
        #expect(hover.pausedTotal(at: at(10)) == 4)
        // Back on the card: the earlier 4 s count toward a 10 s cap.
        hover.entered(at: at(10), requestID: request)
        #expect(hover.isPausing(request, at: at(13), cap: 10))
        #expect(hover.nextChange(after: at(13), cap: 10) == at(16.5))
        #expect(hover.isPausing(request, at: at(16.4), cap: 10))
        #expect(!hover.isPausing(request, at: at(16.5), cap: 10))
        #expect(hover.nextChange(after: at(16.5), cap: 10) == nil)
        // Another request starts its own count.
        let other = UUID()
        hover.entered(at: at(20), requestID: other)
        #expect(hover.isPausing(other, at: at(21), cap: 10))
    }

    @Test func theCapIsTheViewingCap() {
        #expect(HoverPause.cap == ViewingPause.defaultCap)
        #expect(HoverPause.cap == 15 * 60)
    }

    @Test func theHardLimitStillEndsAPausedClock() {
        // Paused with 50 s left, but the caller's hard limit comes 20 s after the resume.
        #expect(RequestClock.resumed(remaining: 50, at: at(100), hardLimit: at(120)) == at(120))
        // A hard limit already passed during the pause ends it at once.
        #expect(RequestClock.resumed(remaining: 50, at: at(100), hardLimit: at(90)) == at(90))
        #expect(RequestClock.remaining(until: at(90), at: at(100)) == 0)
    }
}
