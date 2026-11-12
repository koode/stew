import CoreGraphics
import Darwin
import Foundation
import StewCore

/// history.jsonl next to the socket: ~/Library/Application Support/stew for the real
/// daemon, the test folder for a test daemon. Mode 0600, like the grants.
///
/// Only the daemon writes, on its own queue, after a request has ended, so neither the
/// panel nor a waiting hook ever waits for the disk.
final class HistoryStore {
    static var path: String { (Paths.socket as NSString).deletingLastPathComponent + "/history.jsonl" }

    private let queue = DispatchQueue(label: "stew.history")

    func append(_ entry: HistoryEntry) {
        queue.async {
            guard let line = try? History.line(entry) else { return }
            let descriptor = open(Self.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
            guard descriptor >= 0 else {
                Log.write("history: cannot open \(Self.path): \(String(cString: strerror(errno)))")
                return
            }
            defer { close(descriptor) }
            line.withUnsafeBytes { raw in _ = write(descriptor, raw.baseAddress, raw.count) }
        }
    }

    /// Drops entries older than `keepDays`, rewriting the file only when something goes.
    func prune(keepDays: Int) {
        queue.async {
            let entries = Self.readFile()
            let kept = History.pruned(entries, now: Date(), keepDays: keepDays)
            guard kept.count != entries.count, let data = try? History.lines(kept) else { return }
            Self.writeFile(data)
            Log.write("history: removed \(entries.count - kept.count) entries older than \(keepDays) days")
        }
    }

    /// Everything written so far, including writes still queued.
    func read() -> [HistoryEntry] {
        queue.sync { Self.readFile() }
    }

    /// Waits for queued writes, for a daemon about to exit.
    func flush() {
        queue.sync {}
    }

    static func readFile() -> [HistoryEntry] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return History.parse(data)
    }

    private static func writeFile(_ data: Data) {
        let temporary = path + ".tmp"
        FileManager.default.createFile(atPath: temporary, contents: data, attributes: [.posixPermissions: 0o600])
        if rename(temporary, path) != 0 {
            Log.write("history: cannot replace \(path): \(String(cString: strerror(errno)))")
        }
    }
}

/// Watches for the user coming back after at least two minutes without input, and
/// reports when they left.
final class AwayWatcher {
    private var tracker = AwayTracker()
    private var timer: Timer?

    func start(onReturn: @escaping (Date) -> Void) {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let anyInput = CGEventType(rawValue: ~0)!
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
            if let since = self.tracker.observe(idleSeconds: idle, now: Date()) {
                onReturn(since)
            }
        }
    }
}
