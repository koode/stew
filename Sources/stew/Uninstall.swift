import Foundation
import StewCore

/// `stew uninstall`: removes everything the installers put in place, so an install
/// from the release script can be removed without the source repository.
///
/// Order matters: the hooks go first, while the binary they call still exists, so
/// no agent calls a missing stew. The shell completion files the installer
/// wrote, and the iPhone pairings and the account session in the login keychain, go too. ~/.config/stew stays, and so do allow rules stew wrote into projects'
/// .claude/settings.local.json.
///
/// `keepApp` leaves Stew.app itself in place, for a package manager that removes it: the
/// Homebrew cask's `zap` runs `stew uninstall --keep-app` before it deletes the app.
enum Uninstaller {
    static func run(binDirectory: String, appDirectory: String, keepApp: Bool) -> Int32 {
        if !keepApp, let app = AppVersion.appBundle(forExecutable: Paths.executable),
           InstallLocation.isHomebrewCask(
               app: app,
               prefixes: InstallLocation.homebrewPrefixes(environment: ProcessInfo.processInfo.environment),
               directoryExists: { FileManager.default.fileExists(atPath: $0) },
               resolve: Setup.resolvedPath
           ) {
            // Going ahead would leave Homebrew's app, link and records behind.
            print("stew was installed with Homebrew. Remove it with: brew uninstall --cask --zap \(InstallLocation.caskToken)")
            return 1
        }
        var failures = 0
        do {
            try Hooks.uninstall()
        } catch {
            print("could not remove the hooks: \(error)")
            failures += 1
        }
        // Without a Codex hook file there is nothing to say about Codex.
        if FileManager.default.fileExists(atPath: Hooks.codexHooksPath) {
            do {
                try Hooks.uninstall(agent: .codex)
            } catch {
                print("could not remove the Codex hooks: \(error)")
                failures += 1
            }
        }

        Launchctl.run(["bootout", "gui/\(getuid())/\(Paths.launchAgentLabel)"])
        remove(Paths.launchAgent, &failures)

        for name in (keepApp ? [] : ["Stew.app"]) + [".Stew.app.installing", ".Stew.app.previous", ".stew-update"] {
            remove(appDirectory + "/" + name, &failures)
        }
        remove(binDirectory + "/stew", &failures)
        // Before the support folder goes, because the list of completion files is in it.
        failures += CompletionInstaller.uninstall()
        for agent in CodingAgent.allCases {
            remove(Setup.skillLocation(for: agent).skillFolder, &failures)
        }
        remove(Paths.home + "/Library/Caches/stew", &failures)
        remove(Paths.home + "/Library/Application Support/stew", &failures)
        // The keychain is not inside the home folder, so the installer tests (which set
        // STEW_INSTALL_LAUNCHCTL_LOG and a temporary HOME) must leave it alone.
        if ProcessInfo.processInfo.environment["STEW_INSTALL_LAUNCHCTL_LOG"] == nil {
            if PhoneStore.removeKeychainItems() {
                print("removed the iPhone pairings from the login keychain")
            }
            // Only this Mac's session; the account and its plan stay.
            if KeychainAccountTokenStore.removeAll() {
                print("removed the stew account session from the login keychain")
            }
        }

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
}
