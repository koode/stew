import CryptoKit
import Foundation

public enum LinkError: Error, Equatable, CustomStringConvertible, Sendable {
    case malformed
    case wrongPairing
    case wrongSender
    case badSignature
    case cannotDecrypt
    case expired
    case expiresTooLate
    case replayed
    case badKey

    public var description: String {
        switch self {
        case .malformed: "the message is malformed"
        case .wrongPairing: "the message is for another pairing"
        case .wrongSender: "the message does not come from the paired device"
        case .badSignature: "the signature does not match the paired device"
        case .cannotDecrypt: "the message cannot be decrypted with this pairing's key"
        case .expired: "the message has expired"
        case .expiresTooLate: "the message claims to stay valid too long"
        case .replayed: "the message was already received"
        case .badKey: "a key has the wrong size"
        }
    }
}

/// Message ids already accepted, kept until they expire. A message whose id is here is a
/// replay. Persist it between launches, or a replay is accepted after a restart.
public struct ReplayGuard: Codable, Equatable, Sendable {
    /// Clocks on two devices disagree a little, so expiry gets this much slack.
    public static let clockSkew: TimeInterval = 60

    public private(set) var seen: [String: Int] = [:]

    public init() {}

    public func contains(_ messageId: String) -> Bool { seen[messageId] != nil }

    public mutating func record(_ messageId: String, expiresAt: Int, now: Date) {
        prune(now: now)
        seen[messageId] = expiresAt
    }

    public mutating func prune(now: Date) {
        let cutoff = Int(now.timeIntervalSince1970 - Self.clockSkew)
        seen = seen.filter { $0.value >= cutoff }
    }
}

/// One pairing seen from one side: seals messages to the peer and opens the peer's.
///
/// The key is HKDF-SHA256 over the X25519 shared secret, salted with the pairing secret
/// from the QR code. The pairing secret never reaches the relay, so a relay that swapped
/// in its own public keys during pairing still could not derive the key.
public struct LinkChannel: Sendable {
    public let pairingId: String
    public let side: LinkSide
    public let identity: LinkIdentity
    public let peer: LinkPublicKeys
    private let key: SymmetricKey
    private let peerSigning: Curve25519.Signing.PublicKey

    public init(pairingId: String, side: LinkSide, identity: LinkIdentity, peer: LinkPublicKeys, pairingSecret: Data) throws {
        guard LinkEnvelope.isValidIdentifier(pairingId) else { throw LinkError.malformed }
        let peerAgreement: Curve25519.KeyAgreement.PublicKey
        do {
            peerAgreement = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer.agreement)
            peerSigning = try Curve25519.Signing.PublicKey(rawRepresentation: peer.signing)
        } catch {
            throw LinkError.badKey
        }
        let shared = try identity.agreementKey.sharedSecretFromKeyAgreement(with: peerAgreement)
        key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: pairingSecret,
            sharedInfo: Data("stew-link/1 \(pairingId)".utf8),
            outputByteCount: 32
        )
        self.pairingId = pairingId
        self.side = side
        self.identity = identity
        self.peer = peer
    }

    public func seal<Payload: Encodable>(
        _ payload: Payload,
        kind: LinkKind,
        requestId: String,
        expiresAt: Date,
        replyTo: String = "",
        messageId: String = LinkRandom.identifier()
    ) throws -> LinkEnvelope {
        var envelope = LinkEnvelope(
            pairingId: pairingId,
            kind: kind,
            sender: side,
            requestId: requestId,
            messageId: messageId,
            replyTo: replyTo,
            expiresAt: Int(expiresAt.timeIntervalSince1970.rounded(.up))
        )
        guard envelope.hasValidFields else { throw LinkError.malformed }
        let plaintext = Self.padded(try LinkJSON.encode(payload))
        let box = try ChaChaPoly.seal(plaintext, using: key, authenticating: envelope.header)
        envelope.ciphertext = box.combined
        envelope.signature = try identity.sign(envelope.signedBytes)
        return envelope
    }

    /// Ciphertext length would otherwise tell the relay which answer was given
    /// ("approve" and "deny" differ in length) and roughly how long a command is. The
    /// plaintext is a 4 byte big-endian length, the JSON, and zeros up to a multiple of
    /// this size.
    public static let paddingBlock = 256

    static func padded(_ json: Data) -> Data {
        var length = UInt32(json.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data += json
        let total = (data.count + paddingBlock - 1) / paddingBlock * paddingBlock
        data += Data(count: total - data.count)
        return data
    }

    static func unpadded(_ data: Data) throws -> Data {
        guard data.count >= 4 else { throw LinkError.malformed }
        let length = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length <= data.count - 4 else { throw LinkError.malformed }
        return Data(data.dropFirst(4).prefix(length))
    }

    /// Checks, in order: fields, pairing, sender, signature, expiry, replay, then decrypts.
    /// The message id is recorded only once all of that passed, so a forged message
    /// cannot block a real one by taking its id.
    public func open<Payload: Decodable>(
        _ envelope: LinkEnvelope,
        as type: Payload.Type,
        now: Date = Date(),
        replay: inout ReplayGuard
    ) throws -> Payload {
        guard envelope.hasValidFields else { throw LinkError.malformed }
        guard envelope.pairingId == pairingId else { throw LinkError.wrongPairing }
        guard envelope.sender == side.peer else { throw LinkError.wrongSender }
        guard peerSigning.isValidSignature(envelope.signature, for: envelope.signedBytes) else { throw LinkError.badSignature }
        let nowSeconds = now.timeIntervalSince1970
        guard Double(envelope.expiresAt) + ReplayGuard.clockSkew >= nowSeconds else { throw LinkError.expired }
        guard Double(envelope.expiresAt) <= nowSeconds + LinkEnvelope.longestLife + ReplayGuard.clockSkew else { throw LinkError.expiresTooLate }
        guard !replay.contains(envelope.messageId) else { throw LinkError.replayed }
        let plaintext: Data
        do {
            let box = try ChaChaPoly.SealedBox(combined: envelope.ciphertext)
            plaintext = try ChaChaPoly.open(box, using: key, authenticating: envelope.header)
        } catch {
            throw LinkError.cannotDecrypt
        }
        let payload: Payload
        do {
            payload = try LinkJSON.decode(type, from: try Self.unpadded(plaintext))
        } catch {
            throw LinkError.malformed
        }
        replay.record(envelope.messageId, expiresAt: envelope.expiresAt, now: now)
        return payload
    }
}
