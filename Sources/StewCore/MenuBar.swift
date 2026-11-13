import Foundation

/// stew paused by the user, who is away. Requests that need an answer now time out at
/// once with a note saying so; notifications and needs items still arrive. A pause
/// always ends by itself.
public struct PauseState: Codable, Equatable, Sendable {
    public var since: Date
    public var until: Date

    public init(since: Date, until: Date) {
        self.since = since
        self.until = until
    }

    /// The menu bar's "Pause stew for 1 hour", and `stew pause` without a number.
    public static let defaultMinutes = 60
    /// Longest pause `stew pause MINUTES` accepts: a day.
    public static let maximumMinutes = 24 * 60

    public static func starting(at now: Date, minutes: Int) -> PauseState {
        PauseState(since: now, until: now.addingTimeInterval(Double(minutes) * 60))
    }

    public func isActive(now: Date) -> Bool { now < until }

    /// Whole minutes left, rounded up, so the last seconds still read "1 min".
    public func remainingMinutes(now: Date) -> Int {
        max(1, Int((until.timeIntervalSince(now) / 60).rounded(.up)))
    }

    /// Permission requests, questions and inputs time out at once while paused, since
    /// nobody would answer them in time. Notifications and needs items can wait.
    public static func timesOut(_ prompt: Prompt) -> Bool {
        switch prompt {
        case .permission, .question, .input: true
        case .notify, .needs: false
        }
    }

    public struct MinutesError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// The MINUTES of `stew pause [MINUTES]`: a whole number from 1 to a day.
    public static func minutes(from text: String?) throws -> Int {
        guard let text else { return defaultMinutes }
        guard let minutes = Int(text), (1...maximumMinutes).contains(minutes) else {
            throw MinutesError(description: "pause takes a whole number of minutes from 1 to \(maximumMinutes)")
        }
        return minutes
    }
}

extension StewRequest {
    /// What Claude reads about a request that timed out at once because stew is paused.
    public func pausedNote(remainingMinutes: Int) -> String {
        let late = LateMailbox.canAnswerLate(self)
            ? " If they answer later, stew passes their answer on to you as a late answer, which replaces this timeout."
            : ""
        let span = "\(remainingMinutes) min"
        switch prompt {
        case .permission, .notify, .needs:
            return "The user paused stew and is away, so nobody saw this request. Treat it as denied and continue another way, or ask again after stew resumes in about \(span).\(late)"
        case .question, .input:
            return "The user paused stew and is away, so nobody saw this request. Continue with a safe choice that does not need this answer, or ask again after stew resumes in about \(span).\(late)"
        }
    }
}

/// What the stew menu bar item shows: the icon with its badges, and the menu.
public struct MenuBarState: Equatable, Sendable {
    public enum Update: Equatable, Sendable {
        /// Downloaded and verified; installing restarts stew.
        case ready(String)
        /// Found and not installed, and stew can install it.
        case available(String)
        /// Found, and Homebrew has to install it: the entry copies the command.
        case homebrew(String)
        /// Found, and this user cannot replace the app: the entry opens Settings, which
        /// says why.
        case manual(String)
    }

    public var openNeeds: [NeedsItem]
    /// Missed requests the user has not seen in History yet.
    public var missedCount: Int
    /// Set only while a pause is active.
    public var pausedUntil: Date?
    public var update: Update?
    /// The "Show in menu bar" setting.
    public var showsAlways: Bool

    public init(openNeeds: [NeedsItem] = [], missedCount: Int = 0, pausedUntil: Date? = nil, update: Update? = nil, showsAlways: Bool = true) {
        self.openNeeds = openNeeds
        self.missedCount = missedCount
        self.pausedUntil = pausedUntil
        self.update = update
        self.showsAlways = showsAlways
    }

    /// With "Show in menu bar" off, the item still appears while something needs the user.
    public var isVisible: Bool { showsAlways || !openNeeds.isEmpty }

    /// Everything that waits on the user: open needs items and unseen missed requests.
    public var badgeCount: Int { openNeeds.count + missedCount }

    public var icon: MenuBarIcon {
        MenuBarIcon(count: badgeCount, updateDot: update != nil, paused: pausedUntil != nil)
    }

    /// The menu, top to bottom. `timeText` formats the end of a pause ("15:40").
    public func entries(timeText: (Date) -> String) -> [MenuEntry] {
        var sections: [[MenuEntry]] = []
        if let pausedUntil {
            sections.append([MenuEntry(title: "Paused until \(timeText(pausedUntil))", action: .none)])
        }
        if !openNeeds.isEmpty {
            var needs = [MenuEntry(title: NeedsBook.countText(openNeeds.count), action: .none)]
            needs += openNeeds.map { MenuEntry(title: $0.menuTitle, action: .openNeeds($0.id), toolTip: $0.session.cwd) }
            sections.append(needs)
        }
        sections.append([
            MenuEntry(title: "History…", action: .history, badge: missedCount > 0 ? missedCount : nil),
            MenuEntry(title: "Settings…", action: .settings),
        ])
        var control = [pausedUntil == nil
            ? MenuEntry(title: "Pause stew for 1 hour", action: .pause)
            : MenuEntry(title: "Resume stew", action: .resume)]
        switch update {
        case .ready(let version): control.append(MenuEntry(title: "stew \(version) is ready, restart to update", action: .update))
        case .available(let version): control.append(MenuEntry(title: "stew \(version) is available, install now", action: .update))
        case .homebrew(let version):
            control.append(MenuEntry(title: "stew \(version) is available, copy the brew command", action: .update, toolTip: UpdateNotice.homebrewCommand))
        case .manual(let version): control.append(MenuEntry(title: "stew \(version) is available, see Settings", action: .update))
        case nil: break
        }
        sections.append(control)
        if showsAlways {
            sections.append([MenuEntry(title: "Hide menu bar icon", action: .hide)])
        }
        return Array(sections.joined(separator: [MenuEntry.separator]))
    }

    /// The icon's state, then the entries, for the end-to-end tests, on one line split by
    /// " | ": "-" for a separator, "(…)" around one that does nothing, "[N]" after a badge.
    public func describe(timeText: (Date) -> String) -> String {
        let icon = self.icon
        let header = "visible=\(isVisible) count=\(icon.count) dot=\(icon.updateDot) paused=\(icon.paused)"
        let lines = entries(timeText: timeText).map { entry -> String in
            if entry.isSeparator { return "-" }
            let title = entry.action == .none ? "(\(entry.title))" : entry.title
            return entry.badge.map { "\(title) [\($0)]" } ?? title
        }
        return ([header] + lines).joined(separator: " | ")
    }
}

public struct MenuEntry: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// A heading or a state line: shown, not clickable.
        case none
        case openNeeds(String)
        case history, settings, pause, resume, update, hide
    }

    public var title: String
    public var action: Action
    /// A count at the trailing edge.
    public var badge: Int?
    public var toolTip: String?
    public var isSeparator = false

    public init(title: String, action: Action, badge: Int? = nil, toolTip: String? = nil) {
        self.title = title
        self.action = action
        self.badge = badge
        self.toolTip = toolTip
    }

    public static let separator: MenuEntry = {
        var entry = MenuEntry(title: "", action: .none)
        entry.isSeparator = true
        return entry
    }()
}

/// The look of the menu bar icon: the app icon, a count beside it, a dot for an update,
/// and grey while paused.
public struct MenuBarIcon: Equatable, Sendable {
    public var count: Int
    public var updateDot: Bool
    public var paused: Bool

    public init(count: Int = 0, updateDot: Bool = false, paused: Bool = false) {
        self.count = count
        self.updateDot = updateDot
        self.paused = paused
    }

    /// The count as shown: nothing at zero, "99+" past 99.
    public var countText: String? {
        guard count > 0 else { return nil }
        return count > 99 ? "99+" : "\(count)"
    }
}

public enum MenuBarBadge {
    /// Timeouts and secrets to enter later that ended after the user last opened History
    /// and have no late answer yet. With no `seenAt`, every one counts. The history keeps
    /// whole seconds, so one that ended in the second History opened counts as seen.
    public static func unseenMissed(_ entries: [HistoryEntry], seenAt: Date?) -> Int {
        let cutoff = seenAt.map(History.wholeSecond)
        return entries.filter { entry in
            entry.answerableLater && entry.late == nil && (cutoff.map { entry.ended > $0 } ?? true)
        }.count
    }
}

/// What the daemon remembers between runs for the menu bar and its notices, in
/// daemon-state.json next to the socket.
public struct DaemonState: Codable, Equatable, Sendable {
    public var pause: PauseState?
    /// When the user last opened History: missed requests before it count as seen.
    public var historySeenAt: Date?
    /// The version of the daemon that ran last, to notice that stew was updated.
    public var lastRunVersion: String?
    /// The update the daemon installed before it restarted, with its release notes.
    public var installedUpdate: InstalledUpdate?
    /// Versions already announced as available, so each gets one notice.
    public var announcedVersions: [String]

    public struct InstalledUpdate: Codable, Equatable, Sendable {
        public var version: String
        public var notes: String?

        public init(version: String, notes: String?) {
            self.version = version
            self.notes = notes
        }
    }

    public init(pause: PauseState? = nil, historySeenAt: Date? = nil, lastRunVersion: String? = nil, installedUpdate: InstalledUpdate? = nil, announcedVersions: [String] = []) {
        self.pause = pause
        self.historySeenAt = historySeenAt
        self.lastRunVersion = lastRunVersion
        self.installedUpdate = installedUpdate
        self.announcedVersions = announcedVersions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pause = try? container.decodeIfPresent(PauseState.self, forKey: .pause)
        historySeenAt = try? container.decodeIfPresent(Date.self, forKey: .historySeenAt)
        lastRunVersion = try? container.decodeIfPresent(String.self, forKey: .lastRunVersion)
        installedUpdate = try? container.decodeIfPresent(InstalledUpdate.self, forKey: .installedUpdate)
        announcedVersions = (try? container.decodeIfPresent([String].self, forKey: .announcedVersions)) ?? []
    }

    public static func decode(_ data: Data) -> DaemonState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(DaemonState.self, from: data)) ?? DaemonState()
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// The notices about new versions, shown in the panel as notifications.
public enum UpdateNotice {
    /// Once, on the first start of a newer version: "stew updated to 0.2.0", with a link
    /// to the release notes when the installed update named an http(s) URL for them.
    public static func afterStart(_ state: DaemonState, running: String) -> NotifyRequest? {
        guard let current = SemanticVersion(running) else { return nil }
        let installed = state.installedUpdate?.version == running ? state.installedUpdate : nil
        if let last = state.lastRunVersion.flatMap(SemanticVersion.init) {
            guard current > last else { return nil }
        } else if installed == nil {
            return nil
        }
        let link = installed?.notes.flatMap(URL.init(string:)).flatMap { url -> NotifyLink? in
            guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else { return nil }
            return NotifyLink(title: "What's new", url: url.absoluteString)
        }
        return NotifyRequest(title: "stew updated to \(running)", level: .info, link: link)
    }

    public static let homebrewCommand = "brew upgrade --cask \(InstallLocation.caskToken)"

    /// A version found and not installed, once per version. Where stew can install it,
    /// the notice offers Install now; else it says how to update.
    public static func available(_ version: String, route: UpdateRoute, state: DaemonState) -> NotifyRequest? {
        guard !state.announcedVersions.contains(version) else { return nil }
        let title = "stew \(version) is available"
        switch route {
        case .inPlace:
            return NotifyRequest(title: title, level: .info, action: .installUpdate)
        case .homebrew:
            return NotifyRequest(title: title, body: "Update it with Homebrew: \(homebrewCommand)", level: .info)
        case .notWritable:
            return NotifyRequest(title: title, body: route.note, level: .info)
        }
    }

    /// The menu entry for a version found and not installed.
    public static func menuEntry(_ version: String, route: UpdateRoute) -> MenuBarState.Update {
        switch route {
        case .inPlace: .available(version)
        case .homebrew: .homebrew(version)
        case .notWritable: .manual(version)
        }
    }
}
