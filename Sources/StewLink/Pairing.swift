import CryptoKit
import Foundation

/// What the Mac's QR code holds. The pairing secret is the one value the relay never sees:
/// it salts the encryption key and derives the one-time registration token.
public struct PairingCode: Codable, Equatable, Sendable {
    public static let scheme = "stew"
    static let prefix = "stew://pair?code="

    /// Relay base URL, such as https://relay.stewcli.com.
    public var relay: String
    public var pairingId: String
    public var macName: String
    public var macKeys: LinkPublicKeys
    public var secret: Data

    public init(relay: String, pairingId: String, macName: String, macKeys: LinkPublicKeys, secret: Data) {
        self.relay = relay
        self.pairingId = pairingId
        self.macName = macName
        self.macKeys = macKeys
        self.secret = secret
    }

    public static func generate(relay: String, macName: String, macKeys: LinkPublicKeys) -> PairingCode {
        PairingCode(relay: relay, pairingId: LinkRandom.identifier(), macName: macName, macKeys: macKeys, secret: LinkRandom.bytes(32))
    }

    private enum CodingKeys: String, CodingKey {
        case relay = "r", pairingId = "p", macName = "n", macKeys = "k", secret = "s"
    }

    /// A stew:// link, so the iOS Camera app also opens the stew app with it. The same text
    /// is the manual code: copy it on the Mac and paste it on the phone.
    public var text: String {
        let json = (try? LinkJSON.encode(self)) ?? Data()
        return Self.prefix + json.base64URLEncoded
    }

    public struct InvalidCode: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    public init(text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.prefix) else { throw InvalidCode(description: "This is not a stew pairing code.") }
        guard let json = Data(base64URLEncoded: String(trimmed.dropFirst(Self.prefix.count))),
              let decoded = try? LinkJSON.decode(PairingCode.self, from: json) else {
            throw InvalidCode(description: "The pairing code is incomplete. Copy it again on your Mac.")
        }
        guard LinkEnvelope.isValidIdentifier(decoded.pairingId), decoded.secret.count == 32,
              (try? decoded.macKeys.validated()) != nil else {
            throw InvalidCode(description: "The pairing code is damaged. Show a new one on your Mac.")
        }
        guard let url = URL(string: decoded.relay), let urlScheme = url.scheme, ["https", "http"].contains(urlScheme), url.host != nil else {
            throw InvalidCode(description: "The pairing code has no valid relay address.")
        }
        self = decoded
    }

    /// Proves to the relay that the phone saw this code. The relay keeps only its SHA-256
    /// and forgets it after one use, so the code pairs one phone.
    public var registrationToken: String {
        Self.derive(secret, info: "stew-link/1 registration").base64URLEncoded
    }

    public var registrationTokenHash: String {
        Data(SHA256.hash(data: Data(registrationToken.utf8))).hexEncoded
    }

    /// Six digits both screens show while pairing. They match only when both devices hold
    /// the same secret and see each other's real signing keys.
    public func verificationCode(phoneSigning: Data) -> String {
        var input = Data("stew-link/1 verify".utf8)
        input += secret + macKeys.signing + phoneSigning
        let digest = Array(SHA256.hash(data: input))
        let number = (UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])) % 1_000_000
        let digits = String(format: "%06u", number)
        return digits.prefix(3) + " " + digits.suffix(3)
    }

    static func derive(_ secret: Data, info: String) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), info: Data(info.utf8), outputByteCount: 32)
            .withUnsafeBytes { Data($0) }
    }
}

/// Signed strings for relay calls that carry no envelope. The relay checks them against
/// the key stored for that side of the pairing, and refuses a timestamp more than five
/// minutes off its own clock. v1 signs these texts and sends them in the body or query; v2
/// signs one text per call in the `authorization` header (RelayProtocol.swift).
public enum RelayAuth {
    public static let allowedSkew: TimeInterval = 300

    public static func claimMessage(pairingId: String, registrationTokenHash: String, timestamp: Int) -> Data {
        Data("stew-link/1 claim\n\(pairingId)\n\(registrationTokenHash)\n\(timestamp)".utf8)
    }

    public static func socketMessage(pairingId: String, timestamp: Int) -> Data {
        Data("stew-link/1 socket\n\(pairingId)\n\(timestamp)".utf8)
    }

    public static func pendingMessage(pairingId: String, timestamp: Int) -> Data {
        Data("stew-link/1 pending\n\(pairingId)\n\(timestamp)".utf8)
    }

    public static func deviceMessage(pairingId: String, deviceToken: String, environment: String, timestamp: Int) -> Data {
        Data("stew-link/1 device\n\(pairingId)\n\(deviceToken)\n\(environment)\n\(timestamp)".utf8)
    }

    /// `?ts=…&sig=…` for a GET, with the signature as base64url.
    public static func query(signing message: (Int) -> Data, identity: LinkIdentity, now: Date = Date()) throws -> String {
        let timestamp = Int(now.timeIntervalSince1970)
        let signature = try identity.sign(message(timestamp))
        return "ts=\(timestamp)&sig=\(signature.base64URLEncoded)"
    }
}

/// Body of the Mac's claim on a pairing id, sent when it shows the QR code.
public struct RelayClaim: Codable, Equatable, Sendable {
    public var macSigningKey: Data
    public var registrationTokenHash: String
    public var timestamp: Int
    public var signature: Data

    public init(code: PairingCode, identity: LinkIdentity, now: Date = Date()) throws {
        macSigningKey = identity.publicKeys.signing
        registrationTokenHash = code.registrationTokenHash
        timestamp = Int(now.timeIntervalSince1970)
        signature = try identity.sign(RelayAuth.claimMessage(pairingId: code.pairingId, registrationTokenHash: registrationTokenHash, timestamp: timestamp))
    }
}

/// Body of the phone's first registration: its push token, its public keys and the
/// sealed hello the relay passes on to the Mac.
public struct RelayRegistration: Codable, Equatable, Sendable {
    public var registrationToken: String
    /// Nil for a Mac in the phone's part: it has no push token and takes its frames on
    /// the phone socket instead.
    public var deviceToken: String?
    /// "production" or "sandbox": which APNs host the relay sends to. Nil with no token.
    public var environment: String?
    public var phoneKeys: LinkPublicKeys
    public var hello: LinkEnvelope

    public init(registrationToken: String, deviceToken: String?, environment: String?, phoneKeys: LinkPublicKeys, hello: LinkEnvelope) {
        self.registrationToken = registrationToken
        self.deviceToken = deviceToken
        self.environment = environment
        self.phoneKeys = phoneKeys
        self.hello = hello
    }
}

/// Body of a later push token change, signed by the phone's key.
public struct RelayDeviceUpdate: Codable, Equatable, Sendable {
    public var deviceToken: String
    public var environment: String
    public var timestamp: Int
    public var signature: Data

    public init(pairingId: String, deviceToken: String, environment: String, identity: LinkIdentity, now: Date = Date()) throws {
        self.deviceToken = deviceToken
        self.environment = environment
        timestamp = Int(now.timeIntervalSince1970)
        signature = try identity.sign(RelayAuth.deviceMessage(pairingId: pairingId, deviceToken: deviceToken, environment: environment, timestamp: timestamp))
    }
}

/// One frame from the relay on the Mac's WebSocket: v1 names its type `type`, v2 names it
/// `t` and adds the pairing id and the frame's `seq`.
public struct RelayFrame: Codable, Equatable, Sendable {
    public enum FrameType: String, Codable, Sendable {
        /// An envelope from the phone: an answer or an unpair.
        case envelope
        /// A phone registered with this pairing's code; carries its keys and sealed hello.
        case hello
    }

    public var type: FrameType
    public var envelope: LinkEnvelope
    public var phoneKeys: LinkPublicKeys?
    /// v2 only: the frame's place in the pairing's queue, which the Mac acks.
    public var seq: Int?
    /// v2 only.
    public var pairingId: String?

    public init(type: FrameType, envelope: LinkEnvelope, phoneKeys: LinkPublicKeys? = nil, seq: Int? = nil, pairingId: String? = nil) {
        self.type = type
        self.envelope = envelope
        self.phoneKeys = phoneKeys
        self.seq = seq
        self.pairingId = pairingId
    }

    private enum CodingKeys: String, CodingKey {
        case type, t, envelope, phoneKeys, seq, pairingId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let type = try container.decodeIfPresent(FrameType.self, forKey: .t) {
            self.type = type
        } else {
            type = try container.decode(FrameType.self, forKey: .type)
        }
        envelope = try container.decode(LinkEnvelope.self, forKey: .envelope)
        phoneKeys = try container.decodeIfPresent(LinkPublicKeys.self, forKey: .phoneKeys)
        seq = try container.decodeIfPresent(Int.self, forKey: .seq)
        pairingId = try container.decodeIfPresent(String.self, forKey: .pairingId)
    }

    /// Encodes as v2 when the frame has a seq, else as v1.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: seq == nil ? .type : .t)
        try container.encode(envelope, forKey: .envelope)
        try container.encodeIfPresent(phoneKeys, forKey: .phoneKeys)
        try container.encodeIfPresent(seq, forKey: .seq)
        try container.encodeIfPresent(pairingId, forKey: .pairingId)
    }
}

/// What GET /pending returns to the phone: open requests and recent outcomes.
public struct RelayPending: Codable, Equatable, Sendable {
    public var requests: [LinkEnvelope]
    public var resolved: [LinkEnvelope]

    public init(requests: [LinkEnvelope], resolved: [LinkEnvelope]) {
        self.requests = requests
        self.resolved = resolved
    }
}

/// What POST /messages returns for a phone's answer: the Mac's signed result.
public struct RelayAnswerReply: Codable, Equatable, Sendable {
    public var result: LinkEnvelope

    public init(result: LinkEnvelope) {
        self.result = result
    }
}

/// The `stew` object in an APNs payload, as the relay writes it.
public struct RelayPush: Codable, Equatable, Sendable {
    public var pairingId: String
    public var requestId: String
    public var kind: LinkKind
    /// Absent when the envelope would not fit the 4 KB push limit; then the extension
    /// fetches it from GET /pending.
    public var envelope: LinkEnvelope?

    public init(pairingId: String, requestId: String, kind: LinkKind, envelope: LinkEnvelope?) {
        self.pairingId = pairingId
        self.requestId = requestId
        self.kind = kind
        self.envelope = envelope
    }
}

/// A Mac as the phone stores it: the code it scanned, and the name the user gave it.
public struct PhonePairing: Codable, Equatable, Identifiable, Sendable {
    public var id: String { code.pairingId }
    public var code: PairingCode
    /// Starts as the Mac's own name; the user can rename it on the phone.
    public var displayName: String
    public var pairedAt: Date

    public init(code: PairingCode, displayName: String? = nil, pairedAt: Date = Date()) {
        self.code = code
        self.displayName = displayName ?? code.macName
        self.pairedAt = pairedAt
    }

    public func channel(identity: LinkIdentity) throws -> LinkChannel {
        try LinkChannel(pairingId: code.pairingId, side: .phone, identity: identity, peer: code.macKeys, pairingSecret: code.secret)
    }
}

/// A ready-made phone state for simulator checks and screenshots: the debug build of the
/// app installs it from a launch argument instead of pairing through a relay.
public struct PhoneSeed: Codable, Equatable, Sendable {
    public var phoneName: String
    public var identity: LinkIdentity.Stored
    public var pairings: [PhonePairing]

    public init(phoneName: String, identity: LinkIdentity.Stored, pairings: [PhonePairing]) {
        self.phoneName = phoneName
        self.identity = identity
        self.pairings = pairings
    }
}
