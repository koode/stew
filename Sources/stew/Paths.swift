import Foundation
import StewCore

enum Paths {
    /// HOME first, like other command line tools, so the installer tests can point stew
    /// at a temporary home folder.
    static let home: String = {
        if let home = ProcessInfo.processInfo.environment["HOME"], home.hasPrefix("/") { return home }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }()
    static let launchAgentLabel = "nl.koode.stew"

    static var supportDirectory: String {
        let path = home + "/Library/Application Support/stew"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// STEW_CACHE keeps test runs out of the real cache.
    static var cacheDirectory: String {
        let path = ProcessInfo.processInfo.environment["STEW_CACHE"] ?? home + "/Library/Caches/stew"
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
    /// STEW_LOG keeps test runs out of the real log.
    static var log: String { ProcessInfo.processInfo.environment["STEW_LOG"] ?? home + "/Library/Logs/stew.log" }

    /// Last update check, next to the socket, so a test daemon keeps its own.
    static var updateState: String { (socket as NSString).deletingLastPathComponent + "/update-state.json" }
    static var launchAgent: String { home + "/Library/LaunchAgents/\(launchAgentLabel).plist" }

    static var executable: String {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        _NSGetExecutablePath(&buffer, &size)
        let path = String(cString: buffer)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Where Stew.app is installed and where updates go: the app this binary runs from,
    /// in `~/Applications` from the install script or `/Applications` from the Homebrew
    /// cask. A binary outside any app looks in `~/Applications`. STEW_APP_PATH lets tests
    /// install an update into a temporary folder.
    static var installedApp: String {
        InstallLocation.app(override: ProcessInfo.processInfo.environment["STEW_APP_PATH"], runningExecutable: executable, home: home)
    }

    /// `claude` from config, then the usual install places, then PATH.
    static func claudeBinary(configured: String?) -> String? {
        if let configured, FileManager.default.isExecutableFile(atPath: configured) { return configured }
        return command("claude")
    }

    /// A command in the usual install places, then PATH. The daemon starts from launchd
    /// with a short PATH, so the install places come first.
    static func command(_ name: String) -> String? {
        let fileManager = FileManager.default
        let candidates = [home + "/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        if let found = candidates.first(where: fileManager.isExecutableFile(atPath:)) { return found }
        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        return pathEntries.map { "\($0)/\(name)" }.first(where: fileManager.isExecutableFile(atPath:))
    }
}

enum Log {
    static func write(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
    }

    /// For hook processes, whose stderr Claude Code would show in the session.
    static func append(_ message: String) {
        let line = Data("\(ISO8601DateFormatter().string(from: Date())) \(message)\n".utf8)
        if let handle = FileHandle(forWritingAtPath: Paths.log) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: Paths.log, contents: line)
        }
    }
}
