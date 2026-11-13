import Foundation

/// A request open on a paired iPhone: its clock pauses while the user reads it there, as
/// it does while they type a note on the Mac. The pause ends a short grace period after
/// the phone says the user left the request, or at a cap counted from the first open, so
/// a phone left open on the request still times it out in the end.
public struct ViewingPause: Equatable, Sendable {
    /// After "left": time for the user to come back before the clock runs again.
    public static let grace: TimeInterval = 30
    public static let defaultCap: TimeInterval = 15 * 60

    public var phoneName: String
    public var pairingId: String
    /// The first open. The cap counts from here, so repeated opens cannot pause forever.
    public var started: Date
    /// When the phone said the user left. Nil while the request is on screen there.
    public var leftAt: Date?

    public init(phoneName: String, pairingId: String, started: Date, leftAt: Date? = nil) {
        self.phoneName = phoneName
        self.pairingId = pairingId
        self.started = started
        self.leftAt = leftAt
    }

    /// When the pause ends unless the phone says more: the cap while viewing, or the end
    /// of the grace period after "left", whichever comes first.
    public func endsAt(cap: TimeInterval, grace: TimeInterval = ViewingPause.grace) -> Date {
        let capEnd = started.addingTimeInterval(cap)
        guard let leftAt else { return capEnd }
        return min(leftAt.addingTimeInterval(grace), capEnd)
    }

    public func isActive(at now: Date, cap: TimeInterval, grace: TimeInterval = ViewingPause.grace) -> Bool {
        now < endsAt(cap: cap, grace: grace)
    }

    /// True when the pause ran into the cap while still viewing, rather than ending
    /// after "left": the request then times out instead of resuming its clock.
    public func reachedCap(at now: Date, cap: TimeInterval) -> Bool {
        leftAt == nil && now >= started.addingTimeInterval(cap)
    }

    /// The phone opened the request (again). Within the cap this pauses it again; past
    /// the cap it changes nothing.
    public mutating func viewed(at now: Date, phoneName: String, pairingId: String, cap: TimeInterval) {
        guard now < started.addingTimeInterval(cap) else { return }
        self.phoneName = phoneName
        self.pairingId = pairingId
        leftAt = nil
    }

    /// The phone left the request: the grace period starts. A "left" from another phone
    /// than the one viewing changes nothing.
    public mutating func left(at now: Date, pairingId: String) {
        guard pairingId == self.pairingId, leftAt == nil else { return }
        leftAt = now
    }
}

extension ViewingPause {
    /// What Claude reads when a request times out at the cap while open on the phone.
    public static func capNote(phoneName: String, cap: TimeInterval) -> String {
        return "The request was open on the user's iPhone (\(phoneName)) for \(durationText(cap)) without an answer, the longest stew pauses the clock for."
    }

    /// "1 minute", "15 minutes", or seconds below a minute.
    static func durationText(_ seconds: TimeInterval) -> String {
        guard seconds >= 60 else {
            let whole = max(1, Int(seconds.rounded()))
            return whole == 1 ? "1 second" : "\(whole) seconds"
        }
        let minutes = Int((seconds / 60).rounded())
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}
