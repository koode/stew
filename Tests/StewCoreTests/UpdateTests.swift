import Foundation
import Testing
@testable import StewCore

private let zip = Data("pretend this is Stew-0.2.0.zip".utf8)

private func manifest(
    version: String = "0.2.0",
    build: Int = 42,
    minimumMacOS: String = "14.0",
    url: String = "https://releases.stewcli.com/v0.2.0/Stew-0.2.0.zip",
    signature: String? = nil,
    sha256: String? = nil,
    size: Int? = nil
) -> UpdateManifest {
    UpdateManifest(
        version: version,
        build: build,
        published: "2026-11-20T10:00:00Z",
        minimumMacOS: minimumMacOS,
        notes: "https://stewcli.com/changelog#0.2.0",
        archive: .init(
            url: url,
            sha256: sha256 ?? UpdateVerifier.sha256Hex(zip),
            size: size ?? zip.count,
            ed25519: signature ?? Data(repeating: 1, count: 64).base64EncodedString()
        )
    )
}

private let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0)

@Suite struct SemanticVersionTests {
    @Test func comparesNumerically() throws {
        #expect(try #require(SemanticVersion("0.10.0")) > #require(SemanticVersion("0.9.9")))
        #expect(try #require(SemanticVersion("1.0.0")) > #require(SemanticVersion("0.99.99")))
        #expect(SemanticVersion("1.2") == SemanticVersion("1.2.0"))
        #expect(SemanticVersion("14") == SemanticVersion("14.0.0"))
    }

    @Test func preReleasesSortBeforeTheRelease() throws {
        let beta1 = try #require(SemanticVersion("1.0.0-beta.1"))
        let beta2 = try #require(SemanticVersion("1.0.0-beta.2"))
        let beta10 = try #require(SemanticVersion("1.0.0-beta.10"))
        let release = try #require(SemanticVersion("1.0.0"))
        #expect(beta1 < beta2)
        #expect(beta2 < beta10)
        #expect(beta10 < release)
        #expect(!(release < beta1))
        #expect(try #require(SemanticVersion("1.0.0-alpha")) < beta1)
    }

    @Test func refusesNonsense() {
        for text in ["", "v1.0.0", "1..0", "1.0.0.0", "1.0.0-", "1.0.0-be ta", "-1.0.0", "one"] {
            #expect(SemanticVersion(text) == nil, "\(text)")
        }
    }
}

@Suite struct UpdateManifestTests {
    @Test func decodesTheReleaseFormat() throws {
        let json = """
        {"version":"0.2.0","build":42,"published":"2026-11-20T10:00:00Z","minimumMacOS":"14.0",
         "notes":"https://stewcli.com/changelog#0.2.0",
         "archive":{"url":"https://releases.stewcli.com/v0.2.0/Stew-0.2.0.zip","sha256":"\(String(repeating: "ab", count: 32))",
                    "size":1234567,"ed25519":"\(Data(repeating: 7, count: 64).base64EncodedString())"}}
        """
        let decoded = try UpdateManifest.decode(Data(json.utf8))
        #expect(decoded.version == "0.2.0")
        #expect(decoded.build == 42)
        #expect(decoded.archive.size == 1_234_567)
    }

    @Test func refusesInvalidFields() {
        let invalid: [(String, UpdateManifest)] = [
            ("version", manifest(version: "latest")),
            ("build", manifest(build: 0)),
            ("macOS", manifest(minimumMacOS: "Sonoma")),
            ("http", manifest(url: "http://releases.stewcli.com/x.zip")),
            ("file", manifest(url: "file:///tmp/x.zip")),
            ("sha", manifest(sha256: "ABC")),
            ("size", manifest(size: 0)),
            ("signature", manifest(signature: "not base64!")),
        ]
        for (name, candidate) in invalid {
            #expect(throws: UpdateError.self, "\(name)") { try candidate.validate() }
        }
        #expect(throws: UpdateError.self) { try UpdateManifest.decode(Data("{}".utf8)) }
    }

    @Test func allowsPlainHTTPOnlyOnThisMachine() throws {
        #expect(UpdateManifest.isAllowedDownload(try #require(URL(string: "http://127.0.0.1:8123/latest.json"))))
        #expect(UpdateManifest.isAllowedDownload(try #require(URL(string: "http://localhost/x.zip"))))
        #expect(!UpdateManifest.isAllowedDownload(try #require(URL(string: "http://example.com/x.zip"))))
        #expect(UpdateManifest.isAllowedDownload(try #require(URL(string: "https://releases.stewcli.com/x.zip"))))
    }
}

@Suite struct UpdateDecisionTests {
    @Test func newerVersionOrBuildIsAvailable() {
        #expect(UpdateDecision.evaluate(manifest(), installed: AppVersion(version: "0.1.0", build: 50), macOS: sonoma) == .available)
        #expect(UpdateDecision.evaluate(manifest(), installed: AppVersion(version: "0.2.0", build: 41), macOS: sonoma) == .available)
        #expect(UpdateDecision.evaluate(manifest(), installed: AppVersion(version: "0.2.0", build: nil), macOS: sonoma) == .available)
    }

    @Test func sameOrOlderIsUpToDate() {
        #expect(UpdateDecision.evaluate(manifest(), installed: AppVersion(version: "0.2.0", build: 42), macOS: sonoma) == .upToDate)
        #expect(UpdateDecision.evaluate(manifest(), installed: AppVersion(version: "0.2.0", build: 43), macOS: sonoma) == .upToDate)
        #expect(UpdateDecision.evaluate(manifest(), installed: AppVersion(version: "0.3.0", build: 1), macOS: sonoma) == .upToDate)
    }

    @Test func tooNewForThisMacIsSkipped() {
        let decision = UpdateDecision.evaluate(manifest(minimumMacOS: "15.1"), installed: AppVersion(version: "0.1.0", build: 1), macOS: sonoma)
        #expect(decision == .needsNewerMacOS("15.1"))
        #expect(UpdateDecision.supports(minimumMacOS: "14.5", on: sonoma))
        #expect(!UpdateDecision.supports(minimumMacOS: "14.5.1", on: sonoma))
    }
}

@Suite struct UpdateVerifierTests {
    @Test func acceptsASignedZip() throws {
        let keys = UpdateSigner.generateKeyPair()
        let signature = try UpdateSigner.sign(zip, privateKey: keys.privateKey)
        try UpdateVerifier.verify(zip, against: manifest(signature: signature).archive, publicKey: keys.publicKey)
        #expect(try UpdateSigner.publicKey(forPrivateKey: keys.privateKey) == keys.publicKey)
    }

    @Test func rejectsTamperingAndOtherKeys() throws {
        let keys = UpdateSigner.generateKeyPair()
        let other = UpdateSigner.generateKeyPair()
        let signature = try UpdateSigner.sign(zip, privateKey: keys.privateKey)
        let archive = manifest(signature: signature).archive
        #expect(throws: UpdateError.badSignature) { try UpdateVerifier.verify(zip, against: archive, publicKey: other.publicKey) }

        var tampered = zip
        tampered[0] ^= 0xFF
        #expect(throws: UpdateError.checksumMismatch(expected: archive.sha256, actual: UpdateVerifier.sha256Hex(tampered))) {
            try UpdateVerifier.verify(tampered, against: archive, publicKey: keys.publicKey)
        }
        #expect(throws: UpdateError.sizeMismatch(expected: zip.count, actual: zip.count + 1)) {
            try UpdateVerifier.verify(zip + Data([0]), against: archive, publicKey: keys.publicKey)
        }
        // A zip that matches its manifest but was signed by someone else.
        let forged = manifest(signature: try UpdateSigner.sign(zip, privateKey: other.privateKey)).archive
        #expect(throws: UpdateError.badSignature) { try UpdateVerifier.verify(zip, against: forged, publicKey: keys.publicKey) }
        #expect(throws: UpdateError.noPublicKey) { try UpdateVerifier.verify(zip, against: archive, publicKey: "") }
        #expect(throws: UpdateError.invalidPublicKey) { try UpdateVerifier.verify(zip, against: archive, publicKey: "AAAA") }
    }

    @Test func hashesLikeShasum() {
        #expect(UpdateVerifier.sha256Hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func checksTheUnzippedBundle() throws {
        func plist(_ identifier: String, _ version: String, _ build: String) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": identifier, "CFBundleShortVersionString": version, "CFBundleVersion": build,
            ], format: .xml, options: 0)
        }
        try UpdateVerifier.checkBundle(infoPlist: try plist("nl.koode.stew", "0.2.0", "42"), matches: manifest())
        #expect(throws: UpdateError.self) { try UpdateVerifier.checkBundle(infoPlist: try plist("com.example.other", "0.2.0", "42"), matches: manifest()) }
        #expect(throws: UpdateError.self) { try UpdateVerifier.checkBundle(infoPlist: try plist("nl.koode.stew", "0.1.0", "42"), matches: manifest()) }
        #expect(throws: UpdateError.self) { try UpdateVerifier.checkBundle(infoPlist: try plist("nl.koode.stew", "0.2.0", "41"), matches: manifest()) }
    }

    @Test func readsTheTeamFromCodesign() {
        let developerID = "Executable=/x/Stew.app/Contents/MacOS/stew\nIdentifier=nl.koode.stew\nTeamIdentifier=PXD36584ME\nSealed Resources version=2"
        #expect(UpdateVerifier.teamIdentifier(fromCodesignOutput: developerID) == "PXD36584ME")
        #expect(UpdateVerifier.teamIdentifier(fromCodesignOutput: "Signature=adhoc\nTeamIdentifier=not set") == nil)
        #expect(UpdateVerifier.teamIdentifier(fromCodesignOutput: "code object is not signed at all") == nil)
    }
}

@Suite struct AppSwapTests {
    /// A pretend file system: paths that exist, and renames that fail on purpose.
    final class FakeVolume {
        var paths: Set<String>
        var failing: Set<String> = []
        var renames: [String] = []

        init(_ paths: Set<String>) { self.paths = paths }

        func rename(_ source: String, _ destination: String) -> Int32 {
            renames.append("\(source)>\(destination)")
            guard !failing.contains(destination) else { return EACCES }
            guard paths.remove(source) != nil else { return ENOENT }
            paths.insert(destination)
            return 0
        }
    }

    @Test func movesTheOldAppAsideAndTheNewOneIn() throws {
        let volume = FakeVolume(["/A/Stew.app", "/A/.stew-update/new/Stew.app"])
        try AppSwap.swap(installed: "/A/Stew.app", staged: "/A/.stew-update/new/Stew.app", backup: "/A/.stew-update/backup/Stew.app", rename: volume.rename)
        #expect(volume.paths == ["/A/Stew.app", "/A/.stew-update/backup/Stew.app"])
    }

    @Test func saysWhereTheBackupIsWhenRollbackFails() {
        let volume = FakeVolume(["/A/Stew.app", "/A/.stew-update/new/Stew.app"])
        // Every rename into /A/Stew.app fails: the new app's and the rollback's.
        volume.failing = ["/A/Stew.app"]
        do {
            try AppSwap.swap(installed: "/A/Stew.app", staged: "/A/.stew-update/new/Stew.app", backup: "/A/.stew-update/backup/Stew.app", rename: volume.rename)
            Issue.record("expected the swap to fail")
        } catch {
            #expect("\(error)".contains("still at /A/.stew-update/backup/Stew.app"))
        }
        #expect(volume.renames.last == "/A/.stew-update/backup/Stew.app>/A/Stew.app")
    }

    @Test func restoresTheBackupAfterAFailedMove() {
        let volume = FakeVolume(["/A/Stew.app"])
        // The staged app is missing, so the second rename fails and the backup goes back.
        #expect(throws: UpdateError.self) {
            try AppSwap.swap(installed: "/A/Stew.app", staged: "/A/.stew-update/new/Stew.app", backup: "/A/.stew-update/backup/Stew.app", rename: volume.rename)
        }
        #expect(volume.paths == ["/A/Stew.app"])
    }

    @Test func leavesEverythingWhenTheOldAppCannotMove() {
        let volume = FakeVolume(["/A/.stew-update/new/Stew.app"])
        #expect(throws: UpdateError.self) {
            try AppSwap.swap(installed: "/A/Stew.app", staged: "/A/.stew-update/new/Stew.app", backup: "/A/.stew-update/backup/Stew.app", rename: volume.rename)
        }
        #expect(volume.paths == ["/A/.stew-update/new/Stew.app"])
        #expect(volume.renames.count == 1)
    }
}

@Suite struct UpdateOutcomeTests {
    @Test func exitCodes() {
        #expect(UpdateOutcome(status: .upToDate, message: "").exitCode == 0)
        #expect(UpdateOutcome(status: .installed, message: "").exitCode == 0)
        #expect(UpdateOutcome(status: .available, message: "").exitCode == 10)
        #expect(UpdateOutcome(status: .needsNewerMacOS, message: "").exitCode == 11)
        #expect(UpdateOutcome(status: .deferred, message: "").exitCode == 12)
        #expect(UpdateOutcome(status: .checkFailed, message: "").exitCode == 20)
        #expect(UpdateOutcome(status: .rejected, message: "").exitCode == 21)
        #expect(UpdateOutcome(status: .installFailed, message: "").exitCode == 22)
    }

    @Test func failuresMapToStatuses() {
        #expect(UpdateOutcome.failure(UpdateError.download("timed out")).status == .checkFailed)
        #expect(UpdateOutcome.failure(UpdateError.invalidManifest("x")).status == .checkFailed)
        #expect(UpdateOutcome.failure(UpdateError.badSignature).status == .rejected)
        #expect(UpdateOutcome.failure(UpdateError.codeSignature("x")).status == .rejected)
        #expect(UpdateOutcome.failure(UpdateError.install("x")).status == .installFailed)
    }
}
