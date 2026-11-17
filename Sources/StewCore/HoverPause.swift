import Foundation

/// The pointer over the front request's card pauses its clock, the same way the note
/// field does: the clock runs again when the pointer leaves. It counts only once the
/// pointer has rested on the card for `delay`, so a pointer passing over on its way
/// somewhere else never touches the clock. It belongs to one request: when another one
/// takes the front, the pointer has to come onto its card again.
public struct HoverPause: Equatable, Sendable {
    public static let delay: TimeInterval = 0.5

    /// When the pointer came onto the card, and the request the card showed then.
    public private(set) var enteredAt: Date?
    public private(set) var requestID: UUID?

    public init() {}

    /// The pointer is on the card of `requestID`. Repeated calls keep the first moment.
    public mutating func entered(at now: Date, requestID: UUID) {
        guard enteredAt == nil || self.requestID != requestID else { return }
        enteredAt = now
        self.requestID = requestID
    }

    /// The pointer left the card: the pause, if any, ends at once.
    public mutating func exited() {
        enteredAt = nil
        requestID = nil
    }

    /// True once the pointer has rested on this request's card for `delay`.
    public func isPausing(_ requestID: UUID, at now: Date) -> Bool {
        guard let enteredAt, self.requestID == requestID else { return false }
        return now.timeIntervalSince(enteredAt) >= Self.delay
    }

    /// When the pause begins, while the pointer is on the card and it has not yet.
    public func pausesAt(after now: Date) -> Date? {
        guard let enteredAt else { return nil }
        let begins = enteredAt.addingTimeInterval(Self.delay)
        return begins > now ? begins : nil
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
