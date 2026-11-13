import Darwin
import Foundation
import StewCore

/// Finds, verifies and installs new versions of Stew.app.
///
/// A release is trusted only when the zip matches the size and SHA-256 in latest.json,
/// carries an Ed25519 signature from the release key built into this binary, and the
/// app inside passes `codesign --verify` with the Koode Developer ID team. The app is
/// swapped only while no request is open, then the LaunchAgent restarts the daemon.
final class Updater: ObservableObject {
    /// Base64 Ed25519 public key of the release signing key. `scripts/release.sh keygen`
    /// prints the value for this constant. While it is empty, this build checks for
    /// updates but refuses to install them.
    static let embeddedPublicKey = "mIUbo3h7qbGdsZG3yy5lMiTECjJh5M4WuB2IXfHmzXw="
    static let teamIdentifier = "PXD36584ME"
    static let defaultManifestURL = "https://releases.stewcli.com/latest.json"
    static let checkInterval: TimeInterval = 24 * 60 * 60

    struct State: Codable, Equatable {
        var lastCheck: Date?
        var lastResult: String?
    }

    @Published private(set) var state: State
    @Published private(set) var busy = false
    /// The version the last check found and did not install, for "Install now".
    @Published private(set) var availableVersion: String?
    /// A downloaded and verified version that waits until no request is open.
    @Published private(set) var readyVersion: String?
    /// Told about each install that succeeded, before the restart, so the new daemon can
    /// announce it with its release notes.
    var onInstalled: ((UpdateManifest) -> Void)?

    /// True while no request is open, so the app may be swapped. The daemon sets it.
    var isIdle: () -> Bool = { true }
    /// The daemon's own restart. Nil in the command line tool, which waits for launchctl.
    var restartsInBackground = false

    private let queue = DispatchQueue(label: "stew.update")
    private let log: (String) -> Void
    private var pending: (staged: String, manifest: UpdateManifest)? {
        didSet { readyVersion = pending?.manifest.version }
    }
    private var timer: Timer?

    /// Only an app signed with the Koode team and not marked as built from source
    /// installs updates. A release would silently replace the user's own build, so a
    /// source build only checks and reports, even when it is signed with a certificate.
    let isReleaseBuild: Bool

    static let sourceBuildNote = "Built from source: install updates by rebuilding."

    /// `availableVersion` and `releaseBuild` preset the state, for snapshots of the
    /// settings window.
    init(log: @escaping (String) -> Void, availableVersion: String? = nil, releaseBuild: Bool? = nil) {
        self.log = log
        state = Self.loadState()
        self.availableVersion = availableVersion
        isReleaseBuild = releaseBuild ?? Self.checkReleaseBuild()
    }

    /// The code requirement for a Koode Developer ID signature.
    static var teamRequirement: String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    /// Checks the installed app, which is what an update would replace, else the app
    /// this binary runs from. A binary outside any app is a development build.
    /// STEW_UPDATE_ASSUME_RELEASE_BUILD=1 lets tests install over ad hoc builds.
    private static func checkReleaseBuild() -> Bool {
        if ProcessInfo.processInfo.environment["STEW_UPDATE_ASSUME_RELEASE_BUILD"] == "1" { return true }
        let installed = FileManager.default.fileExists(atPath: Paths.installedApp) ? Paths.installedApp : nil
        guard let app = installed ?? AppVersion.appBundle(forExecutable: Paths.executable) else { return false }
        if Bundle(path: app)?.object(forInfoDictionaryKey: "StewSourceBuild") as? Bool == true { return false }
        return runTool("/usr/bin/codesign", ["--verify", "-R=\(teamRequirement)", app]).0 == 0
    }

    static var manifestURL: String {
        ProcessInfo.processInfo.environment["STEW_UPDATE_URL"] ?? defaultManifestURL
    }

    static var publicKey: String {
        ProcessInfo.processInfo.environment["STEW_UPDATE_PUBLIC_KEY"] ?? embeddedPublicKey
    }

    /// Tests install ad hoc signed bundles; a real update always needs the team.
    static var skipsTeamCheck: Bool {
        ProcessInfo.processInfo.environment["STEW_UPDATE_SKIP_TEAM_CHECK"] == "1"
    }

    /// Downloads and the old app wait here, on the same volume as the app, so the swap
    /// is two renames.
    static var workDirectory: String {
        ((Paths.installedApp as NSString).deletingLastPathComponent as NSString).appendingPathComponent(".stew-update")
    }

    /// The installed app is what an update replaces; a binary outside it compares itself.
    static var installedVersion: AppVersion {
        AppVersion.installed(at: Paths.installedApp) ?? AppVersion.running
    }

    /// Whether this user can swap the installed app in place. When Stew.app is missing,
    /// `prepare` reports that instead.
    static var installRoute: UpdateRoute {
        let app = Paths.installedApp
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: app) else { return .inPlace }
        return UpdateRoute.choose(
            app: app,
            appWritable: fileManager.isWritableFile(atPath: app),
            folderWritable: fileManager.isWritableFile(atPath: (app as NSString).deletingLastPathComponent),
            homebrewCask: InstallLocation.isHomebrewCask(
                app: app,
                prefixes: InstallLocation.homebrewPrefixes(environment: ProcessInfo.processInfo.environment),
                directoryExists: { fileManager.fileExists(atPath: $0) },
                resolve: Setup.resolvedPath
            )
        )
    }

    /// Why updates cannot install here, for Settings; nil when they can.
    var installNote: String? { isReleaseBuild ? Self.installRoute.note : nil }

    /// Restarting goes through launchd, and only for the real install: never for a test
    /// daemon, which has its own socket or app path.
    static var canRestart: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["STEW_APP_PATH"] == nil && environment["STEW_SOCKET"] == nil && !Paths.headless
            && FileManager.default.fileExists(atPath: Paths.launchAgent)
    }

    /// Checks at start after `firstCheck` seconds, then every hour whether a day has
    /// passed since the last check. A wall clock comparison, so sleep does not delay it.
    /// A headless test daemon checks only when STEW_UPDATE_FIRST_CHECK asks it to, so
    /// tests never reach the real release server by accident.
    func startSchedule(enabled: @escaping () -> Bool) {
        let override = ProcessInfo.processInfo.environment["STEW_UPDATE_FIRST_CHECK"].flatMap(Double.init)
        if Paths.headless && override == nil { return }
        let firstCheck = override ?? 60
        DispatchQueue.main.asyncAfter(deadline: .now() + firstCheck) { [weak self] in
            guard let self else { return }
            if !enabled() { self.log("update: automatic updates are off; checking only") }
            self.run(install: enabled()) { _ in }
            self.timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
                guard let self else { return }
                let last = self.state.lastCheck ?? .distantPast
                if Date().timeIntervalSince(last) >= Self.checkInterval { self.run(install: enabled()) { _ in } }
            }
        }
    }

    /// Checks, and with `install` downloads, verifies and installs. Calls `completion`
    /// on the main queue once the outcome is known; an install that waits for open
    /// requests reports `deferred` and finishes later on its own.
    func run(install: Bool, completion: @escaping (UpdateOutcome) -> Void) {
        if let pending {
            completion(UpdateOutcome(status: .deferred, message: "Version \(pending.manifest.version) is ready and installs when no request is open.", version: pending.manifest.version))
            return
        }
        guard !busy else {
            completion(UpdateOutcome(status: .checkFailed, message: "An update check is already running."))
            return
        }
        busy = true
        queue.async { [self] in
            var outcome: UpdateOutcome
            var staged: (String, UpdateManifest)?
            do {
                let (manifest, decision) = try check()
                outcome = describe(decision, manifest: manifest)
                if install, decision == .available {
                    let route = Self.installRoute
                    if isReleaseBuild, let note = route.note {
                        outcome.message += " " + note
                        log("update: not installing; cannot replace \(Paths.installedApp) (\(route))")
                    } else if isReleaseBuild {
                        staged = (try prepare(manifest), manifest)
                    } else {
                        outcome.message += " " + Self.sourceBuildNote
                        log("update: not installing; this build is not signed with the Koode Developer ID")
                    }
                }
            } catch {
                outcome = UpdateOutcome.failure(error)
                log("update: \(outcome.message)")
            }
            DispatchQueue.main.async { [self] in
                busy = false
                if let (path, manifest) = staged {
                    outcome = installWhenIdle(staged: path, manifest: manifest)
                }
                record(outcome)
                availableVersion = outcome.status == .available ? outcome.version : nil
                completion(outcome)
                if outcome.status == .installed { restart() }
            }
        }
    }

    /// The daemon calls this whenever its requests change, to finish a waiting install.
    func idle() {
        guard let pending, isIdle() else { return }
        self.pending = nil
        log("update: no open requests; installing \(pending.manifest.version)")
        let outcome = install(staged: pending.staged, manifest: pending.manifest)
        record(outcome)
        if outcome.status == .installed { restart() }
    }

    /// "Restart to update" in the menu bar: installs the waiting version now, also while
    /// a request is open; the restart ends that request like a stop would.
    func installReadyNow() {
        guard let pending else { return }
        self.pending = nil
        log("update: installing \(pending.manifest.version) now, as asked")
        let outcome = install(staged: pending.staged, manifest: pending.manifest)
        record(outcome)
        if outcome.status == .installed { restart() }
    }

    /// Removes what an earlier update left: the previous app and any half-done download.
    /// The new daemon runs this on start, so it also rewrites the installed shell
    /// completion scripts to match its own commands.
    func cleanUpAfterUpdate() {
        let work = Self.workDirectory
        guard FileManager.default.fileExists(atPath: work) else { return }
        try? FileManager.default.removeItem(atPath: work)
        log("update: removed \(work)")
        CompletionInstaller.refresh(log: log)
    }

    private func check() throws -> (UpdateManifest, UpdateDecision) {
        guard let url = URL(string: Self.manifestURL), UpdateManifest.isAllowedDownload(url) else {
            throw UpdateError.invalidManifest("update URL \(Self.manifestURL) must be https")
        }
        log("update: checking \(url.absoluteString)")
        let manifest = try UpdateManifest.decode(try Self.fetch(url, timeout: 30))
        let installed = Self.installedVersion
        let decision = UpdateDecision.evaluate(manifest, installed: installed, macOS: ProcessInfo.processInfo.operatingSystemVersion)
        log("update: latest is \(manifest.version) (build \(manifest.build)), installed is \(installed): \(decision)")
        return (manifest, decision)
    }

    private func describe(_ decision: UpdateDecision, manifest: UpdateManifest) -> UpdateOutcome {
        switch decision {
        case .upToDate:
            return UpdateOutcome(status: .upToDate, message: "stew is up to date: \(Self.installedVersion).", version: manifest.version)
        case .available:
            return UpdateOutcome(status: .available, message: "Version \(manifest.version) (build \(manifest.build)) is available.", version: manifest.version)
        case .needsNewerMacOS(let minimum):
            return UpdateOutcome(status: .needsNewerMacOS, message: "Version \(manifest.version) needs macOS \(minimum) or later.", version: manifest.version)
        }
    }

    /// Download, verify the zip, unzip next to the app and verify the code signature.
    /// Returns the path of the new Stew.app.
    private func prepare(_ manifest: UpdateManifest) throws -> String {
        let publicKey = Self.publicKey
        guard !publicKey.isEmpty else { throw UpdateError.noPublicKey }
        guard FileManager.default.fileExists(atPath: Paths.installedApp) else {
            throw UpdateError.install("no Stew.app at \(Paths.installedApp); install stew with the install script first")
        }
        guard let url = URL(string: manifest.archive.url) else { throw UpdateError.invalidManifest("bad archive url") }
        let fileManager = FileManager.default
        let work = Self.workDirectory
        let newFolder = work + "/new"
        try? fileManager.removeItem(atPath: newFolder)
        try fileManager.createDirectory(atPath: newFolder, withIntermediateDirectories: true)

        log("update: downloading \(url.absoluteString)")
        let zip = try Self.fetch(url, timeout: 300)
        try UpdateVerifier.verify(zip, against: manifest.archive, publicKey: publicKey)
        log("update: zip verified (\(zip.count) bytes, sha256 \(manifest.archive.sha256), Ed25519 signature)")

        let zipPath = work + "/Stew-\(manifest.version).zip"
        try zip.write(to: URL(fileURLWithPath: zipPath))
        defer { try? fileManager.removeItem(atPath: zipPath) }
        let (unzipStatus, unzipOutput) = Self.runTool("/usr/bin/ditto", ["-x", "-k", zipPath, newFolder])
        guard unzipStatus == 0 else { throw UpdateError.wrongBundle("cannot unzip: \(unzipOutput)") }
        let contents = (try? fileManager.contentsOfDirectory(atPath: newFolder)) ?? []
        guard contents == ["Stew.app"] else {
            throw UpdateError.wrongBundle("the zip must hold only Stew.app, it holds \(contents.joined(separator: ", "))")
        }
        let staged = newFolder + "/Stew.app"
        guard let infoPlist = fileManager.contents(atPath: staged + "/Contents/Info.plist") else {
            throw UpdateError.wrongBundle("the app has no Info.plist")
        }
        try UpdateVerifier.checkBundle(infoPlist: infoPlist, matches: manifest)
        log("update: unzipped Stew.app \(manifest.version) (build \(manifest.build))")

        let (verifyStatus, verifyOutput) = Self.runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged])
        guard verifyStatus == 0 else { throw UpdateError.codeSignature("codesign --verify failed: \(verifyOutput)") }
        if Self.skipsTeamCheck {
            log("update: code signature valid; team check skipped (STEW_UPDATE_SKIP_TEAM_CHECK)")
        } else {
            let requirement = Self.teamRequirement
            let (teamStatus, teamOutput) = Self.runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=\(requirement)", staged])
            let (_, details) = Self.runTool("/usr/bin/codesign", ["-dv", staged])
            let team = UpdateVerifier.teamIdentifier(fromCodesignOutput: details)
            guard teamStatus == 0, team == Self.teamIdentifier else {
                throw UpdateError.codeSignature("the app is signed by team \(team ?? "none"), not \(Self.teamIdentifier): \(teamOutput)")
            }
            log("update: code signature valid, team \(Self.teamIdentifier)")
        }
        return staged
    }

    private func installWhenIdle(staged: String, manifest: UpdateManifest) -> UpdateOutcome {
        guard isIdle() else {
            pending = (staged, manifest)
            log("update: \(manifest.version) is ready; waiting until no request is open")
            return UpdateOutcome(status: .deferred, message: "Version \(manifest.version) is ready and installs when no request is open.", version: manifest.version)
        }
        return install(staged: staged, manifest: manifest)
    }

    private func install(staged: String, manifest: UpdateManifest) -> UpdateOutcome {
        let backupFolder = Self.workDirectory + "/backup"
        try? FileManager.default.removeItem(atPath: backupFolder)
        do {
            try FileManager.default.createDirectory(atPath: backupFolder, withIntermediateDirectories: true)
            try AppSwap.swap(installed: Paths.installedApp, staged: staged, backup: backupFolder + "/Stew.app") { source, destination in
                Darwin.rename(source, destination) == 0 ? 0 : errno
            }
        } catch {
            let outcome = UpdateOutcome(status: .installFailed, message: (error as? UpdateError)?.description ?? "install failed: \(error)", version: manifest.version)
            log("update: \(outcome.message)")
            return outcome
        }
        log("update: installed \(manifest.version) (build \(manifest.build)) at \(Paths.installedApp); previous version kept in \(backupFolder)")
        onInstalled?(manifest)
        let restartNote = Self.canRestart ? " stew restarts now." : ""
        return UpdateOutcome(status: .installed, message: "Installed version \(manifest.version) (build \(manifest.build)).\(restartNote)", version: manifest.version)
    }

    /// `launchctl kickstart -k` stops this daemon and starts the new binary. The daemon
    /// runs it detached, so launchctl survives the daemon it stops.
    private func restart() {
        guard Self.canRestart else {
            log("update: restart skipped (test install or no LaunchAgent)")
            return
        }
        let target = "gui/\(getuid())/\(Paths.launchAgentLabel)"
        log("update: restarting with launchctl kickstart -k \(target)")
        if restartsInBackground {
            // Give the reply to `stew update` time to leave before launchd stops us.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                Client.spawnDetached("/bin/launchctl", ["kickstart", "-k", target])
            }
        } else {
            Client.run("/bin/launchctl", ["kickstart", "-k", target])
        }
    }

    private func record(_ outcome: UpdateOutcome) {
        state = State(lastCheck: Date(), lastResult: outcome.message)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(state) {
            try? data.write(to: URL(fileURLWithPath: Paths.updateState), options: .atomic)
        }
    }

    private static func loadState() -> State {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = FileManager.default.contents(atPath: Paths.updateState),
              let state = try? decoder.decode(State.self, from: data)
        else { return State() }
        return state
    }

    /// One GET with no caching, so latest.json is always fresh.
    private static func fetch(_ url: URL, timeout: TimeInterval) throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("stew/\(AppVersion.running.version)", forHTTPHeaderField: "User-Agent")
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(UpdateError.download("no response from \(url.absoluteString)"))
        session.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(UpdateError.download("\(url.absoluteString): \(error.localizedDescription)"))
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure(UpdateError.download("HTTP \(http.statusCode) from \(url.absoluteString)"))
            } else {
                result = .success(data ?? Data())
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return try result.get()
    }

    /// Runs a tool and returns its exit status with stdout and stderr together.
    private static func runTool(_ path: String, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch { return (-1, "\(error)") }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
