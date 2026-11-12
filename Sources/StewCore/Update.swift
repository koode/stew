import CryptoKit
import Foundation

/// A version such as "0.2.0" or "1.0.0-beta.2". Pre-releases sort before the release.
public struct SemanticVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public var numbers: [Int]
    public var preRelease: [String]

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let core = parts.first, !core.isEmpty else { return nil }
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(numbers.count), numbers.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        self.numbers = numbers.compactMap { $0 }
        if parts.count == 2 {
            let identifiers = parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !identifiers.isEmpty, identifiers.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber } }) else { return nil }
            preRelease = identifiers
        } else {
            preRelease = []
        }
    }

    public var description: String {
        numbers.map(String.init).joined(separator: ".") + (preRelease.isEmpty ? "" : "-" + preRelease.joined(separator: "."))
    }

    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        // Missing parts count as 0, so "1.2" equals "1.2.0".
        for index in 0..<max(lhs.numbers.count, rhs.numbers.count, 3) {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right { return left < right }
        }
        switch (lhs.preRelease.isEmpty, rhs.preRelease.isEmpty) {
        case (true, _): return false
        case (false, true): return true
        case (false, false): break
        }
        for (left, right) in zip(lhs.preRelease, rhs.preRelease) where left != right {
            switch (Int(left), Int(right)) {
            case let (leftNumber?, rightNumber?): return leftNumber < rightNumber
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return left < right
            }
        }
        return lhs.preRelease.count < rhs.preRelease.count
    }
}

/// latest.json on the release server: the newest version and where its zip is.
public struct UpdateManifest: Codable, Equatable, Sendable {
    public struct Archive: Codable, Equatable, Sendable {
        public var url: String
        /// Lowercase hex SHA-256 of the zip.
        public var sha256: String
        /// Size of the zip in bytes.
        public var size: Int
        /// Base64 Ed25519 signature over the zip bytes.
        public var ed25519: String

        public init(url: String, sha256: String, size: Int, ed25519: String) {
            self.url = url
            self.sha256 = sha256
            self.size = size
            self.ed25519 = ed25519
        }
    }

    public var version: String
    public var build: Int
    public var published: String
    public var minimumMacOS: String
    public var notes: String?
    public var archive: Archive

    public init(version: String, build: Int, published: String, minimumMacOS: String, notes: String? = nil, archive: Archive) {
        self.version = version
        self.build = build
        self.published = published
        self.minimumMacOS = minimumMacOS
        self.notes = notes
        self.archive = archive
    }

    /// Largest zip the updater accepts. A release is a few megabytes.
    public static let maximumArchiveSize = 200 * 1024 * 1024

    /// Decodes and checks a manifest. Throws `UpdateError.invalidManifest` with the reason.
    public static func decode(_ data: Data) throws -> UpdateManifest {
        let manifest: UpdateManifest
        do {
            manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
        } catch {
            throw UpdateError.invalidManifest("not a valid latest.json: \(error)")
        }
        try manifest.validate()
        return manifest
    }

    public func validate() throws {
        guard SemanticVersion(version) != nil else { throw UpdateError.invalidManifest("version \"\(version)\" is not X.Y.Z") }
        guard build > 0 else { throw UpdateError.invalidManifest("build must be a positive number") }
        guard SemanticVersion(minimumMacOS) != nil, SemanticVersion(minimumMacOS)?.preRelease.isEmpty == true else {
            throw UpdateError.invalidManifest("minimumMacOS \"\(minimumMacOS)\" is not a macOS version")
        }
        guard ISO8601DateFormatter().date(from: published) != nil else {
            throw UpdateError.invalidManifest("published \"\(published)\" is not an ISO 8601 date")
        }
        guard let url = URL(string: archive.url), Self.isAllowedDownload(url) else {
            throw UpdateError.invalidManifest("archive url \"\(archive.url)\" must be https")
        }
        guard archive.sha256.count == 64, archive.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw UpdateError.invalidManifest("archive sha256 must be 64 lowercase hex characters")
        }
        guard archive.size > 0, archive.size <= Self.maximumArchiveSize else {
            throw UpdateError.invalidManifest("archive size \(archive.size) is out of range")
        }
        guard let signature = Data(base64Encoded: archive.ed25519), signature.count == 64 else {
            throw UpdateError.invalidManifest("archive ed25519 must be a base64 64-byte signature")
        }
    }

    /// HTTPS only. Plain HTTP is allowed for this machine alone, so tests can serve
    /// releases locally; the signature check still applies.
    public static func isAllowedDownload(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return url.host?.isEmpty == false
        case "http": return ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased() ?? "")
        default: return false
        }
    }
}

public enum UpdateError: Error, Equatable, CustomStringConvertible {
    case invalidManifest(String)
    case download(String)
    case sizeMismatch(expected: Int, actual: Int)
    case checksumMismatch(expected: String, actual: String)
    case badSignature
    case invalidPublicKey
    case invalidPrivateKey
    case noPublicKey
    case codeSignature(String)
    case wrongBundle(String)
    case install(String)

    public var description: String {
        switch self {
        case .invalidManifest(let reason): "invalid update manifest: \(reason)"
        case .download(let reason): "download failed: \(reason)"
        case .sizeMismatch(let expected, let actual): "update rejected: the zip is \(actual) bytes, the manifest says \(expected)"
        case .checksumMismatch(let expected, let actual): "update rejected: sha256 is \(actual), the manifest says \(expected)"
        case .badSignature: "update rejected: the Ed25519 signature does not match the zip"
        case .invalidPublicKey: "the update signing key in this build is not a valid Ed25519 public key"
        case .invalidPrivateKey: "the signing key is not a base64 Ed25519 private key"
        case .noPublicKey: "this build has no update signing key, so it cannot install updates"
        case .codeSignature(let reason): "update rejected: \(reason)"
        case .wrongBundle(let reason): "update rejected: \(reason)"
        case .install(let reason): "install failed: \(reason)"
        }
    }
}

/// What a check found, compared with the installed version.
public enum UpdateDecision: Equatable, Sendable {
    case upToDate
    case available
    /// Newer, but it needs a newer macOS than this Mac runs.
    case needsNewerMacOS(String)

    /// Newer version wins; for the same version the higher build wins. A development
    /// build (no build number) counts as build 0.
    public static func evaluate(_ manifest: UpdateManifest, installed: AppVersion, macOS: OperatingSystemVersion) -> UpdateDecision {
        guard let offered = SemanticVersion(manifest.version) else { return .upToDate }
        let current = SemanticVersion(installed.version) ?? SemanticVersion("0.0.0")!
        let isNewer = offered > current || (offered == current && manifest.build > (installed.build ?? 0))
        guard isNewer else { return .upToDate }
        guard supports(minimumMacOS: manifest.minimumMacOS, on: macOS) else { return .needsNewerMacOS(manifest.minimumMacOS) }
        return .available
    }

    public static func supports(minimumMacOS: String, on macOS: OperatingSystemVersion) -> Bool {
        guard let minimum = SemanticVersion(minimumMacOS) else { return false }
        let running = SemanticVersion("\(macOS.majorVersion).\(macOS.minorVersion).\(macOS.patchVersion)")!
        return running >= minimum
    }
}

/// Checks a downloaded zip against the manifest: size, SHA-256, then the Ed25519
/// signature made with the release key.
public enum UpdateVerifier {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(_ zip: Data, against archive: UpdateManifest.Archive, publicKey: String) throws {
        guard zip.count == archive.size else { throw UpdateError.sizeMismatch(expected: archive.size, actual: zip.count) }
        let digest = sha256Hex(zip)
        guard digest == archive.sha256 else { throw UpdateError.checksumMismatch(expected: archive.sha256, actual: digest) }
        guard !publicKey.isEmpty else { throw UpdateError.noPublicKey }
        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { throw UpdateError.invalidPublicKey }
        guard let signature = Data(base64Encoded: archive.ed25519), key.isValidSignature(signature, for: zip) else {
            throw UpdateError.badSignature
        }
    }

    /// The Info.plist of the unzipped app must name stew and the version the manifest promised.
    public static func checkBundle(infoPlist: Data, matches manifest: UpdateManifest) throws {
        guard let plist = try? PropertyListSerialization.propertyList(from: infoPlist, format: nil) as? [String: Any] else {
            throw UpdateError.wrongBundle("the app has no readable Info.plist")
        }
        let identifier = plist["CFBundleIdentifier"] as? String
        guard identifier == "nl.koode.stew" else {
            throw UpdateError.wrongBundle("bundle identifier is \(identifier ?? "missing"), expected nl.koode.stew")
        }
        guard let version = AppVersion(infoPlist: infoPlist), version.version == manifest.version, version.build == manifest.build else {
            throw UpdateError.wrongBundle("the app is not version \(manifest.version) (build \(manifest.build))")
        }
    }

    /// The TeamIdentifier line of `codesign -dv` output, or nil for ad hoc and unsigned code.
    public static func teamIdentifier(fromCodesignOutput output: String) -> String? {
        for line in output.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            let value = String(line.dropFirst("TeamIdentifier=".count)).trimmingCharacters(in: .whitespaces)
            return value == "not set" || value.isEmpty ? nil : value
        }
        return nil
    }
}

/// Release signing, for the maintainer's release script.
public enum UpdateSigner {
    /// A new key pair as base64 raw representations.
    public static func generateKeyPair() -> (privateKey: String, publicKey: String) {
        let key = Curve25519.Signing.PrivateKey()
        return (key.rawRepresentation.base64EncodedString(), key.publicKey.rawRepresentation.base64EncodedString())
    }

    public static func publicKey(forPrivateKey privateKey: String) throws -> String {
        try privateKeyValue(privateKey).publicKey.rawRepresentation.base64EncodedString()
    }

    public static func sign(_ data: Data, privateKey: String) throws -> String {
        try privateKeyValue(privateKey).signature(for: data).base64EncodedString()
    }

    private static func privateKeyValue(_ text: String) throws -> Curve25519.Signing.PrivateKey {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
            throw UpdateError.invalidPrivateKey
        }
        return key
    }
}

/// The result of `stew update`, as one JSON line between the daemon and the command.
public struct UpdateOutcome: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Nothing newer, or the newer version was just installed.
        case upToDate, installed
        /// Found by `stew update --check`; not installed.
        case available
        case needsNewerMacOS
        /// Downloaded and verified; installs as soon as no request is open.
        case deferred
        /// The check itself failed: network, HTTP status, or an invalid manifest.
        case checkFailed
        /// The download did not pass verification.
        case rejected
        /// Moving the new app into place failed; the old one stays.
        case installFailed
    }

    public var status: Status
    public var message: String
    public var version: String?

    public init(status: Status, message: String, version: String? = nil) {
        self.status = status
        self.message = message
        self.version = version
    }

    /// `stew update` exit codes; README "Updates" lists them.
    public var exitCode: Int32 {
        switch status {
        case .upToDate, .installed: 0
        case .available: 10
        case .needsNewerMacOS: 11
        case .deferred: 12
        case .checkFailed: 20
        case .rejected: 21
        case .installFailed: 22
        }
    }

    /// How a failure maps onto a status.
    public static func failure(_ error: Error) -> UpdateOutcome {
        guard let updateError = error as? UpdateError else { return UpdateOutcome(status: .checkFailed, message: "\(error)") }
        switch updateError {
        case .invalidManifest, .download: return UpdateOutcome(status: .checkFailed, message: updateError.description)
        case .install: return UpdateOutcome(status: .installFailed, message: updateError.description)
        default: return UpdateOutcome(status: .rejected, message: updateError.description)
        }
    }
}

/// Puts a verified new app in place of the installed one with two renames on one
/// volume: the installed app moves to `backup`, then the new app moves in. When the
/// second rename fails, the backup moves back, so there is always an app in place.
public enum AppSwap {
    /// `rename` returns 0 on success or an errno value, like rename(2) with errno.
    public static func swap(installed: String, staged: String, backup: String, rename: (String, String) -> Int32) throws {
        let aside = rename(installed, backup)
        guard aside == 0 else {
            throw UpdateError.install("cannot move \(installed) aside: \(String(cString: strerror(aside)))")
        }
        let moved = rename(staged, installed)
        guard moved == 0 else {
            let restored = rename(backup, installed)
            let state = restored == 0
                ? "the previous version is back in place"
                : "the previous version is still at \(backup): \(String(cString: strerror(restored)))"
            throw UpdateError.install("cannot move the new app into \(installed): \(String(cString: strerror(moved))); \(state)")
        }
    }
}
