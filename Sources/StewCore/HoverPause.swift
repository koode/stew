import Foundation

/// The pointer over the front request's card pauses its clock, the same way the note
/// field does: the clock runs again when the pointer leaves. It counts only once the
/// pointer has rested on the card for `delay`, so a pointer passing over on its way
/// somewhere else never touches the clock. It belongs to one request: when another one
/// takes the front, the pointer has to come onto its card again. Hovering pauses one
/// request for at most `cap` in all; after that its clock runs, hovered or not.
public struct HoverPause: Equatable, Sendable {
    public static let delay: TimeInterval = 0.5
    /// A pointer left on the card while the user walks away must not hold a request
    /// without a hard limit forever. The same bound as a request kept open on a phone.
    public static let cap: TimeInterval = ViewingPause.defaultCap

    /// When the pointer came onto the card, while it is there.
    public private(set) var enteredAt: Date?
    /// The request whose card the pointer was on last.
    public private(set) var requestID: UUID?
    /// Seconds this request was paused by hovering before the current stretch.
    public private(set) var pausedBefore: TimeInterval = 0

    public init() {}

    /// The pointer is on the card of `requestID`. Repeated calls keep the first moment;
    /// another request starts its own count.
    public mutating func entered(at now: Date, requestID: UUID) {
        if self.requestID != requestID {
            self.requestID = requestID
            pausedBefore = 0
            enteredAt = now
        } else if enteredAt == nil {
            enteredAt = now
        }
    }

    /// The pointer left the card: the pause, if any, ends at once, and counts toward `cap`.
    public mutating func exited(at now: Date) {
        pausedBefore += stretch(at: now)
        enteredAt = nil
    }

    /// Seconds hovering has paused the request so far, the current stretch included.
    public func pausedTotal(at now: Date) -> TimeInterval {
        pausedBefore + stretch(at: now)
    }

    /// True while the pointer has rested on this request's card for `delay` and the
    /// request has not used up `cap`.
    public func isPausing(_ requestID: UUID, at now: Date, cap: TimeInterval = Self.cap) -> Bool {
        guard let enteredAt, self.requestID == requestID else { return false }
        return now.timeIntervalSince(enteredAt) >= Self.delay && pausedTotal(at: now) < cap
    }

    /// When the pause next begins or ends by itself while the pointer stays on the card:
    /// after `delay`, then at `cap`. Nil: nothing changes until the pointer moves.
    public func nextChange(after now: Date, cap: TimeInterval = Self.cap) -> Date? {
        guard let enteredAt else { return nil }
        let begins = enteredAt.addingTimeInterval(Self.delay)
        if begins > now { return begins }
        let left = cap - pausedTotal(at: now)
        return left > 0 ? now.addingTimeInterval(left) : nil
    }

    private func stretch(at now: Date) -> TimeInterval {
        guard let enteredAt else { return 0 }
        return max(0, now.timeIntervalSince(enteredAt.addingTimeInterval(Self.delay)))
    }
}

/// Pausing and resuming a request's clock. Pausing keeps the time left; resuming gives
/// it back, never past the caller's hard limit (`maxWait`), which a pause cannot move.
public enum RequestClock {
    public static func remaining(until deadline: Date, at now: Date) -> TimeInterval {
        max(0, deadline.timeIntervalSince(now))
    }

    public static func resumed(remaining: TimeInterval, at now: Date, hardLimit: Date?) -> Date {
        let deadline = now.addingTimeInterval(remaining)
        return hardLimit.map { min(deadline, $0) } ?? deadline
    }
}
