import AppKit
import Darwin
import Foundation
import StewCore

/// One client connection. Lives on the socket queue; `send` may be called from anywhere.
final class Connection {
    let id = UUID()
    private let fd: Int32
    private let queue: DispatchQueue
    private var buffer = Data()
    private var source: DispatchSourceRead?
    private var closed = false
    var onLine: ((Connection, Data) -> Void)?
    var onClose: ((Connection) -> Void)?

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [fd] in close(fd) }
        self.source = source
        source.resume()
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        let count = read(fd, &chunk, chunk.count)
        guard count > 0 else {
            // EOF: the caller gave up (Ctrl-C, Bash tool timeout). Its request goes away.
            finish()
            return
        }
        buffer.append(contentsOf: chunk[0..<count])
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { onLine?(self, Data(line)) }
        }
    }

    func send(_ data: Data) {
        queue.async { [self] in
            guard !closed else { return }
            try? Client.writeAll(fd, data)
            finish()
        }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        source?.cancel()
        onClose?(self)
    }
}

final class SocketServer {
    private let path: String
    private let queue = DispatchQueue(label: "stew.socket")
    private var listenSource: DispatchSourceRead?
    private var connections: [UUID: Connection] = [:]
    var onLine: ((Connection, Data) -> Void)?
    var onClose: ((Connection) -> Void)?

    init(path: String) {
        self.path = path
    }

    func start() throws {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            pathBytes.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            throw Client.ClientError(description: "cannot listen on \(path): \(String(cString: strerror(errno)))")
        }
        chmod(path, 0o600)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept(on: fd) }
        listenSource = source
        source.resume()
    }

    private func accept(on listenFD: Int32) {
        let clientFD = Darwin.accept(listenFD, nil, nil)
        guard clientFD >= 0 else { return }
        var noSigPipe: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let connection = Connection(fd: clientFD, queue: queue)
        connection.onLine = { [weak self] connection, line in self?.onLine?(connection, line) }
        connection.onClose = { [weak self] connection in
            self?.connections[connection.id] = nil
            self?.onClose?(connection)
        }
        connections[connection.id] = connection
        connection.start()
    }

    func stop() {
        listenSource?.cancel()
        unlink(path)
    }
}

enum Daemon {
    static func run() -> Never {
        // One daemon per socket. The lock dies with the process, so a crash never wedges it.
        let lockFD = open(Paths.lock, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            Log.write("another daemon holds \(Paths.lock); exiting")
            exit(0)
        }
        signal(SIGPIPE, SIG_IGN)

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let coordinator = Coordinator()
        if !Paths.headless {
            let panel = PanelController(coordinator: coordinator)
            coordinator.onChange = { panel.update() }
        }

        let server = SocketServer(path: Paths.socket)
        server.onLine = { connection, line in
            DispatchQueue.main.async { coordinator.receive(line: line, from: connection) }
        }
        server.onClose = { connection in
            DispatchQueue.main.async { coordinator.connectionClosed(connection.id) }
        }
        coordinator.onStop = {
            server.stop()
            exit(0)
        }
        do {
            try server.start()
        } catch {
            Log.write("\(error)")
            exit(1)
        }
        for terminating in [SIGTERM, SIGINT] {
            signal(terminating, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: terminating, queue: .main)
            source.setEventHandler {
                coordinator.dismissAllForShutdown()
                server.stop()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
        RiskChecker.mainLoopRunning = true
        Log.write("stew daemon listening on \(Paths.socket)")
        application.run()
        exit(0)
    }

    private static var signalSources: [DispatchSourceSignal] = []
}
