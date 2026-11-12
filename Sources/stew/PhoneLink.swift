import AppKit
import CoreGraphics
import Foundation
import StewCore
import StewLink

/// Sends open requests to paired iPhones and applies their answers. It watches the
/// coordinator once a second instead of hooking into every change, so the panel code
/// stays as it is: the coordinator only reports responses and passes on unknown controls.
final class PhoneLink: ObservableObject {
    static let shared = PhoneLink()

    @Published private(set) var pairings: [MacPairing] = []
    @Published private(set) var statuses: [String: RelayConnection.Status] = [:]
    /// The code on screen while a pairing waits for a phone.
    @Published private(set) var pairingCode: PairingCode?
    @Published private(set) var pairingError: String?

    private struct Pushed {
        var pairingIds: Set<String>
        var sent: LinkRequest
    }

    private var store: PhoneStore?
    private weak var coordinator: Coordinator?
    private var connections: [String: RelayConnection] = [:]
    private var replayGuards: [String: ReplayGuard] = [:]
    private var pushed: [UUID: Pushed] = [:]
    /// Which pairing answered a request, so its "resolved" carries the right outcome.
    private var answeredBy: [UUID: String] = [:]
    /// Outcomes of recent requests, so a late answer gets a reason and not just "no".
    private var recentlyResolved: [String: (outcome: LinkOutcome, pairingId: String?, at: Date)] = [:]
    private var timer: Timer?
    let macName = Host.current().localizedName ?? "Mac"

    static let recentLifetime: TimeInterval = 3600
    /// The longest a request waits on the relay when it has no time limit.
    static let unlimitedLifetime: TimeInterval = 24 * 3600
    /// A deadline that moved less than this is not worth a push.
    static let deadlineTolerance: TimeInterval = 3

    var paired: [MacPairing] { pairings.filter { $0.state == .paired } }
    var confirming: MacPairing? { pairings.first { $0.state == .confirming } }

    func start(coordinator: Coordinator) {
        self.coordinator = coordinator
        let store = PhoneStore()
        self.store = store
        pairings = store.pairings
        for pairing in pairings { connect(pairing) }
        coordinator.onRespond = { [weak self] item, response in self?.responded(item, response) }
        coordinator.onControl = { [weak self] control in self?.control(control) }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func verificationCode(for pairing: MacPairing) -> String? {
        guard let store, let phoneKeys = pairing.phoneKeys else { return nil }
        return pairing.pairingCode(macKeys: store.identity.publicKeys).verificationCode(phoneSigning: phoneKeys.signing)
    }

    private func connect(_ pairing: MacPairing) {
        guard let store, connections[pairing.pairingId] == nil else { return }
        let connection = RelayConnection(pairingId: pairing.pairingId, relay: pairing.relay, identity: store.identity)
        connection.onFrame = { [weak self] frame in self?.received(frame, pairingId: pairing.pairingId) }
        connection.onStatus = { [weak self] status in self?.statuses[pairing.pairingId] = status }
        connections[pairing.pairingId] = connection
        connection.connect()
    }

    private func disconnect(_ pairingId: String) {
        connections.removeValue(forKey: pairingId)?.stop()
        statuses[pairingId] = nil
        replayGuards[pairingId] = nil
    }

    private func save(_ pairing: MacPairing) {
        store?.upsert(pairing)
        pairings = store?.pairings ?? []
    }

    private func forget(_ pairingId: String) {
        store?.remove(pairingId)
        pairings = store?.pairings ?? []
        disconnect(pairingId)
        for (itemID, entry) in pushed where entry.pairingIds.contains(pairingId) {
            pushed[itemID]?.pairingIds.remove(pairingId)
        }
    }

    /// Shows a QR code for a new phone. A code still waiting is shown again rather than
    /// replaced, so a phone that already scanned it can still register.
    func startPairing() {
        guard let store, let coordinator else { return }
        pairingError = nil
        if let waiting = pairings.first(where: { $0.state == .waiting }) {
            pairingCode = waiting.pairingCode(macKeys: store.identity.publicKeys)
            return
        }
        let relay = coordinator.config.phone.relay
        let code = PairingCode.generate(relay: relay, macName: macName, macKeys: store.identity.publicKeys)
        guard let claim = try? RelayClaim(code: code, identity: store.identity), let body = try? LinkJSON.encode(claim) else { return }
        let pairing = MacPairing(pairingId: code.pairingId, relay: relay, macName: macName, secret: code.secret, state: .waiting, createdAt: Date())
        let connection = RelayConnection(pairingId: code.pairingId, relay: relay, identity: store.identity)
        connection.post("claim", body: body) { [weak self] result in
            connection.stop()
            guard let self else { return }
            guard result.ok else {
                self.pairingError = result.status == 0
                    ? "Cannot reach the relay at \(relay)."
                    : "The relay at \(relay) refused the pairing (\(result.status))."
                return
            }
            self.save(pairing)
            self.connect(pairing)
            self.pairingCode = code
        }
    }

    func cancelPairing() {
        pairingCode = nil
        for pairing in pairings where pairing.state == .waiting { forget(pairing.pairingId) }
    }

    func confirm(_ pairingId: String) {
        guard var pairing = pairings.first(where: { $0.pairingId == pairingId }), pairing.state == .confirming else { return }
        pairing.state = .paired
        pairing.pairedAt = Date()
        save(pairing)
        if pairingCode?.pairingId == pairingId { pairingCode = nil }
    }

    /// Ends a pairing on both sides: the phone hears about it through the relay.
    func unpair(_ pairingId: String) {
        guard let pairing = pairings.first(where: { $0.pairingId == pairingId }) else { return }
        if pairingCode?.pairingId == pairingId { pairingCode = nil }
        let connection = connections[pairingId]
        if let store, let channel = try? pairing.channel(identity: store.identity),
           let envelope = try? channel.seal(LinkUnpair(reason: "Unpaired on \(macName)."), kind: .unpair, requestId: "pairing", expiresAt: Date().addingTimeInterval(7 * 24 * 3600 - 60)) {
            // Keep the connection alive until the relay has the message.
            connections.removeValue(forKey: pairingId)
            connection?.send(envelope) { _ in connection?.stop() }
        }
        forget(pairingId)
    }

    private func received(_ frame: RelayFrame, pairingId: String) {
        guard let store, var pairing = pairings.first(where: { $0.pairingId == pairingId }) else { return }
        var replay = replayGuards[pairingId] ?? ReplayGuard()
        defer { replayGuards[pairingId] = replay }
        do {
            switch frame.type {
            case .hello:
                guard pairing.state == .waiting, let phoneKeys = try frame.phoneKeys?.validated() else { return }
                let channel = try LinkChannel(pairingId: pairingId, side: .mac, identity: store.identity, peer: phoneKeys, pairingSecret: pairing.secret)
                let hello = try channel.open(frame.envelope, as: LinkHello.self, replay: &replay)
                guard frame.envelope.kind == .hello, hello.phoneKeys == phoneKeys else {
                    Log.write("phone: hello keys do not match the relay's copy; ignored")
                    return
                }
                pairing.state = .confirming
                pairing.phoneName = String(hello.phoneName.prefix(60))
                pairing.phoneKeys = phoneKeys
                save(pairing)
            case .envelope:
                guard let channel = try pairing.channel(identity: store.identity) else { return }
                switch frame.envelope.kind {
                case .answer:
                    // Answers count only from a phone the user confirmed on this Mac.
                    guard pairing.state == .paired else { return }
                    let answer = try channel.open(frame.envelope, as: LinkAnswer.self, replay: &replay)
                    guard answer.requestId == frame.envelope.requestId else { return }
                    let result = apply(answer, from: pairingId)
                    reply(result, to: frame.envelope, channel: channel)
                case .unpair:
                    _ = try channel.open(frame.envelope, as: LinkUnpair.self, replay: &replay)
                    if pairingCode?.pairingId == pairingId { pairingCode = nil }
                    forget(pairingId)
                default:
                    return
                }
            }
        } catch {
            Log.write("phone: refused a message for pairing \(pairingId): \(error)")
        }
    }

    private func reply(_ result: LinkResult, to answer: LinkEnvelope, channel: LinkChannel) {
        guard let envelope = try? channel.seal(result, kind: .result, requestId: answer.requestId, expiresAt: Date().addingTimeInterval(120), replyTo: answer.messageId) else { return }
        connections[channel.pairingId]?.send(envelope)
    }

    /// The Mac's state decides, whatever the phone believed when it answered.
    private func apply(_ answer: LinkAnswer, from pairingId: String) -> LinkResult {
        let requestId = answer.requestId
        func refuse(_ message: String) -> LinkResult { LinkResult(requestId: requestId, accepted: false, message: message) }
        guard let coordinator,
              let item = coordinator.items.first(where: { $0.id.uuidString == requestId }),
              pushed[item.id]?.pairingIds.contains(pairingId) == true else {
            if let recent = recentlyResolved[requestId] {
                return refuse(recent.pairingId == pairingId ? LinkRefusal.alreadyAnswered : LinkRefusal.closed(recent.outcome, macName: macName))
            }
            return refuse(LinkRefusal.closed(nil, macName: macName))
        }
        if let deadline = item.deadline, deadline <= Date() {
            return refuse(LinkRefusal.tooLate(macName: macName, deadline: deadline))
        }
        let note = answer.note.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        switch (answer.choice, item.request.prompt) {
        case (.approve, .permission):
            guard !item.isHardDeny else { return refuse(LinkRefusal.macOnly) }
            answeredBy[item.id] = pairingId
            coordinator.respond(item, StewResponse(status: .approved, note: note, risk: item.risk.assessment))
            return LinkResult(requestId: requestId, accepted: true, message: "Approved on \(macName).")
        case (.deny, .permission):
            answeredBy[item.id] = pairingId
            coordinator.respond(item, StewResponse(status: .denied, note: note, risk: item.risk.assessment))
            return LinkResult(requestId: requestId, accepted: true, message: "Denied on \(macName).")
        case (.moreTime, .permission), (.moreTime, .question):
            guard item.timeLimit != nil else { return refuse(LinkRefusal.noTimeLimit) }
            guard coordinator.current?.id == item.id, item.deadline != nil || item.pausedRemaining != nil else {
                return refuse(LinkRefusal.clockNotStarted)
            }
            coordinator.extendTime()
            let deadline = item.deadline ?? item.pausedRemaining.map { Date().addingTimeInterval($0) }
            return LinkResult(requestId: requestId, accepted: true, message: "More time on \(macName).", deadline: deadline)
        case (.answers(let answers), .question(let set)):
            guard let flow = QuestionFlow(set: set, linkAnswers: answers) else {
                return refuse("Answer every question, with one choice where only one is allowed.")
            }
            answeredBy[item.id] = pairingId
            let annotations = flow.annotations()
            coordinator.respond(item, StewResponse(status: .answered, answers: flow.answers(), annotations: annotations.isEmpty ? nil : annotations))
            return LinkResult(requestId: requestId, accepted: true, message: "Answered on \(macName).")
        default:
            return refuse("This answer does not fit this request.")
        }
    }

    private func responded(_ item: Item, _ response: StewResponse) {
        let answering = answeredBy.removeValue(forKey: item.id)
        guard let entry = pushed.removeValue(forKey: item.id) else { return }
        let outcome: LinkOutcome
        if answering != nil {
            outcome = LinkOutcome(phoneStatus: response.status)
        } else {
            switch response.status {
            case .timeout: outcome = .timedOut
            case .dismissed: outcome = .dismissed
            default: outcome = .answeredOnMac
            }
        }
        resolve(item.id.uuidString, pairingIds: entry.pairingIds, outcome: outcome, answering: answering)
    }

    private func resolve(_ requestId: String, pairingIds: Set<String>, outcome: LinkOutcome, answering: String?) {
        recentlyResolved[requestId] = (outcome, answering, Date())
        guard let store else { return }
        for pairing in paired where pairingIds.contains(pairing.pairingId) {
            guard let channel = try? pairing.channel(identity: store.identity),
                  let envelope = try? channel.seal(LinkResolved(requestId: requestId, outcome: outcome), kind: .resolved, requestId: requestId, expiresAt: Date().addingTimeInterval(Self.recentLifetime)) else { continue }
            connections[pairing.pairingId]?.send(envelope)
        }
    }

    /// The request as the phone should see it now.
    private func linkRequest(for item: Item, previous: LinkRequest?) -> LinkRequest {
        var deadline = item.deadline
        if deadline == nil, let remaining = item.pausedRemaining {
            // Paused while someone types on the Mac: keep what the phone already shows.
            deadline = previous?.deadline ?? Date().addingTimeInterval(remaining)
        }
        let queued = item.timeLimit != nil && item.deadline == nil && item.pausedRemaining == nil
        return LinkRequest(
            requestId: item.id.uuidString,
            macName: macName,
            request: item.request,
            receivedAt: item.received,
            deadline: deadline,
            queued: queued,
            extendBy: item.timeLimit == nil ? nil : coordinator?.config.extendBy,
            hardDeny: item.isHardDeny,
            risk: item.risk.assessment
        )
    }

    private static func needsUpdate(_ old: LinkRequest, _ new: LinkRequest) -> Bool {
        if old.queued != new.queued || old.hardDeny != new.hardDeny || old.risk != new.risk { return true }
        switch (old.deadline, new.deadline) {
        case (nil, nil): return false
        case (let before?, let after?): return abs(before.timeIntervalSince(after)) > deadlineTolerance
        default: return true
        }
    }

    /// How long the relay keeps a request: a little past its deadline, so a late answer
    /// still reaches the Mac and gets a clear refusal.
    private func expiry(for request: LinkRequest, item: Item) -> Date {
        let now = Date()
        let latest = request.deadline ?? item.latestDeadline ?? now.addingTimeInterval(Self.unlimitedLifetime)
        return min(max(latest, now).addingTimeInterval(60), now.addingTimeInterval(6 * 24 * 3600))
    }

    private func send(_ request: LinkRequest, kind: LinkKind, item: Item, to pairingIds: Set<String>) {
        guard let store else { return }
        for pairing in paired where pairingIds.contains(pairing.pairingId) {
            guard let channel = try? pairing.channel(identity: store.identity),
                  let envelope = try? channel.seal(request, kind: kind, requestId: request.requestId, expiresAt: expiry(for: request, item: item)) else { continue }
            connections[pairing.pairingId]?.send(envelope)
        }
    }

    private func tick() {
        guard let coordinator else { return }
        let now = Date()
        recentlyResolved = recentlyResolved.filter { now.timeIntervalSince($0.value.at) < Self.recentLifetime }
        let liveIDs = Set(coordinator.items.map(\.id))
        for (itemID, entry) in pushed where !liveIDs.contains(itemID) {
            // The caller went away (Ctrl-C, a hook timeout) without an answer.
            pushed[itemID] = nil
            resolve(itemID.uuidString, pairingIds: entry.pairingIds, outcome: .dismissed, answering: nil)
        }
        let targets = Set(paired.map(\.pairingId))
        guard !targets.isEmpty else { return }
        var presence: MacPresence?
        for item in coordinator.items where !item.isNeeds {
            if var entry = pushed[item.id] {
                let fresh = linkRequest(for: item, previous: entry.sent)
                guard Self.needsUpdate(entry.sent, fresh) else { continue }
                send(fresh, kind: .update, item: item, to: entry.pairingIds)
                entry.sent = fresh
                pushed[item.id] = entry
                continue
            }
            let current = presence ?? Self.samplePresence()
            presence = current
            guard PushPolicy.shouldPush(config: coordinator.config.phone, openFor: now.timeIntervalSince(item.received), presence: current) else { continue }
            let request = linkRequest(for: item, previous: nil)
            send(request, kind: .request, item: item, to: targets)
            pushed[item.id] = Pushed(pairingIds: targets, sent: request)
        }
    }

    /// Idle time from the last keyboard, mouse or trackpad event, and the lock state of
    /// the login session. The headless test daemon can set STEW_PHONE_PRESENCE instead.
    static func samplePresence() -> MacPresence {
        if Paths.headless, let forced = ProcessInfo.processInfo.environment["STEW_PHONE_PRESENCE"] {
            return forced == "away" ? MacPresence(idleSeconds: .infinity, screenLocked: true) : MacPresence(idleSeconds: 0, screenLocked: false)
        }
        let anyInput = CGEventType(rawValue: ~0) ?? .null
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = (session?["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
        return MacPresence(idleSeconds: idle, screenLocked: locked)
    }

    /// Pairing from the socket exists only in the headless test daemon. On the real daemon
    /// a phone pairs through the settings window alone, so no local process can pair a
    /// phone of its own and approve its own requests.
    private func control(_ control: String) -> String? {
        let words = control.split(separator: " ").map(String.init)
        guard Paths.headless, words.first == "phone", words.count >= 2 else { return nil }
        switch words[1] {
        case "pair":
            startPairing()
            return "started"
        case "code":
            return pairingCode?.text ?? pairingError ?? "waiting"
        case "verification":
            return confirming.flatMap(verificationCode(for:)) ?? "none"
        case "confirm":
            guard let pairing = confirming else { return "nothing to confirm" }
            confirm(pairing.pairingId)
            return "confirmed"
        case "unpair":
            for pairing in pairings { unpair(pairing.pairingId) }
            return "unpaired"
        case "state":
            let connected = statuses.values.filter { $0 == .connected }.count
            return "pairings=\(pairings.count) paired=\(paired.count) confirming=\(confirming == nil ? 0 : 1) connected=\(connected) pushed=\(pushed.count)"
        default:
            return "unknown phone control"
        }
    }
}
