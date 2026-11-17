import AppKit
import Combine
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
        let history = HistoryStore()
        coordinator.history = history
        coordinator.needsStore = NeedsStore(path: NeedsStore.path)
        coordinator.stateStore = DaemonStateStore(path: DaemonStateStore.path)
        let updater = Updater(log: Log.write)
        updater.restartsInBackground = true
        updater.isIdle = { coordinator.isIdle }
        coordinator.onIdle = { updater.idle() }
        coordinator.onUpdate = { reply in updater.run(install: true, completion: reply) }
        watchUpdates(updater, coordinator: coordinator)
        if !Paths.headless {
            let panel = PanelController(coordinator: coordinator)
            coordinator.onChange = { panel.update() }
            let confetti = ConfettiController()
            coordinator.onCelebrate = {
                if let frame = panel.visibleFrame { confetti.burst(around: frame) }
            }
            let settings = SettingsWindowController(updater: updater, pause: coordinator.pauseModel) { coordinator.configChanged() }
            coordinator.onOpenSettings = { tab in settings.show(tab) }
            let answerLate: (UUID, StewResponse) -> Bool = { entryID, response in
                coordinator.answerLate(entryID: entryID, with: response, answeredOn: Coordinator.macName)
            }
            settings.onLateAnswer = answerLate
            settings.onClearHistory = {
                coordinator.clearHistory()
                // Reloads the history in Settings and in the popover.
                coordinator.onLateAnswer?()
            }
            settings.onHistoryShown = { coordinator.historySeen() }
            settings.onPreviewKeys = { owns in coordinator.previewKeys(taken: owns, by: "settings") }
            coordinator.pauseModel.onPause = { choice in coordinator.pause(choice) }
            coordinator.pauseModel.onResume = { coordinator.resume() }
            // Only the real daemon has a menu bar item; a headless one answers `menu`.
            let menuBar = MenuBarController()
            // The menu bar is the home of the history: `stew history`, the menu's History
            // and the notice about missed requests open its popover, never Settings.
            coordinator.onOpenHistory = { missedOnly, entryID in menuBar.showHistory(missedOnly: missedOnly, select: entryID) }
            coordinator.onLateAnswer = {
                settings.reloadHistory()
                menuBar.popover.model.history.reload()
            }
            menuBar.onOpenNeeds = { id in coordinator.openNeeds(id: id) }
            menuBar.onHistory = { coordinator.openHistory(missedOnly: false) }
            menuBar.onSettings = { settings.show(.general) }
            menuBar.onPause = coordinator.pauseModel.onPause
            menuBar.onResume = coordinator.pauseModel.onResume
            menuBar.onHide = { settings.setShowInMenuBar(false) }
            menuBar.onUpdate = {
                switch coordinator.updateEntry {
                case .homebrew:
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(UpdateNotice.homebrewCommand, forType: .string)
                case .manual:
                    settings.show(.general)
                case .ready, .available, nil:
                    coordinator.onInstallUpdate?()
                }
            }
            let popover = menuBar.popover.model
            popover.history.onLateAnswer = answerLate
            popover.history.onClear = settings.onClearHistory
            popover.history.onPreviewKeys = { owns in coordinator.previewKeys(taken: owns, by: "popover") }
            popover.onOpenNeeds = menuBar.onOpenNeeds
            popover.onSettings = menuBar.onSettings
            popover.onPause = menuBar.onPause
            popover.onResume = menuBar.onResume
            popover.onUpdate = menuBar.onUpdate
            popover.onSeen = { coordinator.historySeen() }
            coordinator.onMenuBarChange = { state in menuBar.update(state) }
            awayWatcher.start { awaySince in coordinator.idleUserReturned(awaySince: awaySince) }
            // Locking the screen counts as leaving and unlocking it as coming back, for
            // Pause stew ▸ Until I'm back.
            let distributed = DistributedNotificationCenter.default()
            for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
                screenLockObservers.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
                    coordinator.screenLockChanged(locked: locked)
                })
            }
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
        PhoneLink.shared.start(coordinator: coordinator)
        // The headless test daemon keeps its session in a file next to its socket, so tests
        // never touch the keychain.
        let accountStore: AccountTokenStore = Paths.headless
            ? FileAccountTokenStore(path: (Paths.socket as NSString).deletingLastPathComponent + "/account-session")
            : KeychainAccountTokenStore()
        AccountModel.shared.start(store: accountStore) { lease in PhoneLink.shared.forwardLease(lease) }
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
        Log.write("stew daemon \(AppVersion.running) listening on \(Paths.socket)")
        history.prune(keepDays: coordinator.config.historyDays)
        LateAnswerFile.update { _ in }
        // The pause first, so needs items that come back while paused wait in the menu.
        coordinator.restoreState()
        coordinator.restoreNeeds()
        announceUpdate(coordinator)
        historyPruner = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { _ in
            coordinator.reloadConfigIfChanged()
            history.prune(keepDays: coordinator.config.historyDays)
            // Drops late answers and timed-out requests older than a day.
            LateAnswerFile.update { _ in }
        }
        updater.cleanUpAfterUpdate()
        updater.startSchedule {
            coordinator.reloadConfigIfChanged()
            return coordinator.config.autoUpdate
        }
        application.run()
        exit(0)
    }

    /// Keeps the menu's update entry current, installs on "Install now", announces a
    /// version found and not installed, and keeps the notes of an install for the
    /// "stew updated" notice of the next start.
    private static func watchUpdates(_ updater: Updater, coordinator: Coordinator) {
        coordinator.onInstallUpdate = {
            if updater.readyVersion != nil {
                updater.installReadyNow()
            } else {
                updater.run(install: true) { _ in }
            }
        }
        updater.onInstalled = { manifest in
            coordinator.stateStore.update { $0.installedUpdate = DaemonState.InstalledUpdate(version: manifest.version, notes: manifest.notes) }
        }
        updateWatch = updater.$availableVersion.combineLatest(updater.$readyVersion)
            .receive(on: DispatchQueue.main)
            .sink { available, ready in
                if let ready {
                    coordinator.updateEntry = .ready(ready)
                } else if let available, updater.isReleaseBuild {
                    let route = Updater.installRoute
                    coordinator.updateEntry = UpdateNotice.menuEntry(available, route: route)
                    // With automatic updates on, stew installs it by itself where it can.
                    if !coordinator.config.autoUpdate || route != .inPlace {
                        coordinator.announceAvailable(available, route: route)
                    }
                } else {
                    coordinator.updateEntry = nil
                }
            }
    }

    /// The first start of a newer version says so, once.
    private static func announceUpdate(_ coordinator: Coordinator) {
        let running = AppVersion.running.version
        if let notice = UpdateNotice.afterStart(coordinator.stateStore.state, running: running) {
            coordinator.showNotice(notice)
        }
        coordinator.stateStore.update { state in
            state.lastRunVersion = running
            if state.installedUpdate?.version == running { state.installedUpdate = nil }
        }
    }

    private static var updateWatch: AnyCancellable?
    private static var signalSources: [DispatchSourceSignal] = []
    private static let awayWatcher = AwayWatcher()
    private static var screenLockObservers: [NSObjectProtocol] = []
    private static var historyPruner: Timer?
}
