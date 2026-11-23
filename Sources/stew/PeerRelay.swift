import Foundation
import StewCore
import StewLink

/// This Mac in the phone's part of another Mac's pairing: that Mac's requests show on this
/// Mac's panel, and the answers go back through the relay, end to end encrypted, as a
/// phone's do.
///
/// Pairing two Macs makes two relay pairings, one per direction. Mac A shows a code
/// (`stew pair code`); Mac B joins it (`stew pair CODE`) and shows six digits, which the
/// user types on A's panel, as for an iPhone. B's panel asks whether A may answer B's
/// requests too. Once the user allows it, B makes a pairing of its own and hands its code
/// to A through the first one; A joins it, and B takes it at once because it comes from
/// A's keys. Neither step can happen from the command line alone: a pairing lets the
/// other Mac approve requests, so a process on either Mac must not be able to pair a
/// device of its own.
final class PeerRelay {
    static let shared = PeerRelay()

    enum JoinState: Equatable {
        case registering, joined, approved, linked
        case failed(String)

        var text: String {
            switch self {
            case .registering: "registering"
            case .joined: "joined"
            case .approved: "approved"
            case .linked: "linked"
            case .failed(let message): "error: \(message)"
            }
        }
    }

    private weak var coordinator: Coordinator?
    private var connections: [String: RelayConnection] = [:]
    private var replayGuards: [String: ReplayGuard] = [:]
    /// Joins this process started, for `stew pair CODE` to follow.
    private var joinStates: [String: JoinState] = [:]
    private var handoverTimers: [String: Timer] = [:]
    /// How long the reverse pairing's code keeps being handed over while the other Mac
    /// waits for the user to type the digits.
    static let handoverLifetime: TimeInterval = 600

    private var phone: PhoneLink { PhoneLink.shared }
    private var store: PhoneStore? { phone.linkStore }
    var joined: [JoinedPairing] { store?.joined ?? [] }

    func start(coordinator: Coordinator) {
        self.coordinator = coordinator
        coordinator.onPeerEngaged = { [weak self] item in self?.sendViewing(item) }
        for pairing in joined {
            connect(pairing)
            // A join the user had not answered yet asks again; one approved but not handed
            // over yet tries again.
            if !pairing.approved { askToApprove(pairing) } else if pairing.linkedPairing == nil { handOver(pairing) }
        }
    }


    /// Joins another Mac's pairing with its code. Returns the six digits to type on that
    /// Mac, or why it cannot join. The relay call runs on; `joinState` follows it.
    func join(_ text: String, handedOver: Bool = false, linkedPairing: String? = nil) -> Result<(pairingId: String, digits: String), JoinRefusal> {
        guard let store else { return .failure(JoinRefusal("stew's link is not ready")) }
        let code: PairingCode
        do {
            code = try PairingCode(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return .failure(JoinRefusal("that is not a stew pairing code"))
        }
        let identity = store.identity
        guard code.macKeys != identity.publicKeys else { return .failure(JoinRefusal("that code is this Mac's own")) }
        guard !joined.contains(where: { $0.pairingId == code.pairingId }) else { return .failure(JoinRefusal("this Mac already joined that code")) }
        let digits = code.verificationCode(phoneSigning: identity.publicKeys.signing)
        let pairing = JoinedPairing(code: code, approved: handedOver, handedOver: handedOver, linkedPairing: linkedPairing, joinedAt: Date())
        joinStates[code.pairingId] = .registering
        do {
            let channel = try pairing.channel(identity: identity)
            let hello = try channel.seal(
                LinkHello(phoneName: phone.macName, phoneKeys: identity.publicKeys, isMac: true),
                kind: .hello, requestId: "pairing", expiresAt: Date().addingTimeInterval(3600)
            )
            let registration = RelayRegistration(
                registrationToken: code.registrationToken, deviceToken: nil, environment: nil, phoneKeys: identity.publicKeys, hello: hello
            )
            let body = try LinkJSON.encode(registration)
            let connection = makeConnection(code)
            connection.post("device", signed: false, body: { _ in body }) { [weak self] result in
                connection.stop()
                guard let self else { return }
                guard result.ok else {
                    let reason = result.status == 0 ? "cannot reach the relay at \(code.relay)" : "the relay refused (\(result.errorCode ?? String(result.status)))"
                    self.joinStates[code.pairingId] = .failed(reason)
                    Log.write("peer: joining \(code.macName) failed: \(reason)")
                    return
                }
                store.upsertJoined(pairing)
                self.joinStates[code.pairingId] = handedOver ? .linked : .joined
                self.connect(pairing)
                if handedOver {
                    Log.write("peer: joined the pairing \(code.macName) made for its own requests")
                } else {
                    self.askToApprove(pairing)
                }
            }
        } catch {
            joinStates[code.pairingId] = nil
            return .failure(JoinRefusal("\(error)"))
        }
        return .success((code.pairingId, digits))
    }

    struct JoinRefusal: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    func joinState(_ pairingId: String) -> JoinState? {
        if let pairing = joined.first(where: { $0.pairingId == pairingId }) {
            // Both ways only once the other Mac has joined this Mac's pairing too.
            let ownPaired = phone.pairings.contains { $0.pairingId == pairing.linkedPairing && $0.state == .paired }
            if pairing.handedOver || ownPaired { return .linked }
            return pairing.approved ? .approved : .joined
        }
        return joinStates[pairingId]
    }

    /// The user decides on this Mac's panel whether the other Mac may answer this Mac's
    /// requests. Denying leaves the pairing.
    private func askToApprove(_ pairing: JoinedPairing) {
        guard let coordinator, let store else { return }
        let digits = pairing.code.verificationCode(phoneSigning: store.identity.publicKeys.signing)
        let request = StewRequest(
            session: SessionInfo(name: "stew"),
            prompt: .permission(PermissionRequest(
                action: "Pair with \(pairing.macName), both ways",
                reason: "\(pairing.macName)'s requests then show here, and this Mac's requests show there; either Mac can answer them. To finish, type \(digits) on \(pairing.macName)'s panel."
            )),
            timeout: PhoneLink.codeLifetime
        )
        let pairingId = pairing.pairingId
        coordinator.showOwn(request) { [weak self] response in
            guard let self else { return }
            if response.status == .approved {
                self.approve(pairingId)
            } else {
                Log.write("peer: the user did not pair with \(pairing.macName) (\(response.status.rawValue))")
                self.leave(pairingId)
            }
        }
    }

    private func approve(_ pairingId: String) {
        guard let store, var pairing = joined.first(where: { $0.pairingId == pairingId }) else { return }
        pairing.approved = true
        store.upsertJoined(pairing)
        joinStates[pairingId] = .approved
        handOver(pairing)
    }

    /// Makes this Mac's pairing for its own requests and hands its code to the other Mac
    /// through the pairing just joined. That Mac takes it only once the user typed the
    /// digits there, so this tries again every few seconds until it does.
    private func handOver(_ pairing: JoinedPairing) {
        let pairingId = pairing.pairingId
        phone.startReversePairing(expectedPeer: pairing.code.macKeys, linkedJoin: pairingId) { [weak self] code in
            guard let self, let code else {
                self?.joinStates[pairingId] = .failed("could not make the pairing for this Mac's own requests")
                return
            }
            let started = Date()
            self.sendPeerLink(code, over: pairingId)
            self.handoverTimers[pairingId]?.invalidate()
            self.handoverTimers[pairingId] = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
                guard let self, let current = self.joined.first(where: { $0.pairingId == pairingId }), current.linkedPairing == nil,
                      Date().timeIntervalSince(started) < Self.handoverLifetime else {
                    timer.invalidate()
                    self?.handoverTimers[pairingId] = nil
                    return
                }
                self.sendPeerLink(code, over: pairingId)
            }
        }
    }

    private func sendPeerLink(_ code: PairingCode, over pairingId: String) {
        let answer = LinkAnswer(requestId: LinkPeer.requestId, choice: .peerLink(code.text), phoneName: phone.macName)
        send(answer, over: pairingId) { [weak self] result in
            guard let self, let result, result.accepted, let store,
                  var pairing = self.joined.first(where: { $0.pairingId == pairingId }) else { return }
            pairing.linkedPairing = code.pairingId
            store.upsertJoined(pairing)
            self.joinStates[pairingId] = .linked
            self.handoverTimers.removeValue(forKey: pairingId)?.invalidate()
            Log.write("peer: \(pairing.macName) took this Mac's pairing; requests go both ways")
        }
    }


    private func makeConnection(_ code: PairingCode) -> RelayConnection {
        let connection = RelayConnection(pairingId: code.pairingId, relay: code.relay, identity: store!.identity)
        connection.side = .phone
        return connection
    }

    private func connect(_ pairing: JoinedPairing) {
        guard store != nil, connections[pairing.pairingId] == nil else { return }
        let connection = makeConnection(pairing.code)
        let pairingId = pairing.pairingId
        connection.onFrame = { [weak self] frame in self?.received(frame, pairingId: pairingId) ?? .handled }
        connection.onStop = { [weak self] reason in
            if case .unpaired = reason { self?.forget(pairingId, cascade: true) }
        }
        connections[pairingId] = connection
        connection.connect()
    }

    private func received(_ frame: RelayFrame, pairingId: String) -> RelayConnection.FrameHandling {
        guard let store, let coordinator, let pairing = joined.first(where: { $0.pairingId == pairingId }),
              frame.type == .envelope, let channel = try? pairing.channel(identity: store.identity) else { return .handled }
        var replay = replayGuards[pairingId] ?? ReplayGuard()
        defer { replayGuards[pairingId] = replay }
        do {
            switch frame.envelope.kind {
            case .request:
                let request = try channel.open(frame.envelope, as: LinkRequest.self, replay: &replay)
                guard request.requestId == frame.envelope.requestId, PeerCopy.shows(request.request) else { return .handled }
                coordinator.showPeerCopy(request.request, from: pairing.macName, linkID: request.requestId) { [weak self] item, response in
                    self?.answer(item, response, over: pairingId)
                }
            case .resolved:
                coordinator.dropPeerCopy(linkID: frame.envelope.requestId)
            case .unpair:
                _ = try channel.open(frame.envelope, as: LinkUnpair.self, replay: &replay)
                forget(pairingId, cascade: true)
                return .finished
            default:
                break
            }
        } catch {
            Log.write("peer: refused a message from \(pairing.macName): \(error)")
        }
        return .handled
    }

    /// An answer given on this Mac's panel goes back as the phone's answer would.
    private func answer(_ item: Item, _ response: StewResponse, over pairingId: String) {
        guard let linkID = item.peerLinkID,
              let choice = PeerCopy.choice(for: response, to: item.request, flow: item.flow) else { return }
        let peerName = item.peer ?? "the other Mac"
        let answer = LinkAnswer(requestId: linkID, choice: choice, note: response.note, phoneName: phone.macName)
        send(answer, over: pairingId) { [weak self] result in
            guard let result, !result.accepted else { return }
            self?.coordinator?.showNotice(NotifyRequest(title: "\(peerName) did not take the answer", body: result.message, level: .warning))
        }
    }

    /// The user started answering here: the other Mac pauses its clock, as for a phone
    /// that has the request open.
    private func sendViewing(_ item: Item) {
        guard let linkID = item.peerLinkID,
              let pairingId = joined.first(where: { $0.macName == item.peer })?.pairingId else { return }
        send(LinkAnswer(requestId: linkID, choice: .viewing, phoneName: phone.macName), over: pairingId) { _ in }
    }

    private func send(_ answer: LinkAnswer, over pairingId: String, completion: @escaping (LinkResult?) -> Void) {
        guard let store, let pairing = joined.first(where: { $0.pairingId == pairingId }),
              let channel = try? pairing.channel(identity: store.identity),
              let envelope = try? channel.seal(answer, kind: .answer, requestId: answer.requestId, expiresAt: Date().addingTimeInterval(120)) else {
            completion(nil)
            return
        }
        let connection = connections[pairingId] ?? makeConnection(pairing.code)
        connection.send(envelope) { result in
            guard result.ok, let reply = try? LinkJSON.decode(RelayAnswerReply.self, from: result.body),
                  reply.result.replyTo == envelope.messageId else {
                completion(nil)
                return
            }
            var replay = ReplayGuard()
            completion(try? channel.open(reply.result, as: LinkResult.self, replay: &replay))
        }
    }


    /// Leaves a joined pairing: the other Mac hears about it through the relay. `cascade`
    /// also ends this Mac's own pairing with that Mac, so both directions go together.
    func leave(_ pairingId: String, cascade: Bool = true) {
        guard let store, let pairing = joined.first(where: { $0.pairingId == pairingId }) else { return }
        if let channel = try? pairing.channel(identity: store.identity),
           let envelope = try? channel.seal(LinkUnpair(reason: "Unpaired on \(phone.macName)."), kind: .unpair, requestId: "pairing", expiresAt: Date().addingTimeInterval(3600)) {
            let connection = connections.removeValue(forKey: pairingId) ?? makeConnection(pairing.code)
            connection.send(envelope) { _ in connection.stop() }
        }
        forget(pairingId, cascade: cascade)
    }

    /// Forgets a joined pairing without telling the relay, after the other Mac ended it.
    func forget(_ pairingId: String, cascade: Bool) {
        guard let store, let pairing = joined.first(where: { $0.pairingId == pairingId }) else { return }
        store.removeJoined(pairingId)
        connections.removeValue(forKey: pairingId)?.stop()
        replayGuards[pairingId] = nil
        joinStates[pairingId] = nil
        handoverTimers.removeValue(forKey: pairingId)?.invalidate()
        coordinator?.dropPeerCopies(from: pairing.macName)
        if cascade {
            for own in phone.pairings where own.linkedJoin == pairingId || own.pairingId == pairing.linkedPairing {
                phone.unpair(own.pairingId)
            }
        }
    }


    /// One line per paired Mac: its name, which directions work, and whether the relay
    /// link is up.
    func describe() -> [String] {
        var lines: [String] = []
        var seen = Set<String>()
        for pairing in joined {
            let own = phone.pairings.first { $0.linkedJoin == pairing.pairingId || $0.pairingId == pairing.linkedPairing }
            let both = own?.state == .paired
            let link = connections[pairing.pairingId]?.status == .connected ? "connected" : "not connected"
            lines.append("\(pairing.macName)\t\(both ? "both ways" : "its requests show here")\t\(link)")
            seen.insert(pairing.macName)
        }
        for own in phone.paired where own.isMac == true && !seen.contains(own.phoneName ?? "") {
            lines.append("\(own.phoneName ?? "Mac")\tthis Mac's requests show there\t-")
        }
        return lines
    }

    /// Ends the pairing with a Mac by name, in both directions.
    func unpair(name: String) -> Bool {
        let wanted = name.lowercased()
        var found = false
        for pairing in joined where pairing.macName.lowercased() == wanted {
            leave(pairing.pairingId)
            found = true
        }
        for own in phone.pairings where own.isMac == true && own.phoneName?.lowercased() == wanted {
            phone.unpair(own.pairingId)
            found = true
        }
        return found
    }


    /// `peer …` controls from `stew pair`, `stew peers` and `stew unpair`. They start a
    /// pairing or report on it; the steps that let another Mac answer requests happen
    /// only on the panels.
    func control(_ words: [String]) -> String? {
        guard words.first == "peer", words.count >= 2 else { return nil }
        let argument = words.dropFirst(2).joined(separator: " ")
        switch words[1] {
        case "code":
            phone.startPairing()
            return "started"
        case "code-state":
            if let code = phone.pairingCode { return "code \(code.pairingId) \(code.text)" }
            return phone.pairingError.map { "error: \($0)" } ?? "waiting"
        case "host-state":
            guard let own = phone.pairings.first(where: { $0.pairingId == argument }) else { return "gone" }
            let linked = joined.contains { $0.pairingId == own.linkedJoin || $0.linkedPairing == own.pairingId }
            if own.state == .paired { return linked ? "linked \(own.phoneName ?? "Mac")" : "paired \(own.phoneName ?? "Mac")" }
            return own.state == .confirming ? "confirming \(own.phoneName ?? "Mac")" : "waiting"
        case "join":
            switch join(argument) {
            case .success(let joined): return "joined \(joined.pairingId) \(joined.digits)"
            case .failure(let refusal): return "error: \(refusal.message)"
            }
        case "join-state":
            return joinState(argument)?.text ?? "gone"
        case "list":
            // One line on the socket: the client reads a single line.
            return (try? String(decoding: JSONEncoder().encode(describe()), as: UTF8.self)) ?? "[]"
        case "unpair":
            return unpair(name: argument) ? "unpaired" : "no paired Mac is called \(argument)"
        default:
            return "unknown peer control"
        }
    }
}
