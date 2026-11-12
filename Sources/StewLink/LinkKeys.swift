import CryptoKit
import Foundation

/// The public half of a device's keys: X25519 for key agreement, Ed25519 for signatures.
/// Both are 32 raw bytes and travel as base64 in JSON.
public struct LinkPublicKeys: Codable, Equatable, Hashable, Sendable {
    public var agreement: Data
    public var signing: Data

    public init(agreement: Data, signing: Data) {
        self.agreement = agreement
        self.signing = signing
    }

    /// Refuses keys that are not 32 bytes, so a malformed peer fails at pairing, not later.
    public func validated() throws -> LinkPublicKeys {
        _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: agreement)
        _ = try Curve25519.Signing.PublicKey(rawRepresentation: signing)
        return self
    }
}

/// A device's private keys. The Mac has one identity for all its phones; a phone has one
/// for all its Macs. Each pairing still gets its own symmetric key, because the pairing
/// secret goes into the key derivation.
public struct LinkIdentity: Sendable {
    public let agreementKey: Curve25519.KeyAgreement.PrivateKey
    public let signingKey: Curve25519.Signing.PrivateKey

    public init() {
        agreementKey = Curve25519.KeyAgreement.PrivateKey()
        signingKey = Curve25519.Signing.PrivateKey()
    }

    public init(stored: Stored) throws {
        agreementKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: stored.agreement)
        signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: stored.signing)
    }

    public var publicKeys: LinkPublicKeys {
        LinkPublicKeys(agreement: agreementKey.publicKey.rawRepresentation, signing: signingKey.publicKey.rawRepresentation)
    }

    /// The raw private keys, for the Keychain and nowhere else.
    public var stored: Stored {
        Stored(agreement: agreementKey.rawRepresentation, signing: signingKey.rawRepresentation)
    }

    public struct Stored: Codable, Equatable, Sendable {
        public var agreement: Data
        public var signing: Data

        public init(agreement: Data, signing: Data) {
            self.agreement = agreement
            self.signing = signing
        }
    }

    public func sign(_ data: Data) throws -> Data {
        try signingKey.signature(for: data)
    }
}

public enum LinkRandom {
    /// URL-safe random id: 16 bytes, 22 characters.
    public static func identifier() -> String {
        bytes(16).base64URLEncoded
    }

    public static func bytes(_ count: Int) -> Data {
        guard count > 0 else { return Data() }
        return SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }
}

extension Data {
    /// Base64 without padding, with - and _ instead of + and /. Used for ids, the pairing
    /// code and query strings, where + and / would need escaping.
    public var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public init?(base64URLEncoded text: String) {
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while standard.count % 4 != 0 { standard += "=" }
        self.init(base64Encoded: standard)
    }

    var hexEncoded: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
