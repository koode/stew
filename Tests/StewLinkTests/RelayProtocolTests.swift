import Foundation
import Testing
@testable import StewLink

struct RelayProtocolTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func parameters(_ header: String) -> [String: String] {
        let list = header.dropFirst(RelayAuth.scheme.count + 1).components(separatedBy: ", ")
        return Dictionary(uniqueKeysWithValues: list.map { part in
            let pieces = part.split(separator: "=", maxSplits: 1)
            return (String(pieces[0]), String(pieces[1]))
        })
    }

    @Test func authHeaderSignsMethodPathSideTimeNonceAndBody() throws {
        let identity = LinkIdentity()
        let body = Data("{\"deviceToken\":\"ab\"}".utf8)
        let nonce = Data(repeating: 1, count: 16)
        let header = try RelayAuth.header(method: "post", path: "/v2/pairings/pair/device", side: .phone, body: body, identity: identity, now: now, nonce: nonce)
        #expect(header.hasPrefix("Stew-Ed25519 side=phone, ts=1800000000, nonce=AQEBAQEBAQEBAQEBAQEBAQ, sig="))
        let values = parameters(header)
        let signature = try #require(Data(base64URLEncoded: values["sig"] ?? ""))
        #expect(signature.count == 64)
        let expected = RelayAuth.headerMessage(
            method: "POST", path: "/v2/pairings/pair/device", side: .phone, timestamp: 1_800_000_000,
            nonce: "AQEBAQEBAQEBAQEBAQEBAQ", bodyHash: RelayAuth.bodyHash(body)
        )
        #expect(String(decoding: expected, as: UTF8.self).components(separatedBy: "\n") == [
            "stew-relay/2", "POST", "/v2/pairings/pair/device", "phone", "1800000000", "AQEBAQEBAQEBAQEBAQEBAQ", RelayAuth.bodyHash(body),
        ])
        #expect(identity.signingKey.publicKey.isValidSignature(signature, for: expected))
        let otherBody = RelayAuth.headerMessage(
            method: "POST", path: "/v2/pairings/pair/device", side: .phone, timestamp: 1_800_000_000,
            nonce: "AQEBAQEBAQEBAQEBAQEBAQ", bodyHash: RelayAuth.bodyHash(Data("{}".utf8))
        )
        #expect(!identity.signingKey.publicKey.isValidSignature(signature, for: otherBody))
    }

    @Test func everyHeaderGetsItsOwnNonce() throws {
        let identity = LinkIdentity()
        let first = parameters(try RelayAuth.header(method: "GET", path: "/v2/pairings/pair/pending", side: .phone, body: nil, identity: identity))
        let second = parameters(try RelayAuth.header(method: "GET", path: "/v2/pairings/pair/pending", side: .phone, body: nil, identity: identity))
        #expect(first["nonce"] != second["nonce"])
        #expect(Data(base64URLEncoded: first["nonce"] ?? "")?.count == 16)
    }

    @Test func emptyBodyHashIsTheHashOfNothing() {
        #expect(RelayAuth.bodyHash(nil) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(RelayAuth.bodyHash(Data()) == RelayAuth.bodyHash(nil))
    }

    @Test func versionPaths() {
        #expect(RelayVersion.v2.pairingPath("abc", "socket") == "/v2/pairings/abc/socket")
        #expect(RelayVersion.v1.pairingPath("abc", "messages") == "/v1/pairings/abc/messages")
    }

    @Test func probeSpeaksV2OnlyWhenTheRelayListsIt() {
        let info = Data("{\"protocols\":[1,2],\"heartbeatSeconds\":25,\"answerTimeoutSeconds\":10}".utf8)
        #expect(RelayProbe.decide(status: 200, body: info).version == .v2)
        if case .v2(let decoded) = RelayProbe.decide(status: 200, body: info) {
            #expect(decoded.heartbeatSeconds == 25)
        } else {
            Issue.record("expected v2")
        }
        #expect(RelayProbe.decide(status: 200, body: Data("{\"protocols\":[3]}".utf8)) == .unsupported)
        #expect(RelayProbe.decide(status: 404, body: Data("{\"error\":\"not_found\"}".utf8)) == .v1)
        #expect(RelayProbe.decide(status: 426, body: Data()) == .unsupported)
        #expect(RelayProbe.decide(status: 0, body: Data()) == .unknown)
        #expect(RelayProbe.decide(status: 503, body: Data()) == .unknown)
        #expect(RelayProbe.decide(status: 200, body: Data("not json".utf8)) == .unknown)
    }

    @Test func framesDecodeInBothVersions() throws {
        let sides = try PairedSides()
        let envelope = try sides.phone.seal(LinkUnpair(reason: "test"), kind: .unpair, requestId: "pairing", expiresAt: Date().addingTimeInterval(60))
        let envelopeJSON = String(decoding: try LinkJSON.encode(envelope), as: UTF8.self)
        let v1 = Data("{\"type\":\"envelope\",\"envelope\":\(envelopeJSON)}".utf8)
        let v2 = Data("{\"t\":\"envelope\",\"pairingId\":\"\(envelope.pairingId)\",\"seq\":7,\"envelope\":\(envelopeJSON)}".utf8)
        #expect(try RelayIncoming.decode(v1) == .frame(RelayFrame(type: .envelope, envelope: envelope)))
        #expect(try RelayIncoming.decode(v2) == .frame(RelayFrame(type: .envelope, envelope: envelope, seq: 7, pairingId: envelope.pairingId)))
        let ready = Data("{\"t\":\"ready\",\"pairingId\":\"p\",\"protocol\":2,\"ackedSeq\":3,\"heartbeatSeconds\":25}".utf8)
        #expect(try RelayIncoming.decode(ready) == .ready(RelayReady(pairingId: "p", protocol: 2, ackedSeq: 3, heartbeatSeconds: 25)))
        #expect(try RelayIncoming.decode(Data("pong".utf8)) == .pong)
        let roundTrip = try LinkJSON.decode(RelayFrame.self, from: try LinkJSON.encode(RelayFrame(type: .hello, envelope: envelope, seq: 2, pairingId: "p")))
        #expect(roundTrip.seq == 2 && roundTrip.type == .hello)
    }

    @Test func acksAreTheRelaysJSON() throws {
        let cumulative = try #require(try JSONSerialization.jsonObject(with: Data(RelayAck.cumulative(pairingId: "p\"q", seq: 41).utf8)) as? [String: Any])
        #expect(cumulative["t"] as? String == "ack")
        #expect(cumulative["pairingId"] as? String == "p\"q")
        #expect(cumulative["seq"] as? Int == 41)
        let single = try #require(try JSONSerialization.jsonObject(with: Data(RelayAck.message("m1").utf8)) as? [String: Any])
        #expect(single["type"] as? String == "ack")
        #expect(single["messageId"] as? String == "m1")
    }

    @Test func aResentFrameIsHandledOnce() {
        var sequence = RelaySequence()
        let answers = [1, 2, 2, 1, 5].map { sequence.isNew($0) } + [sequence.isNew(nil)]
        #expect(answers == [true, true, false, false, true, true])
        #expect(sequence.handled == 5)
    }

    @Test func aMissingPongMakesTheSocketDead() {
        var heartbeat = RelayHeartbeat()
        #expect(!heartbeat.isOverdue(now: now))
        heartbeat.pingSent(at: now)
        #expect(!heartbeat.isOverdue(now: now.addingTimeInterval(9)))
        // A second ping before the pong keeps the first one's clock.
        heartbeat.pingSent(at: now.addingTimeInterval(5))
        #expect(heartbeat.isOverdue(now: now.addingTimeInterval(10)))
        heartbeat.pongReceived()
        #expect(!heartbeat.isOverdue(now: now.addingTimeInterval(60)))
    }

    @Test func closeCodesDecideWhatHappensNext() {
        #expect(RelayReconnect.afterClose(code: 1000, reason: nil) == .backoff)
        #expect(RelayReconnect.afterClose(code: 1001, reason: nil) == .soon)
        #expect(RelayReconnect.afterClose(code: 1006, reason: nil) == .backoff)
        #expect(RelayReconnect.afterClose(code: 1009, reason: nil) == .backoff)
        #expect(RelayReconnect.afterClose(code: 1011, reason: nil) == .backoff)
        #expect(RelayReconnect.afterClose(code: 4000, reason: "replaced") == .after(60))
        #expect(RelayReconnect.afterClose(code: 4001, reason: nil) == .authFailed)
        #expect(RelayReconnect.afterClose(code: 4004, reason: nil) == .stop(.unknownPairing))
        #expect(RelayReconnect.afterClose(code: 4008, reason: "idle") == .now)
        #expect(RelayReconnect.afterClose(code: 4010, reason: "unpaired") == .stop(.unpaired))
        #expect(RelayReconnect.afterClose(code: 4011, reason: "expired") == .stop(.claimExpired))
        #expect(RelayReconnect.afterClose(code: 4026, reason: nil) == .stop(.unsupportedProtocol))
        #expect(RelayReconnect.afterClose(code: 4002, reason: nil) == .stop(.planRequired(.socketRefusal)))
        #expect(RelayReconnect.afterClose(code: 4029, reason: "12") == .after(12))
        #expect(RelayReconnect.afterClose(code: 4029, reason: nil) == .after(10))
    }

    @Test func refusedUpgradesMapToTheSameActions() {
        #expect(RelayReconnect.afterRefusal(status: 401, retryAfter: nil) == .authFailed)
        #expect(RelayReconnect.afterRefusal(status: 404, retryAfter: nil) == .stop(.unknownPairing))
        #expect(RelayReconnect.afterRefusal(status: 426, retryAfter: nil) == .stop(.unsupportedProtocol))
        #expect(RelayReconnect.afterRefusal(status: 429, retryAfter: "7") == .after(7))
        // A WebSocket client cannot read the body of a refused upgrade, so 402 alone means
        // plan_required, with the fallback message and URL.
        #expect(RelayReconnect.afterRefusal(status: 402, retryAfter: nil) == .stop(.planRequired(.socketRefusal)))
        #expect(RelayPlanRequired.socketRefusal.upgradeURL == RelayPlanRequired.fallbackURL)
        #expect(RelayPlanRequired.socketRefusal.message == RelayPlanRequired.fallbackMessage)
        #expect(RelayReconnect.afterRefusal(status: 500, retryAfter: nil) == .backoff)
    }

    @Test func errorCodesComeFromTheBodyNotTheStatus() {
        #expect(RelayErrorCode.read(Data("{\"error\":\"mac_timeout\"}".utf8)) == "mac_timeout")
        #expect(RelayErrorCode.read(Data("<html>504: Gateway time-out</html>".utf8)) == nil)
        #expect(RelayErrorCode.read(Data()) == nil)
        #expect(RelayErrorCode.noRelayReply(status: 0, body: Data()))
        #expect(RelayErrorCode.noRelayReply(status: 502, body: Data("<html>Bad gateway</html>".utf8)))
        #expect(RelayErrorCode.noRelayReply(status: 522, body: Data()))
        #expect(!RelayErrorCode.noRelayReply(status: 500, body: Data("{\"error\":\"internal_error\"}".utf8)))
        #expect(!RelayErrorCode.noRelayReply(status: 404, body: Data()))
    }

    @Test func answerRefusalsAreReadByCode() {
        let timeout = Data("{\"error\":\"mac_timeout\"}".utf8)
        let page = Data("<!DOCTYPE html><title>stewcli.com | 504: Gateway time-out</title>".utf8)
        #expect(RelayAnswerRefusal.read(status: 503, body: timeout) == .macTimeout)
        #expect(RelayAnswerRefusal.read(status: 503, body: Data("{\"error\":\"mac_offline\"}".utf8)) == .macOffline)
        #expect(RelayAnswerRefusal.read(status: 429, body: Data("{\"error\":\"rate_limited\"}".utf8)) == .rateLimited)
        #expect(RelayAnswerRefusal.read(status: 409, body: Data("{\"error\":\"replayed\"}".utf8)) == .other(code: "replayed"))
        // v1 relays, and v2 relays before mac_timeout moved to 503, answer 504; behind
        // Cloudflare that 504 arrives as Cloudflare's page.
        #expect(RelayAnswerRefusal.read(status: 504, body: timeout) == .macTimeout)
        #expect(RelayAnswerRefusal.read(status: 504, body: page) == .macTimeout)
        // A 503 is not mac_offline by its status alone.
        #expect(RelayAnswerRefusal.read(status: 503, body: Data()) == .noRelayReply)
        #expect(RelayAnswerRefusal.read(status: 502, body: page) == .noRelayReply)
        #expect(RelayAnswerRefusal.read(status: 429, body: Data()) == .other(code: nil))
    }

    @Test func planRequiredIsReadByCodeWithItsMessageAndURL() throws {
        let body = Data(#"{"error":"plan_required","message":"Pushes to your iPhone need a stew plan.","upgradeUrl":"https://stewcli.com/plans"}"#.utf8)
        let plan = try #require(RelayPlanRequired.read(body))
        #expect(plan.message == "Pushes to your iPhone need a stew plan.")
        #expect(plan.upgradeURL.absoluteString == "https://stewcli.com/plans")
        #expect(RelayAnswerRefusal.read(status: 402, body: body) == .planRequired(plan))
        // The code decides, not the status.
        #expect(RelayAnswerRefusal.read(status: 400, body: body) == .planRequired(plan))
        #expect(RelayPlanRequired.read(Data(#"{"error":"mac_offline"}"#.utf8)) == nil)
        #expect(RelayPlanRequired.read(Data("<html>402</html>".utf8)) == nil)
        #expect(RelayAnswerRefusal.read(status: 402, body: Data()) == .other(code: nil))
    }

    @Test func aPlanRefusalWithoutDetailsFallsBack() throws {
        let plan = try #require(RelayPlanRequired.read(Data(#"{"error":"plan_required","message":"  "}"#.utf8)))
        #expect(plan.message == RelayPlanRequired.fallbackMessage)
        #expect(plan.upgradeURL == RelayPlanRequired.fallbackURL)
    }

    @Test func onlyHttpsURLsOnStewcliComAreOpened() {
        #expect(RelayPlanRequired.allowedURL("https://stewcli.com/plans?from=relay")?.absoluteString == "https://stewcli.com/plans?from=relay")
        #expect(RelayPlanRequired.allowedURL("https://www.stewcli.com/plans") != nil)
        #expect(RelayPlanRequired.allowedURL("HTTPS://STEWCLI.COM/") != nil)
        #expect(RelayPlanRequired.allowedURL("https://stewcli.com:443/") != nil)
        let refused = [
            "http://stewcli.com/plans",
            "https://evil.example/plans",
            "https://stewcli.com.evil.example/",
            "https://evilstewcli.com/",
            "https://stewcli.com@evil.example/",
            "https://user:pass@stewcli.com/",
            "https://stewcli.com:8443/",
            "stewcli://open",
            "javascript:alert(1)",
            "/plans",
            "",
        ]
        for text in refused {
            #expect(RelayPlanRequired.allowedURL(text) == nil, "\(text) must not be opened")
            #expect(RelayPlanRequired(message: "x", upgradeURL: text).upgradeURL == RelayPlanRequired.fallbackURL)
        }
        #expect(RelayPlanRequired.allowedURL(nil) == nil)
    }

    @Test func claimBodiesDifferByVersion() throws {
        let identity = LinkIdentity()
        let code = PairingCode.generate(relay: "https://relay.example.com", macName: "Studio", macKeys: identity.publicKeys)
        let v2 = try #require(try JSONSerialization.jsonObject(with: try LinkJSON.encode(RelayClaimV2(code: code, identity: identity))) as? [String: Any])
        #expect(Set(v2.keys) == ["macSigningKey", "registrationTokenHash"])
        #expect(v2["registrationTokenHash"] as? String == code.registrationTokenHash)
    }

    @Test func claimCarriesALeaseOnlyWhenGiven() throws {
        let identity = LinkIdentity()
        let code = PairingCode.generate(relay: "https://relay.example.com", macName: "Studio", macKeys: identity.publicKeys)
        let body = try LinkJSON.encode(RelayClaimV2(code: code, identity: identity, lease: "payload.signature"))
        let claim = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(claim.keys) == ["macSigningKey", "registrationTokenHash", "lease"])
        #expect(claim["lease"] as? String == "payload.signature")
        #expect(String(decoding: try LinkJSON.encode(RelayLease(lease: "a.b")), as: UTF8.self) == #"{"lease":"a.b"}"#)
    }

    @Test func infoIsAskedAgainForALeaseWhenTheRelayHadNone() {
        let withoutLeases = RelayProbe.v2(RelayInfo(protocols: [2]))
        let withLeases = RelayProbe.v2(RelayInfo(protocols: [2], leases: true))
        #expect(!RelayInfoRefresh.shouldAsk(cached: withoutLeases, age: 3600, purpose: .use))
        #expect(!RelayInfoRefresh.shouldAsk(cached: withoutLeases, age: 59, purpose: .lease))
        #expect(RelayInfoRefresh.shouldAsk(cached: withoutLeases, age: 60, purpose: .lease))
        #expect(!RelayInfoRefresh.shouldAsk(cached: withLeases, age: 3600, purpose: .lease))
    }

    @Test func infoIsAskedAgainAfterAPlanStop() {
        #expect(RelayInfoRefresh.shouldAsk(cached: .v2(RelayInfo(protocols: [2], leases: true)), age: 0, purpose: .planStop))
        #expect(RelayInfoRefresh.shouldAsk(cached: .v2(RelayInfo(protocols: [2])), age: 0, purpose: .planStop))
    }

    @Test func infoWithoutV2IsAskedAgainAfterTenMinutes() {
        #expect(RelayInfoRefresh.shouldAsk(cached: nil, age: 0, purpose: .use))
        #expect(RelayInfoRefresh.shouldAsk(cached: .unknown, age: 0, purpose: .use))
        #expect(!RelayInfoRefresh.shouldAsk(cached: .v1, age: 599, purpose: .use))
        #expect(RelayInfoRefresh.shouldAsk(cached: .v1, age: 600, purpose: .use))
        #expect(!RelayInfoRefresh.shouldAsk(cached: .unsupported, age: 599, purpose: .lease))
    }

    @Test func infoSaysWhetherTheRelayTakesLeases() {
        let withLeases = RelayProbe.decide(status: 200, body: Data(#"{"protocols":[1,2],"leases":true}"#.utf8))
        guard case .v2(let info) = withLeases else {
            Issue.record("expected v2")
            return
        }
        #expect(info.acceptsLeases)
        guard case .v2(let older) = RelayProbe.decide(status: 200, body: Data(#"{"protocols":[2]}"#.utf8)) else {
            Issue.record("expected v2")
            return
        }
        #expect(!older.acceptsLeases)
    }

    @Test func infoSaysWhetherPairingNeedsAPlan() {
        guard case .v2(let enforced) = RelayProbe.decide(status: 200, body: Data(#"{"protocols":[2],"leases":true,"plans":true}"#.utf8)) else {
            Issue.record("expected v2")
            return
        }
        #expect(enforced.requiresPlan)
        guard case .v2(let open) = RelayProbe.decide(status: 200, body: Data(#"{"protocols":[2],"leases":true}"#.utf8)) else {
            Issue.record("expected v2")
            return
        }
        #expect(!open.requiresPlan)
    }

    @Test func thePlanGateAsksAgainAfterTenMinutes() {
        let info = RelayProbe.v2(RelayInfo(protocols: [2], leases: true))
        #expect(!RelayInfoRefresh.shouldAsk(cached: info, age: 599, purpose: .planGate))
        #expect(RelayInfoRefresh.shouldAsk(cached: info, age: 600, purpose: .planGate))
        #expect(!RelayInfoRefresh.shouldAsk(cached: info, age: 600, purpose: .use))
    }
}
