import Darwin
import Foundation
import StewCore

/// needs.json next to the socket: the open needs items, so they survive a daemon
/// restart. Mode 0600, because commands are kept as given and may hold a secret the
/// user has to copy. Only the daemon writes it; hooks and `stew needs list` read it.
final class NeedsStore {
    static var path: String { (Paths.socket as NSString).deletingLastPathComponent + "/needs.json" }

    private let path: String?
    private(set) var items: [NeedsItem]

    /// Nil `path` keeps the items in memory only, for snapshots.
    init(path: String?) {
        self.path = path
        items = path.flatMap { FileManager.default.contents(atPath: $0) }.map(NeedsBook.decode) ?? []
    }

    static func readFile() -> [NeedsItem] {
        FileManager.default.contents(atPath: path).map(NeedsBook.decode) ?? []
    }

    func item(_ id: String) -> NeedsItem? {
        items.first { $0.id == id }
    }

    /// Returns the automatic items the new one replaced.
    @discardableResult
    func add(_ item: NeedsItem) -> [NeedsItem] {
        let replaced = NeedsBook.add(item, to: &items)
        save()
        return replaced
    }

    func remove(_ id: String) -> NeedsItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = items.remove(at: index)
        save()
        return removed
    }

    func update(_ id: String, _ change: (inout NeedsItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        save()
    }

    /// Written at once, not queued, so `stew needs list` right after `stew needs` sees it.
    private func save() {
        guard let path, let data = try? NeedsBook.encode(items) else { return }
        let temporary = path + ".tmp"
        FileManager.default.createFile(atPath: temporary, contents: data, attributes: [.posixPermissions: 0o600])
        if rename(temporary, path) != 0 {
            Log.write("needs: cannot replace \(path): \(String(cString: strerror(errno)))")
        }
    }
}
