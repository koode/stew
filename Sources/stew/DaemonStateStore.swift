import Darwin
import Foundation
import StewCore

/// daemon-state.json next to the socket: the pause, when History was last opened, and
/// what the update notices need across a restart. Only the daemon writes it.
final class DaemonStateStore {
    static var path: String { (Paths.socket as NSString).deletingLastPathComponent + "/daemon-state.json" }

    private let path: String?
    private(set) var state: DaemonState

    /// Nil `path` keeps the state in memory only, for snapshots.
    init(path: String?) {
        self.path = path
        state = path.flatMap { FileManager.default.contents(atPath: $0) }.map(DaemonState.decode) ?? DaemonState()
    }

    func update(_ change: (inout DaemonState) -> Void) {
        var updated = state
        change(&updated)
        guard updated != state else { return }
        state = updated
        save()
    }

    private func save() {
        guard let path, let data = try? state.encoded() else { return }
        let temporary = path + ".tmp"
        FileManager.default.createFile(atPath: temporary, contents: data, attributes: [.posixPermissions: 0o600])
        if rename(temporary, path) != 0 {
            Log.write("state: cannot replace \(path): \(String(cString: strerror(errno)))")
        }
    }
}
