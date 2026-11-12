import Foundation

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let launchAgentLabel = "nl.koode.stew"

    static var supportDirectory: String {
        let path = home + "/Library/Application Support/stew"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    static var cacheDirectory: String {
        let path = home + "/Library/Caches/stew"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// STEW_SOCKET lets tests run a second daemon beside the real one.
    static var socket: String {
        ProcessInfo.processInfo.environment["STEW_SOCKET"] ?? supportDirectory + "/stew.sock"
    }

    static var lock: String { socket + ".lock" }
    static var config: String { ProcessInfo.processInfo.environment["STEW_CONFIG"] ?? home + "/.config/stew/config.json" }

    /// Test mode: no panel, no hotkeys, and the socket accepts simulated key presses.
    /// Never on for the real daemon, or a caller could approve its own request.
    static var headless: Bool { ProcessInfo.processInfo.environment["STEW_HEADLESS"] == "1" }
    static var log: String { home + "/Library/Logs/stew.log" }
    static var launchAgent: String { home + "/Library/LaunchAgents/\(launchAgentLabel).plist" }

    static var executable: String {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        _NSGetExecutablePath(&buffer, &size)
        let path = String(cString: buffer)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// `claude` from config, then the usual install places, then PATH.
    static func claudeBinary(configured: String?) -> String? {
        let fileManager = FileManager.default
        if let configured, fileManager.isExecutableFile(atPath: configured) { return configured }
        let candidates = [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        if let found = candidates.first(where: fileManager.isExecutableFile(atPath:)) { return found }
        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        return pathEntries.map { "\($0)/claude" }.first(where: fileManager.isExecutableFile(atPath:))
    }
}

enum Log {
    static func write(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
    }
}
