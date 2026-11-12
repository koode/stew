import Foundation
import StewLink

/// One pairing's link to its relay: an outbound WebSocket that receives the phone's
/// answers, and HTTP posts for everything the Mac sends. The socket reconnects with
/// exponential backoff, so a relay restart or a sleeping Mac heals by itself.
final class RelayConnection: NSObject, URLSessionWebSocketDelegate {
    enum Status: Equatable {
        case connecting, connected, failed(String)
    }

    let pairingId: String
    let relay: String
    private let identity: LinkIdentity
    private var session: URLSession!
    private var socket: URLSessionWebSocketTask?
    private var backoff: TimeInterval = 1
    private var stopped = false
    private var pingTimer: Timer?
    /// Called on the main queue with each frame from the relay.
    var onFrame: ((RelayFrame) -> Void)?
    /// Called on the main queue whenever the socket's status changes.
    var onStatus: ((Status) -> Void)?
    private(set) var status: Status = .connecting
    private var lastBadFrameLog = Date.distantPast

    static let longestBackoff: TimeInterval = 60
    static let pingInterval: TimeInterval = 30

    init(pairingId: String, relay: String, identity: LinkIdentity) {
        self.pairingId = pairingId
        self.relay = relay.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.identity = identity
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }

    private func url(_ path: String) -> URL? {
        URL(string: relay + "/v1/pairings/\(pairingId)/\(path)")
    }

    func connect() {
        guard !stopped else { return }
        setStatus(.connecting)
        guard let query = try? RelayAuth.query(signing: { RelayAuth.socketMessage(pairingId: self.pairingId, timestamp: $0) }, identity: identity),
              var components = url("socket").flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            setStatus(.failed("bad relay address"))
            return
        }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.percentEncodedQuery = query
        guard let socketURL = components.url else { return }
        let task = session.webSocketTask(with: socketURL)
        socket = task
        task.resume()
        receive(on: task)
    }

    func stop() {
        stopped = true
        pingTimer?.invalidate()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session.invalidateAndCancel()
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
                    self.reconnect(after: "\(error.localizedDescription)")
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: return
        }
        if data == Data("pong".utf8) { return }
        do {
            onFrame?(try LinkJSON.decode(RelayFrame.self, from: data))
        } catch {
            // At most one line a minute, so a misbehaving relay cannot fill the log.
            guard Date().timeIntervalSince(lastBadFrameLog) > 60 else { return }
            lastBadFrameLog = Date()
            Log.write("phone: unreadable frame from relay: \(error)")
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard webSocketTask === socket else { return }
        backoff = 1
        setStatus(.connected)
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: Self.pingInterval, repeats: true) { [weak self] _ in
            self?.socket?.send(.string("ping")) { _ in }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === socket else { return }
        reconnect(after: "closed (\(closeCode.rawValue))")
    }

    private func reconnect(after reason: String) {
        pingTimer?.invalidate()
        socket = nil
        guard !stopped else { return }
        setStatus(.failed(reason))
        // Jitter keeps several Macs from reconnecting in step after a relay restart.
        let delay = backoff * Double.random(in: 0.8...1.2)
        backoff = min(backoff * 2, Self.longestBackoff)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.connect() }
    }

    private func setStatus(_ status: Status) {
        guard status != self.status else { return }
        self.status = status
        onStatus?(status)
    }

    struct PostResult {
        let status: Int
        let body: Data
        var ok: Bool { (200..<300).contains(status) }
        var text: String { String(decoding: body, as: UTF8.self) }
    }

    /// Posts JSON and calls back on the main queue. Status 0 means the relay was unreachable.
    func post(_ path: String, body: Data, completion: ((PostResult) -> Void)? = nil) {
        guard let target = url(path) else { return }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        session.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = data ?? Data(error.map { $0.localizedDescription }?.utf8 ?? "".utf8)
            DispatchQueue.main.async { completion?(PostResult(status: status, body: body)) }
        }.resume()
    }

    func send(_ envelope: LinkEnvelope, completion: ((PostResult) -> Void)? = nil) {
        guard let body = try? LinkJSON.encode(envelope) else { return }
        post("messages", body: body) { result in
            if !result.ok {
                Log.write("phone: relay refused \(envelope.kind.rawValue) for \(envelope.requestId): \(result.status) \(result.text)")
            }
            completion?(result)
        }
    }
}
