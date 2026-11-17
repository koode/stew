import Foundation
import Security

/// Where the Mac keeps its account session token. Main queue only.
public protocol AccountTokenStore: AnyObject {
    func read() -> String?
    func save(_ token: String) throws
    func delete()
}

/// Keeps the token in memory only, for tests and `stew snapshot`.
public final class MemoryAccountTokenStore: AccountTokenStore {
    private var token: String?

    public init(token: String? = nil) {
        self.token = token
    }

    public func read() -> String? { token }
    public func save(_ token: String) throws { self.token = token }
    public func delete() { token = nil }
}

/// A 0600 file, for the headless test daemon, which must never touch the keychain.
public final class FileAccountTokenStore: AccountTokenStore {
    private let path: String

    public init(path: String) {
        self.path = path
    }

    public func read() -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    public func save(_ token: String) throws {
        guard FileManager.default.createFile(atPath: path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    public func delete() {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// The login keychain, where the real daemon keeps the token: a file another process
/// could read would hand over the account.
public final class KeychainAccountTokenStore: AccountTokenStore {
    public static let service = "nl.koode.stew.account"
    static let accountName = "session"

    public init() {}

    private var match: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.accountName,
        ]
    }

    public func read() -> String? {
        var query = match
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        let token = String(decoding: data, as: UTF8.self)
        return token.isEmpty ? nil : token
    }

    public func save(_ token: String) throws {
        let data = Data(token.utf8)
        let status = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = match
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "stew account"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public func delete() {
        SecItemDelete(match as CFDictionary)
    }

    /// Deletes every keychain item stew made for the account. True when one was deleted.
    @discardableResult
    public static func removeAll() -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    public struct KeychainError: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String { (SecCopyErrorMessageString(status, nil) as String?) ?? "keychain error \(status)" }
    }
}
