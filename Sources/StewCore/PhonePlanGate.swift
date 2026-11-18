import Foundation

/// Whether Settings ▸ iPhone offers to pair an iPhone, or asks for stew Pro first. Only a
/// relay that refuses Macs without a plan closes it: there a claim without a lease answers
/// 402, so offering a pairing code would only lead to an error.
public enum PhonePlanGate: Equatable, Sendable {
    case open
    /// The relay needs a plan and the account on this Mac has none, or nobody is signed in.
    case needsPro(signedIn: Bool)

    public static let title = "stew on iPhone is available with stew Pro"
    public static let subscribe = "Subscribe now"

    /// `relayRequiresPlan` is nil while the relay has not answered; the relay still refuses
    /// the claim then, so the gate stays open rather than block pairing on a slow network.
    public static func decide(relayRequiresPlan: Bool?, account: Account?) -> PhonePlanGate {
        guard relayRequiresPlan == true, account?.entitled != true else { return .open }
        return .needsPro(signedIn: account != nil)
    }

    /// The text under the title, or nil when the gate is open.
    public var message: String? {
        switch self {
        case .open:
            return nil
        case .needsPro(signedIn: false):
            return "Requests that stay open while you are away go to your iPhone. A new stew account starts with a free trial, no card needed."
        case .needsPro(signedIn: true):
            return "Requests that stay open while you are away go to your iPhone. Subscribe to pair an iPhone with this Mac."
        }
    }
}
