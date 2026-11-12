import Foundation
import Testing
import StewCore
@testable import StewLink

struct PairedSides {
    let mac: LinkChannel
    let phone: LinkChannel
    let code: PairingCode
    let macIdentity: LinkIdentity
    let phoneIdentity: LinkIdentity

    init() throws {
        macIdentity = LinkIdentity()
        phoneIdentity = LinkIdentity()
        code = PairingCode.generate(relay: "https://relay.example.com", macName: "Studio", macKeys: macIdentity.publicKeys)
        mac = try LinkChannel(pairingId: code.pairingId, side: .mac, identity: macIdentity, peer: phoneIdentity.publicKeys, pairingSecret: code.secret)
        phone = try LinkChannel(pairingId: code.pairingId, side: .phone, identity: phoneIdentity, peer: macIdentity.publicKeys, pairingSecret: code.secret)
    }
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let soon = now.addingTimeInterval(60)

private func sampleAnswer() -> LinkAnswer {
    LinkAnswer(requestId: "request1", choice: .approve, note: "go ahead", phoneName: "iPhone", answeredAt: now)
}

@Suite struct LinkChannelTests {
    @Test func roundTripBothWays() throws {
        let sides = try PairedSides()
        var replay = ReplayGuard()
        let envelope = try sides.phone.seal(sampleAnswer(), kind: .answer, requestId: "request1", expiresAt: soon)
        #expect(envelope.sender == .phone)
        #expect(try sides.mac.open(envelope, as: LinkAnswer.self, now: now, replay: &replay) == sampleAnswer())

        let result = LinkResult(requestId: "request1", accepted: true, message: "Approved")
        let reply = try sides.mac.seal(result, kind: .result, requestId: "request1", expiresAt: soon, replyTo: envelope.messageId)
        var phoneReplay = ReplayGuard()
        #expect(try sides.phone.open(reply, as: LinkResult.self, now: now, replay: &phoneReplay) == result)
        #expect(reply.replyTo == envelope.messageId)
    }

    @Test func survivesJSON() throws {
        let sides = try PairedSides()
        let envelope = try sides.phone.seal(sampleAnswer(), kind: .answer, requestId: "request1", expiresAt: soon)
        let decoded = try LinkJSON.decode(LinkEnvelope.self, from: try LinkJSON.encode(envelope))
        var replay = ReplayGuard()
        #expect(try sides.mac.open(decoded, as: LinkAnswer.self, now: now, replay: &replay) == sampleAnswer())
    }

    @Test func plaintextIsNotInTheEnvelope() throws {
        let sides = try PairedSides()
        let envelope = try sides.phone.seal(sampleAnswer(), kind: .answer, requestId: "request1", expiresAt: soon)
        let json = String(decoding: try LinkJSON.encode(envelope), as: UTF8.self)
        #expect(!json.contains("go ahead"))
        #expect(!json.contains("iPhone"))
    }

    @Test func tamperedCiphertextIsRefused() throws {
        let sides = try PairedSides()
        var envelope = try sides.phone.seal(sampleAnswer(), kind: .answer, requestId: "request1", expiresAt: soon)
        envelope.ciphertext[envelope.ciphertext.count - 1] ^= 0x01
        var replay = ReplayGuard()
        #expect(throws: LinkError.badSignature) { try sides.mac.open(envelope, as: LinkAnswer.self, now: now, replay: &replay) }
    }

    @Test func movedToAnotherRequestIsRefused() throws {
        let sides = try PairedSides()
        var envelope = try sides.phone.seal(sampleAnswer(), kind: .answer, requestId: "request1", expiresAt: soon)
        envelope.requestId = "request2"
        var replay = ReplayGuard()
        #expect(throws: LinkError.badSignature) { try sides.mac.open(envelope, as: LinkAnswer.self, now: now, replay: &replay) }
    }

    @Test func changedKindIsRefused() throws {
        let sides = try PairedSides()
        var envelope = try sides.mac.seal(LinkResolved(requestId: "request1", outcome: .approved, resolvedAt: now), kind: .resolved, requestId: "request1", expiresAt: soon)
        envelope.kind = .request
        var replay = ReplayGuard()
        #expect(throws: LinkError.badSignature) { try sides.phone.open(envelope, as: LinkResolved.self, now: now, replay: &replay) }
    }

    /// A relay holding the signing key could re-sign a changed header, but the header is
    /// also the associated data of the encryption, so decryption still fails.
    @Test func resignedHeaderStillFailsDecryption() throws {
        let sides = try PairedSides()
        var envelope = try sides.phone.seal(sampleAnswer(), kind: .answer, requestId: "request1", expiresAt: soon)
        envelope.requestId = "request2"
        envelope.signature = try sides.phoneIdentity.sign(envelope.signedBytes)
        var replay = ReplayGuard()
        #expect(throws: LinkError.cannotDecrypt) { try sides.mac.open(envelope, as: LinkAnswer.self, now: now, replay: &replay) }
    }

    @Test func otherSignerIsRefused() throws {
        let sides = try PairedSides()
        var envelope = try sides.phone.seal(sampleAnswer(), kind: .answer, requestId: "request1", expiresAt: soon)
        envelope.signature = try LinkIdentity().sign(envelope.signedBytes)
        var replay = ReplayGuard()
        #expect(throws: LinkError.badSignature) { try sides.mac.open(envelope, as: LinkAnswer.self, now: now, replay: &replay) }
    }

    @Test func wrongPairingSecretCannotDecrypt() throws {
        let sides = try PairedSides()
        let impostor = try LinkChannel(pairingId: sides.code.pairingId, side: .mac, identity: sides.macIdentity, peer: sides.phoneIdentity.publicKeys, pairingSecret: LinkRandom.bytes(32))
        let envelope = try sides.phone.seal(sampleAnswer(), kind: .answer, requestId: "request1", expiresAt: soon)
        var replay = ReplayGuard()
        #expect(throws: LinkError.cannotDecrypt) { try impostor.open(envelope, as: LinkAnswer.self, now: now, replay: &replay) }
    }

    @Test func wrongAgreementKeyCannotDecrypt() throws {
        let sides = try PairedSides()
        // Same signing key, so the signature passes; a different X25519 key cannot decrypt.
        let otherKeys = LinkPublicKeys(agreement: LinkIdentity().publicKeys.agreement, signing: sides.phoneIdentity.publicKeys.signing)
        let impostor = try LinkChannel(pairingId: sides.code.pairingId, side: .mac, identity: sides.macIdentity, peer: otherKeys, pairingSecret: sides.code.secret)
        let envelope = try sides.phone.seal(sampleAnswer(), kind: .answer, requestId: "request1", expiresAt: soon)
        var replay = ReplayGuard()
        #expect(throws: LinkError.cannotDecrypt) { try impostor.open(envelope, as: LinkAnswer.self, now: now, replay: &replay) }
    }

    @Test func otherPairingIsRefused() throws {
        let sides = try PairedSides()
        let other = try PairedSides()
        let envelope = try other.phone.seal(sampleAnswer(), kind: .answer, requestId: "request1", expiresAt: soon)
        var replay = ReplayGuard()
        #expect(throws: LinkError.wrongPairing) { try sides.mac.open(envelope, as: LinkAnswer.self, now: now, replay: &replay) }
    }

    @Test func ownMessageReflectedBackIsRefused() throws {
        let sides = try PairedSides()
        let envelope = try sides.mac.seal(LinkResolved(requestId: "request1", outcome: .approved, resolvedAt: now), kind: .resolved, requestId: "request1", expiresAt: soon)
        var replay = ReplayGuard()
        #expect(throws: LinkError.wrongSender) { try sides.mac.open(envelope, as: LinkResolved.self, now: now, replay: &replay) }
    }

    @Test func replayIsRefused() throws {
        let sides = try PairedSides()
        let envelope = try sides.phone.seal(sampleAnswer(), kind: .answer, requestId: "request1", expiresAt: soon)
        var replay = ReplayGuard()
        _ = try sides.mac.open(envelope, as: LinkAnswer.self, now: now, replay: &replay)
        #expect(throws: LinkError.replayed) { try sides.mac.open(envelope, as: LinkAnswer.self, now: now.addingTimeInterval(5), replay: &replay) }
    }

    @Test func replayGuardSurvivesARestart() throws {
        let sides = try PairedSides()
        let envelope = try sides.phone.seal(sampleAnswer(), kind: .answer, requestId: "request1", expiresAt: soon)
        var replay = ReplayGuard()
        _ = try sides.mac.open(envelope, as: LinkAnswer.self, now: now, replay: &replay)
        var restored = try LinkJSON.decode(ReplayGuard.self, from: try LinkJSON.encode(replay))
        #expect(throws: LinkError.replayed) { try sides.mac.open(envelope, as: LinkAnswer.self, now: now, replay: &restored) }
    }

    @Test func forgedMessageDoesNotTakeTheId() throws {
        let sides = try PairedSides()
        let real = try sides.phone.seal(sampleAnswer(), kind: .answer, requestId: "request1", expiresAt: soon)
        var forged = real
        forged.signature = try LinkIdentity().sign(forged.signedBytes)
        var replay = ReplayGuard()
        #expect(throws: LinkError.badSignature) { try sides.mac.open(forged, as: LinkAnswer.self, now: now, replay: &replay) }
        #expect(try sides.mac.open(real, as: LinkAnswer.self, now: now, replay: &replay) == sampleAnswer())
    }

    @Test func expiredIsRefused() throws {
        let sides = try PairedSides()
        let envelope = try sides.phone.seal(sampleAnswer(), kind: .answer, requestId: "request1", expiresAt: soon)
        var replay = ReplayGuard()
        let late = soon.addingTimeInterval(ReplayGuard.clockSkew + 1)
        #expect(throws: LinkError.expired) { try sides.mac.open(envelope, as: LinkAnswer.self, now: late, replay: &replay) }
    }

    @Test func expiryWithinClockSkewIsAccepted() throws {
        let sides = try PairedSides()
        let envelope = try sides.phone.seal(sampleAnswer(), kind: .answer, requestId: "request1", expiresAt: soon)
        var replay = ReplayGuard()
        #expect(try sides.mac.open(envelope, as: LinkAnswer.self, now: soon.addingTimeInterval(30), replay: &replay) == sampleAnswer())
    }

    @Test func expiryTooFarAheadIsRefused() throws {
        let sides = try PairedSides()
        let envelope = try sides.phone.seal(sampleAnswer(), kind: .answer, requestId: "request1", expiresAt: now.addingTimeInterval(30 * 24 * 3600))
        var replay = ReplayGuard()
        #expect(throws: LinkError.expiresTooLate) { try sides.mac.open(envelope, as: LinkAnswer.self, now: now, replay: &replay) }
    }

    @Test func replayGuardForgetsExpiredIds() throws {
        var replay = ReplayGuard()
        replay.record("first", expiresAt: Int(now.timeIntervalSince1970), now: now)
        replay.prune(now: now.addingTimeInterval(ReplayGuard.clockSkew + 1))
        #expect(!replay.contains("first"))
    }

    @Test func idsWithNewlinesCannotBeSealed() throws {
        let sides = try PairedSides()
        #expect(throws: LinkError.malformed) {
            try sides.phone.seal(sampleAnswer(), kind: .answer, requestId: "request1\nkind", expiresAt: soon)
        }
    }

    @Test func headerIsStable() {
        let envelope = LinkEnvelope(pairingId: "pair", kind: .answer, sender: .phone, requestId: "request", messageId: "message", replyTo: "", expiresAt: 42, ciphertext: Data([1, 2, 3]))
        #expect(String(decoding: envelope.signedBytes, as: UTF8.self) == "stew-link/1\npair\nanswer\nphone\nrequest\nmessage\n\n42\nAQID")
    }
}

@Suite struct PairingCodeTests {
    @Test func textRoundTrip() throws {
        let code = PairingCode.generate(relay: "https://relay.stewcli.com", macName: "Studio", macKeys: LinkIdentity().publicKeys)
        #expect(code.text.hasPrefix("stew://pair?code="))
        #expect(try PairingCode(text: "  " + code.text + "\n") == code)
    }

    @Test func refusesOtherText() {
        #expect(throws: PairingCode.InvalidCode.self) { try PairingCode(text: "https://example.com") }
        #expect(throws: PairingCode.InvalidCode.self) { try PairingCode(text: "stew://pair?code=abc") }
    }

    @Test func refusesNonHTTPRelay() throws {
        var code = PairingCode.generate(relay: "https://relay.stewcli.com", macName: "Studio", macKeys: LinkIdentity().publicKeys)
        code.relay = "file:///etc/passwd"
        #expect(throws: PairingCode.InvalidCode.self) { try PairingCode(text: code.text) }
    }

    @Test func registrationTokenIsNotTheSecret() {
        let code = PairingCode.generate(relay: "https://relay.stewcli.com", macName: "Studio", macKeys: LinkIdentity().publicKeys)
        #expect(Data(base64URLEncoded: code.registrationToken) != code.secret)
        #expect(code.registrationTokenHash.count == 64)
    }

    @Test func verificationCodeMatchesOnBothSidesAndChangesWithKeys() {
        let code = PairingCode.generate(relay: "https://relay.stewcli.com", macName: "Studio", macKeys: LinkIdentity().publicKeys)
        let phone = LinkIdentity().publicKeys.signing
        let shown = code.verificationCode(phoneSigning: phone)
        #expect(shown == code.verificationCode(phoneSigning: phone))
        #expect(shown.count == 7)
        #expect(shown != code.verificationCode(phoneSigning: LinkIdentity().publicKeys.signing))
    }

    @Test func base64URLRoundTrip() {
        for count in 0..<40 {
            let data = LinkRandom.bytes(count)
            #expect(Data(base64URLEncoded: data.base64URLEncoded) == data)
            #expect(!data.base64URLEncoded.contains("="))
        }
    }

    @Test func relayAuthSignatureVerifies() throws {
        let identity = LinkIdentity()
        let query = try RelayAuth.query(signing: { RelayAuth.socketMessage(pairingId: "pair", timestamp: $0) }, identity: identity, now: now)
        let parts = Dictionary(uniqueKeysWithValues: query.split(separator: "&").map { part -> (String, String) in
            let pieces = part.split(separator: "=", maxSplits: 1)
            return (String(pieces[0]), String(pieces[1]))
        })
        #expect(parts["ts"] == "1800000000")
        let signature = try #require(Data(base64URLEncoded: parts["sig"] ?? ""))
        #expect(identity.signingKey.publicKey.isValidSignature(signature, for: RelayAuth.socketMessage(pairingId: "pair", timestamp: 1_800_000_000)))
    }
}
