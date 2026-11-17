import Foundation
import StewLink

/// Which relay protocol each relay address speaks, from GET /v2/info, kept for the life of
/// the process. A relay that answered v2 is never asked again, so nothing on the network can
/// talk this Mac back down to v1; one without v2 is asked again after a while, since it may
/// have been upgraded. Main queue only.
final class RelayVersions {
    static let shared = RelayVersions()
    static let recheckWithoutV2After: TimeInterval = 600

    private var known: [String: (probe: RelayProbe, at: Date)] = [:]
    private var waiting: [String: [(RelayProbe) -> Void]] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()

    func resolve(relay: String, completion: @escaping (RelayProbe) -> Void) {
        if let entry = known[relay] {
            switch entry.probe {
            case .v2:
                completion(entry.probe)
                return
            case .v1, .unsupported:
                if Date().timeIntervalSince(entry.at) < Self.recheckWithoutV2After {
                    completion(entry.probe)
                    return
                }
            case .unknown:
                break
            }
        }
        if waiting[relay] != nil {
            waiting[relay]?.append(completion)
            return
        }
        waiting[relay] = [completion]
        guard let url = URL(string: relay + RelayProtocol.infoPath) else {
            finish(relay, .unknown)
            return
        }
        session.dataTask(with: url) { data, response, _ in
            let probe = RelayProbe.decide(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data ?? Data())
            DispatchQueue.main.async { self.finish(relay, probe) }
        }.resume()
    }

    private func finish(_ relay: String, _ probe: RelayProbe) {
        if probe != .unknown, !(known[relay]?.probe.version == .v2 && probe.version != .v2) {
            known[relay] = (probe, Date())
        }
        let completions = waiting.removeValue(forKey: relay) ?? []
        let answer = known[relay]?.probe ?? probe
        for completion in completions { completion(answer) }
    }
}

/// One pairing's link to its relay: an outbound WebSocket that receives the phone's
/// answers, and HTTP posts for everything the Mac sends. It speaks relay protocol v2, or v1
/// with a relay from before v2. The socket reconnects as the close code says (the table in
/// the relay's wire protocol), so a relay restart or a sleeping Mac heals by itself, and an
/// ended pairing stops for good.
final class RelayConnection: NSObject, URLSessionWebSocketDelegate {
    enum Status: Equatable {
        case connecting, connected, failed(String)
        /// The relay refused this Mac's signature three times in a row; stew keeps trying.
        case refused
        /// The link stopped for good.
        case stopped(RelayStop)
    }

    /// What the owner did with a frame. `finished` stops the connection once the ack is out.
    enum FrameHandling {
        case handled, finished
    }

    let pairingId: String
    let relay: String
    private let identity: LinkIdentity
    private var session: URLSession!
    private var socket: URLSessionWebSocketTask?
    private var backoff: TimeInterval = 1
    private var stopped = false
    private var pingTimer: Timer?
    private var heartbeat = RelayHeartbeat()
    private var heartbeatInterval = RelayHeartbeat.interval
    private var sequence = RelaySequence()
    private var authFailures = 0
    private(set) var version: RelayVersion?
    /// What the relay's /v2/info said, once known; nil for a v1 relay.
    private(set) var info: RelayInfo?
    /// Called on the main queue with each new frame from the relay.
    var onFrame: ((RelayFrame) -> FrameHandling)?
    /// Called on the main queue whenever the socket's status changes.
    var onStatus: ((Status) -> Void)?
    /// Called on the main queue when the relay ended the link for good.
    var onStop: ((RelayStop) -> Void)?
    private(set) var status: Status = .connecting
    private var lastBadFrameLog = Date.distantPast

    static let longestBackoff: TimeInterval = 60
    /// Sends of envelopes the relay itself did not answer (no response, or a proxy's page)
    /// get this many more tries, with the same envelope: a v2 relay answers a repeat with
    /// the first outcome.
    static let sendRetries = 2

    init(pairingId: String, relay: String, identity: LinkIdentity) {
        self.pairingId = pairingId
        self.relay = relay.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.identity = identity
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }

    /// Learns which protocol the relay speaks, once per relay and process.
    func resolveVersion(_ completion: @escaping (RelayProbe) -> Void) {
        RelayVersions.shared.resolve(relay: relay) { [weak self] probe in
            if let self, let version = probe.version {
                self.version = version
                if case .v2(let info) = probe {
                    self.info = info
                    if let seconds = info.heartbeatSeconds, seconds > 0 { self.heartbeatInterval = seconds }
                }
            }
            completion(probe)
        }
    }

    func connect() {
        guard !stopped else { return }
        setStatus(.connecting)
        resolveVersion { [weak self] probe in
            guard let self, !self.stopped else { return }
            switch probe {
            case .v1, .v2: self.openSocket()
            case .unsupported: self.end(.unsupportedProtocol)
            case .unknown: self.reconnect(after: "cannot reach the relay", plan: .backoff)
            }
        }
    }

    /// Closes the socket and stops reconnecting. Posts already on the way still finish.
    func stop() {
        guard !stopped else { return }
        stopped = true
        pingTimer?.invalidate()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session.finishTasksAndInvalidate()
    }

    private func end(_ reason: RelayStop) {
        stop()
        setStatus(.stopped(reason))
        onStop?(reason)
    }

    private func openSocket() {
        guard let version, let request = socketRequest(version) else {
            setStatus(.failed("bad relay address"))
            return
        }
        let task = session.webSocketTask(with: request)
        socket = task
        sequence = RelaySequence()
        heartbeat = RelayHeartbeat()
        task.resume()
        receive(on: task)
    }

    private func socketRequest(_ version: RelayVersion) -> URLRequest? {
        guard var components = URL(string: relay + version.pairingPath(pairingId, "socket"))
            .flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { return nil }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        switch version {
        case .v1:
            guard let query = try? RelayAuth.query(signing: { RelayAuth.socketMessage(pairingId: self.pairingId, timestamp: $0) }, identity: identity) else {
                return nil
            }
            components.percentEncodedQuery = query
            return components.url.map { URLRequest(url: $0) }
        case .v2:
            guard let socketURL = components.url,
                  let header = try? RelayAuth.header(method: "GET", path: components.percentEncodedPath, side: .mac, body: nil, identity: identity) else {
                return nil
            }
            var request = URLRequest(url: socketURL)
            request.setValue(header, forHTTPHeaderField: "authorization")
            request.setValue(RelayProtocol.subprotocol, forHTTPHeaderField: "sec-websocket-protocol")
            request.setValue("2", forHTTPHeaderField: RelayProtocol.versionHeader)
            return request
        }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, task === self.socket else { return }
                switch result {
                case .success(let message):
                    self.handle(message)
                    self.receive(on: task)
                case .failure(let error):
                    self.ended(task, fallback: error.localizedDescription)
                }
            }
        }
    }

    /// The socket is gone: by a close code, a refused upgrade, or a network error.
    private func ended(_ task: URLSessionWebSocketTask, fallback: String) {
        if task.closeCode != .invalid {
            let reason = task.closeReason.map { String(decoding: $0, as: UTF8.self) }
            reconnect(after: "closed (\(task.closeCode.rawValue))", plan: .afterClose(code: task.closeCode.rawValue, reason: reason))
        } else if let response = task.response as? HTTPURLResponse, response.statusCode != 101 {
            reconnect(
                after: "refused (\(response.statusCode))",
                plan: .afterRefusal(status: response.statusCode, retryAfter: response.value(forHTTPHeaderField: "retry-after"))
            )
        } else {
            reconnect(after: fallback, plan: .backoff)
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: return
        }
        let incoming: RelayIncoming
        do {
            incoming = try RelayIncoming.decode(data)
        } catch {
            // Acked all the same, so the relay does not send it again on every connect.
            if let seq = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["seq"] as? Int, sequence.isNew(seq) {
                sendAck(RelayAck.cumulative(pairingId: pairingId, seq: seq))
            }
            // At most one line a minute, so a misbehaving relay cannot fill the log.
            guard Date().timeIntervalSince(lastBadFrameLog) > 60 else { return }
            lastBadFrameLog = Date()
            Log.write("phone: unreadable frame from relay: \(error)")
            return
        }
        switch incoming {
        case .pong:
            heartbeat.pongReceived()
        case .ready:
            break
        case .frame(let frame):
            if let framePairing = frame.pairingId, framePairing != pairingId { return }
            guard sequence.isNew(frame.seq) else {
                acknowledge(frame)
                return
            }
            let handling = onFrame?(frame) ?? .handled
            acknowledge(frame) { [weak self] in
                if handling == .finished { self?.stop() }
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard webSocketTask === socket else { return }
        if version == .v2, `protocol` != RelayProtocol.subprotocol {
            Log.write("phone: the relay did not select \(RelayProtocol.subprotocol) for pairing \(pairingId)")
        }
        backoff = 1
        authFailures = 0
        setStatus(.connected)
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in self?.sendPing() }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === socket else { return }
        reconnect(
            after: "closed (\(closeCode.rawValue))",
            plan: .afterClose(code: closeCode.rawValue, reason: reason.map { String(decoding: $0, as: UTF8.self) })
        )
    }

    /// A ping every heartbeat interval; a socket that does not answer one within the pong
    /// timeout is dead even if the system has not noticed yet.
    private func sendPing() {
        guard let task = socket else { return }
        if heartbeat.isOverdue(now: Date()) {
            dropDeadSocket(task)
            return
        }
        heartbeat.pingSent(at: Date())
        task.send(.string("ping")) { _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + RelayHeartbeat.pongTimeout) { [weak self] in
            guard let self, task === self.socket, self.heartbeat.isOverdue(now: Date()) else { return }
            self.dropDeadSocket(task)
        }
    }

    private func dropDeadSocket(_ task: URLSessionWebSocketTask) {
        task.cancel(with: .goingAway, reason: nil)
        reconnect(after: "no answer to ping", plan: .backoff)
    }

    private func reconnect(after reason: String, plan: RelayReconnect) {
        pingTimer?.invalidate()
        socket = nil
        guard !stopped else { return }
        // Jitter keeps several Macs from reconnecting in step after a relay restart.
        let jitter = Double.random(in: 0.8...1.2)
        let delay: TimeInterval
        switch plan {
        case .backoff:
            delay = backoff * jitter
            backoff = min(backoff * 2, Self.longestBackoff)
            setStatus(.failed(reason))
        case .soon:
            delay = Double.random(in: 0.5...3)
            setStatus(.failed(reason))
        case .now:
            delay = 0
            setStatus(.connecting)
        case .after(let seconds):
            delay = seconds * jitter
            setStatus(.failed(reason))
        case .authFailed:
            authFailures += 1
            delay = backoff * jitter
            backoff = min(backoff * 2, Self.longestBackoff)
            setStatus(authFailures >= 3 ? .refused : .failed(reason))
        case .stop(let reason):
            end(reason)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.connect() }
    }

    private func setStatus(_ status: Status) {
        guard status != self.status else { return }
        self.status = status
        onStatus?(status)
    }

    /// Tells the relay a frame was handled, whatever the outcome, since sending it again
    /// would change nothing. v2 acks everything up to the frame's seq; v1 acks the one
    /// envelope, which a v1 relay needs only for hello and unpair and ignores otherwise.
    private func acknowledge(_ frame: RelayFrame, completion: (() -> Void)? = nil) {
        if version == .v2, let seq = frame.seq {
            sendAck(RelayAck.cumulative(pairingId: pairingId, seq: seq), completion: completion)
        } else {
            sendAck(RelayAck.message(frame.envelope.messageId), completion: completion)
        }
    }

    private func sendAck(_ text: String, completion: (() -> Void)? = nil) {
        guard let socket else {
            completion?()
            return
        }
        socket.send(.string(text)) { _ in
            DispatchQueue.main.async { completion?() }
        }
    }

    struct PostResult {
        let status: Int
        let body: Data
        /// v2: the relay had this envelope already and answered with its first outcome.
        var duplicate = false
        var ok: Bool { (200..<300).contains(status) }
        var text: String { String(decoding: body, as: UTF8.self) }
        /// The relay's error code; act on this, not on the status.
        var errorCode: String? { RelayErrorCode.read(body) }
        /// The relay refused for want of a plan.
        var planRequired: RelayPlanRequired? { RelayPlanRequired.read(body) }
        /// No response, or a proxy's page in place of the relay's: the post may or may not
        /// have reached the relay.
        var noRelayReply: Bool { RelayErrorCode.noRelayReply(status: status, body: body) }
    }

    /// Posts JSON to a pairing call and calls back on the main queue. The body may differ by
    /// version, so it is made once the version is known. `signed` adds the v2 auth header.
    /// Status 0 means the relay was unreachable; 426 that it speaks no version stew knows.
    func post(_ action: String, signed: Bool, body makeBody: @escaping (RelayVersion) -> Data?, completion: ((PostResult) -> Void)? = nil) {
        call("POST", action, signed: signed, body: makeBody, completion: completion)
    }

    /// Sends JSON to a pairing call with any method; otherwise exactly as `post`.
    func call(_ method: String, _ action: String, signed: Bool, body makeBody: @escaping (RelayVersion) -> Data?, completion: ((PostResult) -> Void)? = nil) {
        resolveVersion { [weak self] probe in
            guard let self else { return }
            guard !self.stopped else {
                completion?(PostResult(status: 0, body: Data("the link to the relay was stopped".utf8)))
                return
            }
            guard let version = probe.version else {
                completion?(PostResult(status: probe == .unsupported ? 426 : 0, body: Data("no relay protocol in common".utf8)))
                return
            }
            guard let target = URL(string: self.relay + version.pairingPath(self.pairingId, action)), let body = makeBody(version) else { return }
            var request = URLRequest(url: target)
            request.httpMethod = method
            request.httpBody = body
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            if version == .v2 {
                request.setValue("2", forHTTPHeaderField: RelayProtocol.versionHeader)
                let path = URLComponents(url: target, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? target.path
                if signed, let header = try? RelayAuth.header(method: method, path: path, side: .mac, body: body, identity: self.identity) {
                    request.setValue(header, forHTTPHeaderField: "authorization")
                }
            }
            self.session.dataTask(with: request) { data, response, error in
                let http = response as? HTTPURLResponse
                let body = data ?? Data(error.map { $0.localizedDescription }?.utf8 ?? "".utf8)
                let result = PostResult(status: http?.statusCode ?? 0, body: body, duplicate: http?.value(forHTTPHeaderField: RelayProtocol.duplicateHeader) == "1")
                DispatchQueue.main.async { completion?(result) }
            }.resume()
        }
    }

    func send(_ envelope: LinkEnvelope, completion: ((PostResult) -> Void)? = nil) {
        send(envelope, retriesLeft: Self.sendRetries, completion: completion)
    }

    private func send(_ envelope: LinkEnvelope, retriesLeft: Int, completion: ((PostResult) -> Void)?) {
        guard let body = try? LinkJSON.encode(envelope) else { return }
        post("messages", signed: false, body: { _ in body }) { [weak self] result in
            // Only v2 answers a repeat with the first outcome; v1 would refuse it as a replay.
            if result.noRelayReply, retriesLeft > 0, let self, self.version == .v2, !self.stopped {
                let wait = TimeInterval(2 * (Self.sendRetries - retriesLeft + 1))
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                    guard let self, !self.stopped else {
                        completion?(result)
                        return
                    }
                    self.send(envelope, retriesLeft: retriesLeft - 1, completion: completion)
                }
                return
            }
            if !result.ok {
                Log.write("phone: relay refused \(envelope.kind.rawValue) for \(envelope.requestId): \(result.status) \(result.text)")
            }
            // Only the user can change the plan, so the link stops until they do.
            if let self, !self.stopped, let plan = result.planRequired {
                self.end(.planRequired(plan))
            }
            completion?(result)
        }
    }
}
