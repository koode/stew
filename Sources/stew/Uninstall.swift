import Foundation

/// `stew uninstall`: removes everything the installers put in place, so an install
/// from the release script can be removed without the source repository.
///
/// Order matters: the hooks go first, while the binary they call still exists, so
/// Claude Code never calls a missing stew. ~/.config/stew stays, and so do allow rules
/// stew wrote into projects' .claude/settings.local.json.
enum Uninstaller {
    static func run(binDirectory: String, appDirectory: String) -> Int32 {
        var failures = 0
        do {
            try Hooks.uninstall()
        } catch {
            print("could not remove the hooks: \(error)")
            failures += 1
        }

        launchctl(["bootout", "gui/\(getuid())/\(Paths.launchAgentLabel)"])
        remove(Paths.launchAgent, &failures)

        for name in ["Stew.app", ".Stew.app.installing", ".Stew.app.previous", ".stew-update"] {
            remove(appDirectory + "/" + name, &failures)
        }
        remove(binDirectory + "/stew", &failures)
        remove(Paths.home + "/.claude/skills/stew", &failures)
        remove(Paths.home + "/Library/Caches/stew", &failures)
        remove(Paths.home + "/Library/Application Support/stew", &failures)

        if failures == 0 {
            print("stew removed. Settings in ~/.config/stew are kept.")
        } else {
            print("stew removed, except for \(failures) item(s) listed above.")
        }
        return failures == 0 ? 0 : 1
    }

    private static func remove(_ path: String, _ failures: inout Int) {
        let fileManager = FileManager.default
        // A link counts even when what it points to is already gone.
        guard (try? fileManager.attributesOfItem(atPath: path)) != nil else { return }
        do {
            try fileManager.removeItem(atPath: path)
            print("removed \(path)")
        } catch {
            print("could not remove \(path): \(error.localizedDescription)")
            failures += 1
        }
    }

    /// Tests set STEW_INSTALL_LAUNCHCTL_LOG, so they never stop the real daemon.
    private static func launchctl(_ arguments: [String]) {
        if let logPath = ProcessInfo.processInfo.environment["STEW_INSTALL_LAUNCHCTL_LOG"] {
            let line = Data(("launchctl " + arguments.joined(separator: " ") + "\n").utf8)
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(line)
                try? handle.close()
            } else {
                FileManager.default.createFile(atPath: logPath, contents: line)
            }
            return
        }
        Client.run("/bin/launchctl", arguments)
    }
}
