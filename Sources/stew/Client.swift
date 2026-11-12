import Darwin
import Foundation
import StewCore

/// The command line side: builds a request, hands it to the daemon, prints the answer.
enum Client {
    static func send(_ request: StewRequest) -> StewResponse {
        do {
            let fd = try connectStartingDaemon()
            defer { close(fd) }
            try writeAll(fd, try Wire.encode(request))
            guard let line = readLine(fd) else {
                return StewResponse(status: .error, error: "daemon closed the connection without an answer")
            }
            return try Wire.decode(StewResponse.self, line: line)
        } catch {
            return StewResponse(status: .error, error: "\(error)")
        }
    }

    static func sendControl(_ control: String) -> String? {
        guard let fd = try? connect(path: Paths.socket) else { return nil }
        defer { close(fd) }
        guard (try? writeAll(fd, try Wire.encode(ControlMessage(control: control)))) != nil,
              let line = readLine(fd) else { return nil }
        return String(decoding: line, as: UTF8.self)
    }

    struct ClientError: Error, CustomStringConvertible {
        let description: String
    }

    static func connect(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError(description: "socket: \(String(cString: strerror(errno)))") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw ClientError(description: "socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            pathBytes.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw ClientError(description: "connect \(path): \(message)")
        }
        return fd
    }

    /// Connects, and starts the daemon first when nothing listens yet.
    static func connectStartingDaemon() throws -> Int32 {
        if let fd = try? connect(path: Paths.socket) { return fd }
        startDaemon()
        let deadline = Date().addingTimeInterval(8)
        var lastError: Error = ClientError(description: "daemon did not start")
        while Date() < deadline {
            do { return try connect(path: Paths.socket) } catch { lastError = error }
            usleep(100_000)
        }
        throw ClientError(description: "\(lastError). Check \(Paths.log)")
    }

    /// Prefers the LaunchAgent so the daemon lives outside the caller's process tree.
    static func startDaemon() {
        let isDefaultSocket = ProcessInfo.processInfo.environment["STEW_SOCKET"] == nil
        if isDefaultSocket, FileManager.default.fileExists(atPath: Paths.launchAgent) {
            let domain = "gui/\(getuid())"
            if run("/bin/launchctl", ["kickstart", "\(domain)/\(Paths.launchAgentLabel)"]) != 0 {
                _ = run("/bin/launchctl", ["bootstrap", domain, Paths.launchAgent])
            }
            return
        }
        spawnDetached(Paths.executable, ["daemon"])
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// New session, output to the log, so the caller's shell can exit without waiting on it.
    static func spawnDetached(_ path: String, _ arguments: [String]) {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, Paths.log, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        var pid: pid_t = 0
        posix_spawn(&pid, path, &actions, &attributes, argv, environ)
        argv.forEach { free($0) }
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw ClientError(description: "write: \(String(cString: strerror(errno)))")
                }
                offset += written
            }
        }
    }

    static func readLine(_ fd: Int32) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return buffer.isEmpty ? nil : buffer }
            buffer.append(contentsOf: chunk[0..<count])
            if let newline = buffer.firstIndex(of: 0x0A) {
                return buffer[..<newline]
            }
        }
    }
}
