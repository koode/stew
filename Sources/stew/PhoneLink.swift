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
    /// Needs items sent to phones, by needs id, with the pairings they went to.
    private var pushedNeeds: [String: Set<String>] = [:]
    /// Which pairing marked a needs item done.
    private var needsDoneBy: [String: String] = [:]
    /// Which pairing answered a request, so its "resolved" carries the right outcome.
    private var answeredBy: [UUID: String] = [:]
    /// Outcomes of recent requests, so a late answer gets a reason and not just "no".
    private var recentlyResolved: [String: (outcome: LinkOutcome, pairingId: String?, at: Date)] = [:]
    /// Requests that timed out on phones, by request id: which phones had them, and
    /// whether auto mode never allows them, so a phone can answer them late but not
    /// approve what only the Mac may. Memory only: after a restart only the Mac answers late.
    private var lateAnswerable: [String: (pairingIds: Set<String>, hardDeny: Bool, confirmation: PhoneConfirmation?, at: Date)] = [:]
    private var timer: Timer?
    let macName = Host.current().localizedName ?? "Mac"

    static let recentLifetime: TimeInterval = 3600
    /// The longest a request waits on the relay when it has no time limit.
    static let unlimitedLifetime: TimeInterval = 24 * 3600
    /// A deadline that moved less than this is not worth a push.
    static let deadlineTolerance: TimeInterval = 3
    /// A pairing code stops working after this. It is a secret on screen and possibly on
    /// the clipboard, so it should not outlive the moment the user meant to pair.
    static let codeLifetime: TimeInterval = 600
    private var lastRefusalLog: [String: Date] = [:]

    var paired: [MacPairing] { pairings.filter { $0.state == .paired } }
    var confirming: MacPairing? { pairings.first { $0.state == .confirming } }

    /// When the code on screen stops working, for the countdown next to it.
    var pairingCodeExpires: Date? {
        guard let code = pairingCode,
              let waiting = pairings.first(where: { $0.pairingId == code.pairingId && $0.state == .waiting }) else { return nil }
        return waiting.createdAt.addingTimeInterval(Self.codeLifetime)
    }

    func start(coordinator: Coordinator) {
        self.coordinator = coordinator
        let store = PhoneStore()
        self.store = store
        pairings = store.pairings
        // A waiting code is no longer on screen after a restart, so nobody should use it.
        for pairing in pairings where pairing.state == .waiting {
            store.remove(pairing.pairingId)
        }
        pairings = store.pairings
        for pairing in pairings { connect(pairing) }
        coordinator.onRespond = { [weak self] item, response in self?.responded(item, response) }
        coordinator.answeringPhone = { [weak self] item in
            guard let self, let pairingId = self.answeredBy[item.id] else { return nil }
            return self.phoneName(pairingId)
        }
        coordinator.onControl = { [weak self] control in self?.control(control) }
        coordinator.onNeedsFinished = { [weak self] record, outcome in self?.needsFinished(record, outcome) }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// Sample state for `stew snapshot`, which never starts the link.
    func showSample(pairings: [MacPairing], statuses: [String: RelayConnection.Status], code: PairingCode?, error: String? = nil, store: PhoneStore) {
        self.store = store
        self.pairings = pairings
        self.statuses = statuses
        pairingCode = code
        pairingError = error
    }

    func verificationCode(for pairing: MacPairing) -> String? {
        guard let store, let phoneKeys = pairing.phoneKeys else { return nil }
        return pairing.pairingCode(macKeys: store.identity.publicKeys).verificationCode(phoneSigning: phoneKeys.signing)
    }

    private func connect(_ pairing: MacPairing) {
        guard let store, connections[pairing.pairingId] == nil else { return }
        let connection = RelayConnection(pairingId: pairing.pairingId, relay: pairing.relay, identity: store.identity)
        connection.onFrame = { [weak self] frame in self?.received(frame, pairingId: pairing.pairingId) ?? .handled }
        connection.onStatus = { [weak self] status in self?.statuses[pairing.pairingId] = status }
        connection.onStop = { [weak self] reason in self?.relayStopped(pairing.pairingId, reason: reason) }
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

    /// Shows a QR code for a new phone. Every call makes a new secret and drops any code
    /// still waiting, so a secret is never on screen twice.
    func startPairing() {
        guard let store, let coordinator else { return }
        cancelPairing()
        pairingError = nil
        let relay = coordinator.config.phone.relay
        let code = PairingCode.generate(relay: relay, macName: macName, macKeys: store.identity.publicKeys)
        let identity = store.identity
        let pairing = MacPairing(pairingId: code.pairingId, relay: relay, macName: macName, secret: code.secret, state: .waiting, createdAt: Date())
        let connection = RelayConnection(pairingId: code.pairingId, relay: relay, identity: identity)
        // The connection asks the relay for its protocol first, so a code never names a relay
        // this Mac cannot use.
        connection.post("claim", signed: true, body: { version in
            switch version {
            case .v2: try? LinkJSON.encode(RelayClaimV2(code: code, identity: identity))
            case .v1: (try? RelayClaim(code: code, identity: identity)).flatMap { try? LinkJSON.encode($0) }
            }
        }) { [weak self] result in
            connection.stop()
            guard let self else { return }
            guard result.ok else {
                switch result.status {
                case 0: self.pairingError = "Cannot reach the relay at \(relay)."
                case 426: self.pairingError = "The relay at \(relay) needs a newer stew. Update stew, then pair again."
                default: self.pairingError = "The relay at \(relay) refused the pairing (\(result.errorCode ?? String(result.status)))."
                }
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

    /// The user types the digits the phone shows. Clicking a button would also confirm a
    /// phone that never showed digits, such as when another device used the code first.
    @discardableResult
    func confirm(_ pairingId: String, digits: String) -> Bool {
        guard var pairing = pairings.first(where: { $0.pairingId == pairingId }), pairing.state == .confirming,
              let expected = verificationCode(for: pairing),
              digits.filter(\.isNumber) == expected.filter(\.isNumber) else { return false }
        pairing.state = .paired
        pairing.pairedAt = Date()
        save(pairing)
        if pairingCode?.pairingId == pairingId { pairingCode = nil }
        return true
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

    /// The relay ended the link for good, by its close code.
    private func relayStopped(_ pairingId: String, reason: RelayStop) {
        switch reason {
        case .unpaired:
            forget(pairingId)
        case .claimExpired:
            if pairingCode?.pairingId == pairingId {
                pairingCode = nil
                pairingError = "The pairing code expired. Show a new one."
            }
            forget(pairingId)
        case .unknownPairing, .unsupportedProtocol:
            // Kept, with the reason in its status, so the user decides: pair again or update.
            Log.write("phone: the relay stopped pairing \(pairingId): \(reason)")
        }
    }

    /// Handles one frame. The connection acks it afterwards, whatever happened here, and
    /// stops once that ack is out when this returns `finished`.
    private func received(_ frame: RelayFrame, pairingId: String) -> RelayConnection.FrameHandling {
        guard let store, var pairing = pairings.first(where: { $0.pairingId == pairingId }) else { return .handled }
        var replay = replayGuards[pairingId] ?? ReplayGuard()
        defer { replayGuards[pairingId] = replay }
        do {
            switch frame.type {
            case .hello:
                guard pairing.state == .waiting, let phoneKeys = try frame.phoneKeys?.validated() else { return .handled }
                let channel = try LinkChannel(pairingId: pairingId, side: .mac, identity: store.identity, peer: phoneKeys, pairingSecret: pairing.secret)
                let hello = try channel.open(frame.envelope, as: LinkHello.self, replay: &replay)
                guard frame.envelope.kind == .hello, hello.phoneKeys == phoneKeys else {
                    Log.write("phone: hello keys do not match the relay's copy; ignored")
                    return .handled
                }
                pairing.state = .confirming
                pairing.phoneName = String(hello.phoneName.prefix(60))
                pairing.phoneKeys = phoneKeys
                save(pairing)
            case .envelope:
                guard let channel = try pairing.channel(identity: store.identity) else { return .handled }
                switch frame.envelope.kind {
                case .answer:
                    // Answers count only from a phone the user confirmed on this Mac.
                    guard pairing.state == .paired else { return .handled }
                    let answer = try channel.open(frame.envelope, as: LinkAnswer.self, replay: &replay)
                    guard answer.requestId == frame.envelope.requestId else { return .handled }
                    let result = apply(answer, from: pairingId)
                    // The phone shows the reason too; the log keeps it for when it did not.
                    if !result.accepted {
                        Log.write("phone: refused the answer to \(answer.requestId): \(result.message)")
                    }
                    reply(result, to: frame.envelope, channel: channel)
                case .unpair:
                    _ = try channel.open(frame.envelope, as: LinkUnpair.self, replay: &replay)
                    if pairingCode?.pairingId == pairingId { pairingCode = nil }
                    // The connection keeps its socket until the relay has the ack, then stops.
                    connections.removeValue(forKey: pairingId)
                    forget(pairingId)
                    return .finished
                default:
                    return .handled
                }
            }
        } catch {
            // At most one line a minute per pairing, so a misbehaving relay cannot fill the log.
            if Date().timeIntervalSince(lastRefusalLog[pairingId] ?? .distantPast) > 60 {
                lastRefusalLog[pairingId] = Date()
                Log.write("phone: refused a message for pairing \(pairingId): \(error)")
            }
        }
        return .handled
    }

    private func reply(_ result: LinkResult, to answer: LinkEnvelope, channel: LinkChannel) {
        guard let envelope = try? channel.seal(result, kind: .result, requestId: answer.requestId, expiresAt: Date().addingTimeInterval(120), replyTo: answer.messageId) else { return }
        connections[channel.pairingId]?.send(envelope)
    }

    /// The Mac's state decides, whatever the phone believed when it answered.
    private func apply(_ answer: LinkAnswer, from pairingId: String) -> LinkResult {
        let requestId = answer.requestId
        func refuse(_ message: String) -> LinkResult { LinkResult(requestId: requestId, accepted: false, message: message) }
        let needsPrefix = LinkPresentation.needsRequestId("")
        if requestId.hasPrefix(needsPrefix) {
            return applyNeeds(answer, needsID: String(requestId.dropFirst(needsPrefix.count)), from: pairingId)
        }
        guard let coordinator,
              let item = coordinator.items.first(where: { $0.id.uuidString == requestId }),
              pushed[item.id]?.pairingIds.contains(pairingId) == true else {
            if answer.choice == .viewing || answer.choice == .left {
                // Ignored for a request that already ended; the phone shows its outcome.
                return refuse(LinkRefusal.closed(recentlyResolved[requestId]?.outcome, macName: macName))
            }
            if let late = applyLate(answer, from: pairingId) { return late }
            if let recent = recentlyResolved[requestId] {
                return refuse(recent.pairingId == pairingId ? LinkRefusal.alreadyAnswered : LinkRefusal.closed(recent.outcome, macName: macName))
            }
            return refuse(LinkRefusal.closed(nil, macName: macName))
        }
        if answer.choice == .viewing || answer.choice == .left {
            return applyViewing(answer, item: item, coordinator: coordinator, from: pairingId)
        }
        if let deadline = item.deadline, deadline <= Date() {
            // The time ran out a moment ago and the timer has not fired yet: time the
            // request out now, so the answer can still go as a late answer.
            coordinator.expire(item)
            return applyLate(answer, from: pairingId) ?? refuse(LinkRefusal.tooLate(macName: macName, deadline: deadline))
        }
        if Date().timeIntervalSince(answer.answeredAt) > LinkRefusal.answerLifetime {
            return refuse(LinkRefusal.tooSlow)
        }
        let note = answer.note.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        switch (answer.choice, item.request.prompt) {
        case (.approve, .permission):
            guard !item.isHardDeny else { return refuse(LinkRefusal.macOnly) }
            if case .checking = item.risk { return refuse(LinkRefusal.riskChecking) }
            // A stale or forged notification action, or an app from before severity,
            // cannot skip the extra confirmation a high or critical request asks for.
            guard SeverityRules.acceptsPhoneApproval(confirmation: confirmation(for: item), confirmed: answer.confirmed) else {
                return refuse(LinkRefusal.needsConfirmation)
            }
            answeredBy[item.id] = pairingId
            coordinator.respond(item, StewResponse(status: .approved, note: note, risk: item.risk.assessment))
            return LinkResult(requestId: requestId, accepted: true, message: "Approved on \(macName).")
        case (.deny, .permission):
            answeredBy[item.id] = pairingId
            coordinator.respond(item, StewResponse(status: .denied, note: note, risk: item.risk.assessment))
            return LinkResult(requestId: requestId, accepted: true, message: "Denied on \(macName).")
        case (.moreTime, .permission), (.moreTime, .question), (.moreTime, .input), (.enterSoon, .input):
            if case .enterSoon = answer.choice, item.input?.secret != true { return refuse("This answer does not fit this request.") }
            guard item.timeLimit != nil else { return refuse(LinkRefusal.noTimeLimit) }
            guard coordinator.current?.id == item.id, item.deadline != nil || item.pausedRemaining != nil else {
                return refuse(LinkRefusal.clockNotStarted)
            }
            let isEnterSoon = answer.choice == .enterSoon
            coordinator.extendTime(by: isEnterSoon ? InputRequest.enterSoonSeconds : nil)
            let deadline = item.deadline ?? item.pausedRemaining.map { Date().addingTimeInterval($0) }
            return LinkResult(requestId: requestId, accepted: true, message: isEnterSoon ? "5 more minutes on \(macName)." : "More time on \(macName).", deadline: deadline)
        case (.text(let text), .input(let input)):
            // The Mac's own check decides: a reply that does not fit the pattern, or any
            // reply to a secret, is refused and the request stays open.
            if let refusal = LinkRefusal.inputRefusal(text, for: input) { return refuse(refusal) }
            guard case .valid(let answerText) = input.check(text) else { return refuse(LinkRefusal.emptyAnswer) }
            answeredBy[item.id] = pairingId
            coordinator.respond(item, StewResponse(status: .answered, text: answerText))
            return LinkResult(requestId: requestId, accepted: true, message: "Answered on \(macName).")
        case (.secret(let text), .input(let input)):
            // Exactly the panel's path for a secret: the same check, and the history and
            // the log never hold it. The refusal says what was expected, never what came.
            if let refusal = LinkRefusal.secretRefusal(text, for: input) { return refuse(refusal) }
            guard case .valid(let secret) = input.check(text) else { return refuse(LinkRefusal.emptyAnswer) }
            answeredBy[item.id] = pairingId
            coordinator.respond(item, StewResponse(status: .answered, text: secret))
            return LinkResult(requestId: requestId, accepted: true, message: "Entered on \(macName).")
        case (.enterLater, .input):
            answeredBy[item.id] = pairingId
            guard coordinator.enterLater(item) else {
                answeredBy[item.id] = nil
                return refuse("This request cannot wait for later.")
            }
            return LinkResult(requestId: requestId, accepted: true, message: "Waiting for you to enter it on \(macName).")
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

    /// A needs item takes Done, or one of its other answers by label, from a phone. "Not
    /// now" never leaves the phone.
    /// A paired phone by the name the history shows.
    private func phoneName(_ pairingId: String) -> String {
        paired.first { $0.pairingId == pairingId }?.phoneName ?? "iPhone"
    }

    private func applyNeeds(_ answer: LinkAnswer, needsID: String, from pairingId: String) -> LinkResult {
        let requestId = answer.requestId
        func refuse(_ message: String) -> LinkResult { LinkResult(requestId: requestId, accepted: false, message: message) }
        guard let coordinator, coordinator.needsStore.item(needsID) != nil, pushedNeeds[needsID]?.contains(pairingId) == true else {
            if let recent = recentlyResolved[requestId] {
                return refuse(recent.pairingId == pairingId ? LinkRefusal.alreadyAnswered : LinkRefusal.closed(recent.outcome, macName: macName))
            }
            return refuse(LinkRefusal.closed(nil, macName: macName))
        }
        if Date().timeIntervalSince(answer.answeredAt) > LinkRefusal.answerLifetime {
            return refuse(LinkRefusal.tooSlow)
        }
        let note = answer.note.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        switch answer.choice {
        case .done:
            needsDoneBy[needsID] = pairingId
            coordinator.answerNeeds(id: needsID, answerIndex: nil, note: note, answeredOn: phoneName(pairingId))
            return LinkResult(requestId: requestId, accepted: true, message: "Marked done on \(macName).")
        case .needsAnswer(let label):
            guard let record = coordinator.needsStore.item(needsID), let index = record.needs.answers.firstIndex(of: label) else {
                return refuse(LinkRefusal.unknownAnswer)
            }
            needsDoneBy[needsID] = pairingId
            guard coordinator.answerNeeds(id: needsID, answerIndex: index, note: note, answeredOn: phoneName(pairingId)) else {
                needsDoneBy[needsID] = nil
                return refuse(LinkRefusal.unknownAnswer)
            }
            return LinkResult(requestId: requestId, accepted: true, message: "Answered \u{201C}\(label)\u{201D} on \(macName).")
        default:
            return refuse("This answer does not fit this request.")
        }
    }

    private func needsFinished(_ record: NeedsItem, _ outcome: HistoryEntry.Outcome) {
        let doneBy = needsDoneBy.removeValue(forKey: record.id)
        guard let pairingIds = pushedNeeds.removeValue(forKey: record.id) else { return }
        let linkOutcome: LinkOutcome
        switch outcome {
        case .done: linkOutcome = .done
        case .answered: linkOutcome = .answered
        case .resolvedByClaude: linkOutcome = .resolvedByClaude
        case .answeredInSession: linkOutcome = .answeredInSession
        case .movedOn: linkOutcome = .movedOn
        default: linkOutcome = .dismissed
        }
        resolve(LinkPresentation.needsRequestId(record.id), pairingIds: pairingIds, outcome: linkOutcome, answering: doneBy)
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
            case .later: outcome = .later
            default: outcome = .answeredOnMac
            }
        }
        // A secret the user chose to enter later can come from the app too, like one
        // that timed out.
        if outcome == .timedOut || (outcome == .later && entry.sent.secretInApp == true) {
            lateAnswerable[item.id.uuidString] = (entry.pairingIds, item.isHardDeny, entry.sent.confirmation, Date())
        }
        resolve(item.id.uuidString, pairingIds: entry.pairingIds, outcome: outcome, answering: answering)
    }

    /// An answer from the phone to a request that timed out: it goes to the Claude session
    /// as a late answer, exactly like one from History's preview. Nil when the request is not
    /// one the phone may answer late, so the usual refusal applies.
    private func applyLate(_ answer: LinkAnswer, from pairingId: String) -> LinkResult? {
        let requestId = answer.requestId
        func refuse(_ message: String) -> LinkResult { LinkResult(requestId: requestId, accepted: false, message: message) }
        guard let coordinator, let sent = lateAnswerable[requestId], sent.pairingIds.contains(pairingId),
              let entryID = UUID(uuidString: requestId) else { return nil }
        guard let request = coordinator.lateRequest(entryID: entryID) else {
            // Answered late on the Mac already, or too old to answer.
            if LateAnswerFile.read().answer(entryID) != nil { return refuse(LinkRefusal.closed(.answeredOnMac, macName: macName)) }
            return nil
        }
        if Date().timeIntervalSince(answer.answeredAt) > LinkRefusal.answerLifetime {
            return refuse(LinkRefusal.tooSlow)
        }
        let note = answer.note.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let response: StewResponse
        switch (answer.choice, request.prompt) {
        case (.approve, .permission):
            guard !sent.hardDeny else { return refuse(LinkRefusal.macOnly) }
            guard SeverityRules.acceptsPhoneApproval(confirmation: sent.confirmation, confirmed: answer.confirmed) else {
                return refuse(LinkRefusal.needsConfirmation)
            }
            response = StewResponse(status: .approved, note: note)
        case (.deny, .permission):
            response = StewResponse(status: .denied, note: note)
        case (.answers(let answers), .question(let set)):
            guard let flow = QuestionFlow(set: set, linkAnswers: answers) else {
                return refuse("Answer every question, with one choice where only one is allowed.")
            }
            let annotations = flow.annotations()
            response = StewResponse(status: .answered, answers: flow.answers(), annotations: annotations.isEmpty ? nil : annotations)
        case (.text(let text), .input(let input)):
            // A secret is refused here too: it comes as `.secret`, never as a reply.
            if let refusal = LinkRefusal.inputRefusal(text, for: input) { return refuse(refusal) }
            guard case .valid(let answerText) = input.check(text) else { return refuse(LinkRefusal.emptyAnswer) }
            response = StewResponse(status: .answered, text: answerText)
        case (.secret(let text), .input(let input)):
            // Stored like a secret entered late on the Mac: a placeholder in the file, the
            // value in the daemon's memory until the session's next hook fetches it.
            if let refusal = LinkRefusal.secretRefusal(text, for: input) { return refuse(refusal) }
            guard case .valid(let secret) = input.check(text) else { return refuse(LinkRefusal.emptyAnswer) }
            response = StewResponse(status: .answered, text: secret)
        default:
            return refuse(LinkRefusal.closed(.timedOut, macName: macName))
        }
        guard coordinator.answerLate(entryID: entryID, with: response, answeredOn: phoneName(pairingId)) else {
            return refuse(LinkRefusal.closed(nil, macName: macName))
        }
        lateAnswerable[requestId] = nil
        recentlyResolved[requestId] = (.answered, pairingId, Date())
        return LinkResult(requestId: requestId, accepted: true, message: LinkRefusal.lateAnswerSent + ".", late: true)
    }

    private func resolve(_ requestId: String, pairingIds: Set<String>, outcome: LinkOutcome, answering: String?) {
        recentlyResolved[requestId] = (outcome, answering, Date())
        guard let store else { return }
        // Each phone's notification says which phone answered, and "this iPhone" on that one.
        let answeredOn = answering.flatMap { answeringId in paired.first { $0.pairingId == answeringId }?.phoneName ?? "iPhone" }
        for pairing in paired where pairingIds.contains(pairing.pairingId) {
            let resolved = LinkResolved(
                requestId: requestId,
                outcome: outcome,
                answeredOn: answeredOn,
                answeredHere: answering == nil ? nil : answering == pairing.pairingId
            )
            guard let channel = try? pairing.channel(identity: store.identity),
                  let envelope = try? channel.seal(resolved, kind: .resolved, requestId: requestId, expiresAt: Date().addingTimeInterval(Self.recentLifetime)) else { continue }
            connections[pairing.pairingId]?.send(envelope)
        }
    }

    /// "Viewing" pauses the request's clock while it is open on the phone; "left" lets it
    /// run again after the grace period. The new deadline reaches every phone through the
    /// usual update, as after More time.
    private func applyViewing(_ answer: LinkAnswer, item: Item, coordinator: Coordinator, from pairingId: String) -> LinkResult {
        let requestId = answer.requestId
        guard item.timeLimit != nil else { return LinkResult(requestId: requestId, accepted: false, message: LinkRefusal.noTimeLimit) }
        if let deadline = item.deadline, deadline <= Date() {
            return LinkResult(requestId: requestId, accepted: false, message: LinkRefusal.tooLate(macName: macName, deadline: deadline))
        }
        if Date().timeIntervalSince(answer.answeredAt) > LinkRefusal.answerLifetime {
            return LinkResult(requestId: requestId, accepted: false, message: LinkRefusal.tooSlow)
        }
        let phoneName = paired.first { $0.pairingId == pairingId }?.phoneName ?? answer.phoneName
        if answer.choice == .viewing {
            guard coordinator.startViewing(item, phoneName: phoneName, pairingId: pairingId) else {
                return LinkResult(requestId: requestId, accepted: false, message: LinkRefusal.viewingCapReached)
            }
            let ends = item.viewing?.endsAt(cap: coordinator.config.phone.viewingCap, grace: Coordinator.viewingGrace)
            return LinkResult(requestId: requestId, accepted: true, message: LinkPresentation.viewingPaused, deadline: ends)
        }
        coordinator.stopViewing(item, pairingId: pairingId)
        let deadline = item.deadline ?? item.pausedRemaining.map { Date().addingTimeInterval($0) }
        return LinkResult(requestId: requestId, accepted: true, message: "", deadline: deadline)
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
            request: Self.withoutOrigin(item.request),
            receivedAt: item.received,
            deadline: deadline,
            queued: queued,
            extendBy: item.timeLimit == nil ? nil : coordinator?.config.extendBy,
            hardDeny: item.isHardDeny,
            risk: item.risk.assessment,
            confirmation: confirmation(for: item),
            viewingOn: coordinator.flatMap { $0.isViewing(item) ? item.viewing?.phoneName : nil },
            secretInApp: item.input?.secret == true ? true : nil
        )
    }

    /// The extra step the phone must ask for before it approves, from the risk check's
    /// severity and the setting in force now.
    private func confirmation(for item: Item) -> PhoneConfirmation? {
        guard let coordinator else { return nil }
        return SeverityRules.phoneConfirmation(item.risk.assessment?.severity, config: coordinator.config.classifier)
    }

    /// The origin holds the raw tool input of a blocked call, which only the Mac needs.
    private static func withoutOrigin(_ request: StewRequest) -> StewRequest {
        var stripped = request
        stripped.origin = nil
        return stripped
    }

    private static func needsUpdate(_ old: LinkRequest, _ new: LinkRequest) -> Bool {
        if old.queued != new.queued || old.hardDeny != new.hardDeny || old.risk != new.risk || old.confirmation != new.confirmation || old.viewingOn != new.viewingOn { return true }
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
        send(request, kind: kind, expiresAt: expiry(for: request, item: item), to: pairingIds)
    }

    private func send(_ request: LinkRequest, kind: LinkKind, expiresAt: Date, to pairingIds: Set<String>) {
        guard let store else { return }
        for pairing in paired where pairingIds.contains(pairing.pairingId) {
            guard let channel = try? pairing.channel(identity: store.identity),
                  let envelope = try? channel.seal(request, kind: kind, requestId: request.requestId, expiresAt: expiresAt) else { continue }
            connections[pairing.pairingId]?.send(envelope)
        }
    }

    private func tick() {
        guard let coordinator else { return }
        let now = Date()
        if let code = pairingCode, let waiting = pairings.first(where: { $0.pairingId == code.pairingId && $0.state == .waiting }),
           now.timeIntervalSince(waiting.createdAt) > Self.codeLifetime {
            cancelPairing()
            pairingError = "The pairing code expired after 10 minutes. Pair again for a new one."
        }
        recentlyResolved = recentlyResolved.filter { now.timeIntervalSince($0.value.at) < Self.recentLifetime }
        lateAnswerable = lateAnswerable.filter { now.timeIntervalSince($0.value.at) < LateMailbox.lifetime }
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
            // The phone should see the risk verdict, and a hard deny must never be offered
            // as approvable, so a request waits while its check runs.
            if case .checking = item.risk { continue }
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
            guard PushPolicy.shouldPush(
                source: item.source, config: coordinator.config.phone, openFor: now.timeIntervalSince(item.received), presence: current,
                typedOnMac: item.typedOnMac
            ) else { continue }
            let request = linkRequest(for: item, previous: nil)
            send(request, kind: .request, item: item, to: targets)
            pushed[item.id] = Pushed(pairingIds: targets, sent: request)
        }
        pushNeeds(coordinator: coordinator, targets: targets, now: now, presence: &presence)
    }

    /// Needs items go out under the same policy as requests. One the user parked with
    /// "Not now" on the Mac stays parked: they have seen it and chose to wait. A needs
    /// item has no deadline, so the relay keeps it close to its longest.
    private func pushNeeds(coordinator: Coordinator, targets: Set<String>, now: Date, presence: inout MacPresence?) {
        let open = coordinator.needsStore.items
        let openIDs = Set(open.map(\.id))
        for (needsID, pairingIds) in pushedNeeds where !openIDs.contains(needsID) {
            // Replaced by a newer automatic item from the same session without an ending.
            pushedNeeds[needsID] = nil
            resolve(LinkPresentation.needsRequestId(needsID), pairingIds: pairingIds, outcome: .movedOn, answering: nil)
        }
        for record in open where !record.parked && pushedNeeds[record.id] == nil {
            guard PushPolicy.shouldPushNeeds(config: coordinator.config.phone, openFor: now.timeIntervalSince(record.created)) else { continue }
            let request = LinkRequest(
                requestId: LinkPresentation.needsRequestId(record.id),
                macName: macName,
                request: StewRequest(session: record.session, prompt: .needs(record.needs), wait: false),
                receivedAt: record.created,
                deadline: nil,
                queued: false,
                extendBy: nil,
                hardDeny: false,
                risk: nil
            )
            send(request, kind: .request, expiresAt: now.addingTimeInterval(6 * 24 * 3600), to: targets)
            pushedNeeds[record.id] = targets
        }
    }

    /// The Mac's presence. The headless test daemon can set STEW_PHONE_PRESENCE instead.
    static func samplePresence() -> MacPresence {
        if Paths.headless, let forced = ProcessInfo.processInfo.environment["STEW_PHONE_PRESENCE"] {
            return forced == "away" ? MacPresence(idleSeconds: .infinity, screenLocked: true) : MacPresence(idleSeconds: 0, screenLocked: false)
        }
        return MacPresence.sampled()
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
            return confirm(pairing.pairingId, digits: words.dropFirst(2).joined()) ? "confirmed" : "wrong digits"
        case "unpair":
            for pairing in pairings { unpair(pairing.pairingId) }
            return "unpaired"
        case "state":
            let connected = statuses.values.filter { $0 == .connected }.count
            return "pairings=\(pairings.count) paired=\(paired.count) confirming=\(confirming == nil ? 0 : 1) connected=\(connected) pushed=\(pushed.count) needs=\(pushedNeeds.count)"
        default:
            return "unknown phone control"
        }
    }
}

extension MacPresence {
    /// Idle time from the last keyboard, mouse or trackpad event, and the lock state of
    /// the login session. Reading the idle time needs no Accessibility permission.
    static func sampled() -> MacPresence {
        let anyInput = CGEventType(rawValue: ~0) ?? .null
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = (session?["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
        return MacPresence(idleSeconds: idle, screenLocked: locked)
    }
}
