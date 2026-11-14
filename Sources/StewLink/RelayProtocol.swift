import CryptoKit
import Foundation

/// Relay protocol versions. The envelope's own `v` versions the end-to-end format and does
/// not change with these. v2 is current; v1 is what relays and builds from before v2 speak.
public enum RelayVersion: Int, Codable, Sendable, Comparable {
    case v1 = 1, v2 = 2

    public static func < (lhs: RelayVersion, rhs: RelayVersion) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The path of a pairing call, such as /v2/pairings/{id}/socket.
    public func pairingPath(_ pairingId: String, _ action: String) -> String {
        "/v\(rawValue)/pairings/\(pairingId)/\(action)"
    }
}

public enum RelayProtocol {
    /// Every v2 response carries this header with the version.
    public static let versionHeader = "stew-protocol"
    /// A repeated envelope's response carries this header with the value "1".
    public static let duplicateHeader = "stew-duplicate"
    /// The WebSocket subprotocol a v2 socket offers.
    public static let subprotocol = "stew.relay.2"
    public static let infoPath = "/v2/info"
}

/// What GET /v2/info returns: the versions a relay serves, and its limits and timers.
public struct RelayInfo: Codable, Equatable, Sendable {
    public var protocols: [Int]
    public var maxBodyBytes: Int?
    public var maxClientFrameBytes: Int?
    public var heartbeatSeconds: Double?
    public var pongTimeoutSeconds: Double?
    public var idleCloseSeconds: Double?
    public var answerTimeoutSeconds: Double?

    public init(protocols: [Int], heartbeatSeconds: Double? = nil, pongTimeoutSeconds: Double? = nil) {
        self.protocols = protocols
        self.heartbeatSeconds = heartbeatSeconds
        self.pongTimeoutSeconds = pongTimeoutSeconds
    }
}

/// What a client learns from asking a relay for GET /v2/info.
public enum RelayProbe: Equatable, Sendable {
    /// The relay speaks v2.
    case v2(RelayInfo)
    /// No /v2/info: the relay predates v2, so the client speaks v1 with it.
    case v1
    /// The relay answers, but serves no version this client speaks: stew needs an update.
    case unsupported
    /// Unreachable, or an error that says nothing about the version: ask again later.
    case unknown

    /// Decides from the response to GET /v2/info. Status 0 means no response.
    public static func decide(status: Int, body: Data) -> RelayProbe {
        switch status {
        case 200:
            guard let info = try? JSONDecoder().decode(RelayInfo.self, from: body) else { return .unknown }
            return info.protocols.contains(RelayVersion.v2.rawValue) ? .v2(info) : .unsupported
        case 404: return .v1
        case 426: return .unsupported
        default: return .unknown
        }
    }

    public var version: RelayVersion? {
        switch self {
        case .v2: .v2
        case .v1: .v1
        case .unsupported, .unknown: nil
        }
    }
}

extension RelayAuth {
    /// The scheme of the v2 `authorization` header.
    public static let scheme = "Stew-Ed25519"

    /// What a v2 auth header signs: the lines below joined with "\n", no newline at the end.
    public static func headerMessage(method: String, path: String, side: LinkSide, timestamp: Int, nonce: String, bodyHash: String) -> Data {
        Data(["stew-relay/2", method.uppercased(), path, side.rawValue, String(timestamp), nonce, bodyHash].joined(separator: "\n").utf8)
    }

    /// Lowercase hex SHA-256 of the exact body bytes; of no bytes for a GET.
    public static func bodyHash(_ body: Data?) -> String {
        Data(SHA256.hash(data: body ?? Data())).hexEncoded
    }

    /// `Stew-Ed25519 side=…, ts=…, nonce=…, sig=…` for one v2 call. Make a new one for every
    /// call, retries included: the relay accepts each nonce once.
    public static func header(
        method: String,
        path: String,
        side: LinkSide,
        body: Data?,
        identity: LinkIdentity,
        now: Date = Date(),
        nonce: Data = LinkRandom.bytes(16)
    ) throws -> String {
        let timestamp = Int(now.timeIntervalSince1970)
        let nonceText = nonce.base64URLEncoded
        let message = headerMessage(method: method, path: path, side: side, timestamp: timestamp, nonce: nonceText, bodyHash: bodyHash(body))
        let signature = try identity.sign(message)
        return "\(scheme) side=\(side.rawValue), ts=\(timestamp), nonce=\(nonceText), sig=\(signature.base64URLEncoded)"
    }
}

/// Body of the Mac's v2 claim. The auth header, signed by `macSigningKey`, proves the Mac
/// holds the key.
public struct RelayClaimV2: Codable, Equatable, Sendable {
    public var macSigningKey: Data
    public var registrationTokenHash: String

    public init(code: PairingCode, identity: LinkIdentity) {
        macSigningKey = identity.publicKeys.signing
        registrationTokenHash = code.registrationTokenHash
    }
}

/// Body of a v2 push token change; the auth header carries the phone's signature.
public struct RelayDeviceChange: Codable, Equatable, Sendable {
    public var deviceToken: String
    public var environment: String

    public init(deviceToken: String, environment: String) {
        self.deviceToken = deviceToken
        self.environment = environment
    }
}

/// The relay's first frame on a v2 socket.
public struct RelayReady: Codable, Equatable, Sendable {
    public var pairingId: String
    public var `protocol`: Int
    public var ackedSeq: Int
    public var heartbeatSeconds: Double?
}

/// A text frame from the relay on the Mac's socket.
public enum RelayIncoming: Equatable, Sendable {
    case pong
    case ready(RelayReady)
    case frame(RelayFrame)

    private struct Kind: Decodable {
        var t: String?
    }

    public static func decode(_ data: Data) throws -> RelayIncoming {
        if data == Data("pong".utf8) { return .pong }
        if try LinkJSON.decode(Kind.self, from: data).t == "ready" {
            return .ready(try LinkJSON.decode(RelayReady.self, from: data))
        }
        return .frame(try LinkJSON.decode(RelayFrame.self, from: data))
    }
}

/// What the Mac sends on its socket to say frames were handled.
public enum RelayAck {
    /// v2: everything up to `seq` is handled.
    public static func cumulative(pairingId: String, seq: Int) -> String {
        "{\"t\":\"ack\",\"pairingId\":\(jsonString(pairingId)),\"seq\":\(seq)}"
    }

    /// v1: one queued frame, by its envelope's message id.
    public static func message(_ messageId: String) -> String {
        "{\"messageId\":\(jsonString(messageId)),\"type\":\"ack\"}"
    }

    private static func jsonString(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}

/// Frames to handle once per run: the relay resends what was not acked when the socket
/// reconnects, and the Mac acks those again without handling them twice.
public struct RelaySequence: Equatable, Sendable {
    public private(set) var handled = 0

    public init() {}

    /// Whether a frame is new. Frames without a seq (v1) are always new.
    public mutating func isNew(_ seq: Int?) -> Bool {
        guard let seq else { return true }
        guard seq > handled else { return false }
        handled = seq
        return true
    }
}

/// The client half of the heartbeat: a `ping` every `interval`, and a socket that has not
/// answered one within `pongTimeout` counts as dead.
public struct RelayHeartbeat: Equatable, Sendable {
    public static let interval: TimeInterval = 25
    public static let pongTimeout: TimeInterval = 10

    public private(set) var awaitingPongSince: Date?

    public init() {}

    public mutating func pingSent(at date: Date) {
        if awaitingPongSince == nil { awaitingPongSince = date }
    }

    public mutating func pongReceived() {
        awaitingPongSince = nil
    }

    public func isOverdue(now: Date, pongTimeout: TimeInterval = RelayHeartbeat.pongTimeout) -> Bool {
        guard let awaitingPongSince else { return false }
        return now.timeIntervalSince(awaitingPongSince) >= pongTimeout
    }
}

/// Why a client stops reconnecting for good.
public enum RelayStop: Equatable, Sendable {
    /// 4010: the pairing ended; forget it.
    case unpaired
    /// 4011: nobody used the code before the relay dropped the claim.
    case claimExpired
    /// 4004 or HTTP 404: the relay does not know this pairing.
    case unknownPairing
    /// 4026 or HTTP 426: the relay needs a newer stew.
    case unsupportedProtocol
}

/// What a client does after its socket closed or the upgrade was refused, per the close
/// code table in the relay's wire protocol.
public enum RelayReconnect: Equatable, Sendable {
    /// Wait the current backoff, then double it.
    case backoff
    /// 1001: the relay restarts; come back in 0.5 to 3 seconds without growing the backoff.
    case soon
    /// 4008: the relay closed an idle socket; reconnect at once.
    case now
    /// Wait exactly this long: 60 s after 4000, the relay's seconds after 4029 or 429.
    case after(TimeInterval)
    /// 4001 or HTTP 401: back off, and after three in a row say the relay refused this Mac.
    case authFailed
    case stop(RelayStop)

    public static let replacedWait: TimeInterval = 60
    /// Used for a 429 or 4029 that names no wait: the relay's address limit window.
    public static let defaultRateLimitWait: TimeInterval = 10

    public static func afterClose(code: Int, reason: String?) -> RelayReconnect {
        switch code {
        case 1001: .soon
        case 4000: .after(replacedWait)
        case 4001: .authFailed
        case 4004: .stop(.unknownPairing)
        case 4008: .now
        case 4010: .stop(.unpaired)
        case 4011: .stop(.claimExpired)
        case 4026: .stop(.unsupportedProtocol)
        case 4029: .after(reason.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) } ?? defaultRateLimitWait)
        default: .backoff
        }
    }

    /// A refusal before the upgrade, by HTTP status.
    public static func afterRefusal(status: Int, retryAfter: String?) -> RelayReconnect {
        switch status {
        case 401: .authFailed
        case 404: .stop(.unknownPairing)
        case 426: .stop(.unsupportedProtocol)
        case 429: .after(retryAfter.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) } ?? defaultRateLimitWait)
        default: .backoff
        }
    }
}
