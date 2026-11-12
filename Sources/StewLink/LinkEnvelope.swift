import Foundation

/// What a message is for. The relay reads this to pick the push type, so it is outside the
/// ciphertext; everything about the request itself is inside.
public enum LinkKind: String, Codable, Sendable, CaseIterable {
    /// Phone to Mac, once, while pairing: the phone's name and keys.
    case hello
    /// Mac to phone: a request to answer, or a notification. Sent as an alert push.
    case request
    /// Mac to phone: the same request with a new deadline. Sent as a background push.
    case update
    /// Mac to phone: the request is closed, with its outcome. Sent as a background push.
    case resolved
    /// Phone to Mac: an answer to a request.
    case answer
    /// Mac to phone: whether an answer was taken, as the reply to that answer.
    case result
    /// Either side: this pairing is over.
    case unpair
}

public enum LinkSide: String, Codable, Sendable {
    case mac, phone

    public var peer: LinkSide { self == .mac ? .phone : .mac }
}

/// One message between a Mac and a phone. The relay sees every field except the plaintext
/// inside `ciphertext`, and can verify `signature` against the key it stored for the sender.
public struct LinkEnvelope: Codable, Equatable, Sendable {
    public static let version = 1
    /// Messages may not claim to stay valid longer than this, which bounds the replay store.
    public static let longestLife: TimeInterval = 7 * 24 * 3600

    public var v: Int
    public var pairingId: String
    public var kind: LinkKind
    public var sender: LinkSide
    /// The request this message is about. "pairing" for hello and unpair.
    public var requestId: String
    /// Unique per message. Receivers refuse a message id they have already seen.
    public var messageId: String
    /// For a result: the message id of the answer it replies to. Empty otherwise.
    public var replyTo: String
    /// Unix seconds. Receivers refuse the message after this.
    public var expiresAt: Int
    /// ChaCha20-Poly1305 combined box: 12 byte nonce, ciphertext, 16 byte tag.
    public var ciphertext: Data
    /// Ed25519 over `signedBytes`.
    public var signature: Data

    public init(
        pairingId: String,
        kind: LinkKind,
        sender: LinkSide,
        requestId: String,
        messageId: String,
        replyTo: String = "",
        expiresAt: Int,
        ciphertext: Data = Data(),
        signature: Data = Data()
    ) {
        v = Self.version
        self.pairingId = pairingId
        self.kind = kind
        self.sender = sender
        self.requestId = requestId
        self.messageId = messageId
        self.replyTo = replyTo
        self.expiresAt = expiresAt
        self.ciphertext = ciphertext
        self.signature = signature
    }

    /// The fields in a fixed order, one per line. It is the associated data of the
    /// encryption, so a relay cannot move a ciphertext to another request or kind.
    public var header: Data {
        let lines = ["stew-link/\(v)", pairingId, kind.rawValue, sender.rawValue, requestId, messageId, replyTo, String(expiresAt)]
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// What the sender signs: the header, a newline, and the ciphertext as standard base64
    /// (the same text JSON carries, so the relay can check it without re-encoding).
    public var signedBytes: Data {
        header + Data(("\n" + ciphertext.base64EncodedString()).utf8)
    }

    /// Ids are 1 to 64 characters of A-Z, a-z, 0-9, - and _, so no field can hold the
    /// newline that separates header lines.
    public static func isValidIdentifier(_ text: String, allowEmpty: Bool = false) -> Bool {
        if text.isEmpty { return allowEmpty }
        guard text.utf8.count <= 64 else { return false }
        return text.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D || byte == 0x5F
        }
    }

    public var hasValidFields: Bool {
        v == Self.version
            && Self.isValidIdentifier(pairingId)
            && Self.isValidIdentifier(requestId)
            && Self.isValidIdentifier(messageId)
            && Self.isValidIdentifier(replyTo, allowEmpty: true)
    }
}

public enum LinkJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        try encoder().encode(value)
    }

    public static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try JSONDecoder().decode(type, from: data)
    }
}
