import Foundation

/// The "phone" object in config.json: when an open request goes to the paired iPhones.
public struct PhoneConfig: Codable, Equatable, Sendable {
    public static let defaultRelay = "https://relay.stewcli.com"

    /// "away" (the Mac is idle or locked), "always" or "never".
    public var push: String
    /// Seconds a request must stay open before it goes to the phone.
    public var after: Double
    /// Seconds without keyboard or mouse input before the Mac counts as idle.
    public var idleAfter: Double
    /// Relay for new pairings. Existing pairings keep the relay they were made with.
    public var relay: String
    /// The longest a request's clock stays paused while it is open on a phone, in seconds.
    public var viewingCap: Double

    public init(
        push: String = PhonePushMode.away.rawValue, after: Double = 10, idleAfter: Double = 120, relay: String = PhoneConfig.defaultRelay,
        viewingCap: Double = ViewingPause.defaultCap
    ) {
        self.push = push
        self.after = after
        self.idleAfter = idleAfter
        self.relay = relay
        self.viewingCap = viewingCap
    }

    public init(from decoder: Decoder) throws {
        let defaults = PhoneConfig()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        push = try container.decodeIfPresent(String.self, forKey: .push) ?? defaults.push
        after = try container.decodeIfPresent(Double.self, forKey: .after) ?? defaults.after
        idleAfter = try container.decodeIfPresent(Double.self, forKey: .idleAfter) ?? defaults.idleAfter
        relay = try container.decodeIfPresent(String.self, forKey: .relay) ?? defaults.relay
        viewingCap = try container.decodeIfPresent(Double.self, forKey: .viewingCap) ?? defaults.viewingCap
    }

    /// An unknown value counts as the default, so a typo never pushes more than asked.
    public var mode: PhonePushMode { PhonePushMode(rawValue: push) ?? .away }
}

public enum PhonePushMode: String, Codable, Sendable, CaseIterable {
    case away, always, never
}

/// Whether someone is at the Mac, sampled when a push is considered.
public struct MacPresence: Equatable, Sendable {
    public var idleSeconds: Double
    public var screenLocked: Bool

    public init(idleSeconds: Double, screenLocked: Bool) {
        self.idleSeconds = idleSeconds
        self.screenLocked = screenLocked
    }
}

/// Who put an item in the panel: a caller on the socket (a hook, `stew notify`, a
/// question from Claude) or stew itself (an update notice, the return summary).
public enum ItemSource: Sendable {
    case caller
    case stew
}

public enum PushPolicy {
    /// A request goes to the phone once it has been open `after` seconds and, in "away"
    /// mode, nobody has touched the Mac for `idleAfter` seconds or the screen is locked.
    /// Someone at the Mac answers in the panel; a push would only be noise. stew's own
    /// notices never go: they are about this Mac, such as an update to install here or
    /// requests that timed out in its panel, and the phone has nothing to do with them.
    public static func shouldPush(source: ItemSource, config: PhoneConfig, openFor: TimeInterval, presence: MacPresence) -> Bool {
        guard source == .caller else { return false }
        switch config.mode {
        case .never:
            return false
        case .always:
            return openFor >= config.after
        case .away:
            return openFor >= config.after && (presence.screenLocked || presence.idleSeconds >= config.idleAfter)
        }
    }

    /// A needs item goes to the phone once it has been open `after` seconds, also while
    /// someone is at the Mac: it has no deadline, and the task often takes the user away
    /// from the desk. "Never" still sends nothing.
    public static func shouldPushNeeds(config: PhoneConfig, openFor: TimeInterval) -> Bool {
        config.mode != .never && openFor >= config.after
    }
}
