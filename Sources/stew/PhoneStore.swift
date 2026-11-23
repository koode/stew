import Foundation
import Security
import StewLink

/// A phone as the Mac stores it. A pairing starts as `waiting` while the QR code is on
/// screen, becomes `confirming` when a phone has registered, and `paired` once the user
/// confirms the matching digits.
struct MacPairing: Codable, Equatable, Identifiable {
    enum State: String, Codable {
        case waiting, confirming, paired
    }

    var id: String { pairingId }
    var pairingId: String
    var relay: String
    var macName: String
    var secret: Data
    var state: State
    var phoneName: String?
    var phoneKeys: LinkPublicKeys?
    var createdAt: Date
    var pairedAt: Date?
    /// The device is another Mac, from its hello. Nil or false: an iPhone.
    var isMac: Bool?
    /// The pairing this Mac made for its own requests after it joined a paired Mac's
    /// pairing: only a device with these keys (that Mac's) may take it, and it counts as
    /// paired at once, as the user confirmed that Mac when it joined.
    var expectedPeer: LinkPublicKeys?
    /// For a pairing with another Mac: the id of the pairing this Mac joined on that Mac,
    /// so ending one ends both.
    var linkedJoin: String?

    func pairingCode(macKeys: LinkPublicKeys) -> PairingCode {
        PairingCode(relay: relay, pairingId: pairingId, macName: macName, macKeys: macKeys, secret: secret)
    }

    func channel(identity: LinkIdentity) throws -> LinkChannel? {
        guard let phoneKeys else { return nil }
        return try LinkChannel(pairingId: pairingId, side: .mac, identity: identity, peer: phoneKeys, pairingSecret: secret)
    }
}

/// A pairing of another Mac that this Mac joined with its code, in the phone's part: the
/// other Mac's requests show on this Mac's panel, and answers go back through the relay.
struct JoinedPairing: Codable, Equatable, Identifiable {
    var id: String { pairingId }
    var pairingId: String { code.pairingId }
    var code: PairingCode
    /// The user let the other Mac answer this Mac's requests, on this Mac's panel. Only
    /// then does this Mac make the pairing for its own requests and hand it over.
    var approved: Bool
    /// Joined with a code the other Mac handed over through a pairing the user already
    /// confirmed, so it needed no step of its own.
    var handedOver: Bool
    /// This Mac's own pairing that the other Mac joined, once there is one.
    var linkedPairing: String?
    var joinedAt: Date

    var macName: String { code.macName }

    func channel(identity: LinkIdentity) throws -> LinkChannel {
        try LinkChannel(pairingId: code.pairingId, side: .phone, identity: identity, peer: code.macKeys, pairingSecret: code.secret)
    }
}

/// The Mac's keys and its pairings. Both are secrets (the pairing secret salts every
/// key, and a phone key in this list may approve requests), so they live in the login
/// keychain, not in a file another process could edit. The headless test daemon keeps
/// them in a 0600 file next to its socket instead, so tests never touch the keychain.
final class PhoneStore {
    struct Contents: Codable, Equatable {
        var identity: LinkIdentity.Stored
        var pairings: [MacPairing]
        /// Pairings of other Macs that this Mac joined in the phone's part. Nil in stores
        /// from before pairing Macs.
        var joined: [JoinedPairing]?
    }

    static let keychainService = "nl.koode.stew.link"
    private static let keychainAccount = "pairings"

    private(set) var identity: LinkIdentity
    private(set) var pairings: [MacPairing]
    private(set) var joined: [JoinedPairing] = []
    private let filePath: String?
    private let persists: Bool

    /// Keeps everything in memory, for `stew snapshot`.
    init(sampleIdentity: LinkIdentity) {
        filePath = nil
        persists = false
        identity = sampleIdentity
        pairings = []
    }

    init(headless: Bool = Paths.headless) {
        persists = true
        filePath = headless ? (Paths.socket as NSString).deletingLastPathComponent + "/phone-link.json" : nil
        let stored = Self.read(filePath: filePath).flatMap { try? JSONDecoder().decode(Contents.self, from: $0) }
        if let stored, let identity = try? LinkIdentity(stored: stored.identity) {
            self.identity = identity
            pairings = stored.pairings
            joined = stored.joined ?? []
        } else {
            identity = LinkIdentity()
            pairings = []
        }
    }

    func upsert(_ pairing: MacPairing) {
        if let index = pairings.firstIndex(where: { $0.pairingId == pairing.pairingId }) {
            pairings[index] = pairing
        } else {
            pairings.append(pairing)
        }
        save()
    }

    func remove(_ pairingId: String) {
        pairings.removeAll { $0.pairingId == pairingId }
        save()
    }

    func upsertJoined(_ pairing: JoinedPairing) {
        if let index = joined.firstIndex(where: { $0.pairingId == pairing.pairingId }) {
            joined[index] = pairing
        } else {
            joined.append(pairing)
        }
        save()
    }

    func removeJoined(_ pairingId: String) {
        joined.removeAll { $0.pairingId == pairingId }
        save()
    }

    private func save() {
        guard persists, let data = try? JSONEncoder().encode(Contents(identity: identity.stored, pairings: pairings, joined: joined)) else { return }
        do {
            try Self.write(data, filePath: filePath)
        } catch {
            Log.write("phone: cannot save pairings: \(error)")
        }
    }

    /// Deletes every keychain item stew made for iPhone pairings. True when one was deleted.
    @discardableResult
    static func removeKeychainItems() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    private static func read(filePath: String?) -> Data? {
        if let filePath { return FileManager.default.contents(atPath: filePath) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func write(_ data: Data, filePath: String?) throws {
        if let filePath {
            FileManager.default.createFile(atPath: filePath, contents: data, attributes: [.posixPermissions: 0o600])
            return
        }
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        let status = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = match
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "stew iPhone pairings"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    struct KeychainError: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String { (SecCopyErrorMessageString(status, nil) as String?) ?? "keychain error \(status)" }
    }
}
