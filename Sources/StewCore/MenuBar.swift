import Foundation

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
    /// Set while a pause is active, and in the minute before Until I'm back begins.
    public var pause: PauseDisplay?
    public var update: Update?
    /// The "Show in menu bar" setting.
    public var showsAlways: Bool
    /// The hour the morning choice, Until 08:00, ends at.
    public var morningHour: Int
    /// The "Icon" setting: the pot without its tile, tinted by macOS.
    public var monochromeIcon: Bool

    public init(
        openNeeds: [NeedsItem] = [], missedCount: Int = 0, pause: PauseDisplay? = nil, update: Update? = nil, showsAlways: Bool = true,
        morningHour: Int = PauseChoice.defaultMorningHour, monochromeIcon: Bool = false
    ) {
        self.openNeeds = openNeeds
        self.missedCount = missedCount
        self.pause = pause
        self.update = update
        self.showsAlways = showsAlways
        self.morningHour = morningHour
        self.monochromeIcon = monochromeIcon
    }

    /// The ways to pause stew, in the order the Pause stew submenu lists them. Each gets
    /// its title from `PauseChoice.title`, and the daemon starts it with `pause(_:)`.
    public var pauseChoices: [PauseChoice] { PauseChoice.menu(morningHour: morningHour) }

    /// With "Show in menu bar" off, the item still appears while something needs the user.
    public var isVisible: Bool { showsAlways || !openNeeds.isEmpty }

    /// Everything that waits on the user: open needs items and unseen missed requests.
    public var badgeCount: Int { openNeeds.count + missedCount }

    public var icon: MenuBarIcon {
        MenuBarIcon(count: badgeCount, updateDot: update != nil, paused: pause?.isPaused ?? false, monochrome: monochromeIcon)
    }

    /// The menu at `now`, top to bottom. `timeText` formats the end of a pause ("15:40",
    /// "08:00 tomorrow"), as `PauseState.endText` does.
    public func entries(now: Date = Date(), calendar: Calendar = .current, timeText: (Date) -> String) -> [MenuEntry] {
        var sections: [[MenuEntry]] = []
        if let pause {
            sections.append([MenuEntry(title: pause.title(now: now, timeText: timeText), action: .none)])
        }
        if !openNeeds.isEmpty {
            var needs = [MenuEntry(title: NeedsBook.countText(openNeeds.count), action: .none)]
            needs += openNeeds.map { MenuEntry(title: $0.menuTitle, action: .openNeeds($0.id), toolTip: $0.session.cwd) }
            sections.append(needs)
        }
        sections.append([
            MenuEntry(title: "History…", action: .history, badge: missedCount > 0 ? missedCount : nil),
            MenuEntry(title: "Settings…", action: .settings),
            MenuEntry(title: "Set up stew…", action: .setup),
        ])
        var control: [MenuEntry]
        switch pause {
        case nil:
            let choices = pauseChoices.map { choice in
                MenuEntry(title: choice.title(now: now, calendar: calendar, timeText: timeText), action: .pause(choice))
            }
            control = [MenuEntry(title: "Pause stew", action: .none, submenu: choices)]
        case .startsAt: control = [MenuEntry(title: "Cancel pause", action: .resume)]
        case .until, .untilBack: control = [MenuEntry(title: "Resume stew", action: .resume)]
        }
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
    /// " | ": "-" for a separator, "(…)" around one that does nothing, "[N]" after a badge,
    /// and "▸ {a; b}" after one that opens a submenu.
    public func describe(now: Date = Date(), calendar: Calendar = .current, timeText: (Date) -> String) -> String {
        let icon = self.icon
        let header = "visible=\(isVisible) count=\(icon.count) dot=\(icon.updateDot) paused=\(icon.paused)"
        let lines = entries(now: now, calendar: calendar, timeText: timeText).map { entry -> String in
            if entry.isSeparator { return "-" }
            if entry.hasSubmenu { return "\(entry.title) ▸ {\(entry.submenu.map(\.title).joined(separator: "; "))}" }
            let title = entry.action == .none ? "(\(entry.title))" : entry.title
            return entry.badge.map { "\(title) [\($0)]" } ?? title
        }
        return ([header] + lines).joined(separator: " | ")
    }
}

public struct MenuEntry: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// A heading, a state line, or the parent of a submenu: does nothing by itself.
        case none
        case openNeeds(String)
        case pause(PauseChoice)
        case history, settings, setup, resume, update, hide
    }

    public var title: String
    public var action: Action
    /// A count at the trailing edge.
    public var badge: Int?
    public var toolTip: String?
    /// What the submenu this entry opens lists; empty for an entry without one.
    public var submenu: [MenuEntry]
    public var isSeparator = false

    public init(title: String, action: Action, badge: Int? = nil, toolTip: String? = nil, submenu: [MenuEntry] = []) {
        self.title = title
        self.action = action
        self.badge = badge
        self.toolTip = toolTip
        self.submenu = submenu
    }

    public var hasSubmenu: Bool { !submenu.isEmpty }

    /// Clickable: it does something, or opens a submenu.
    public var isEnabled: Bool { action != .none || hasSubmenu }

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
    /// A template image macOS tints, in place of the app icon's colors.
    public var monochrome: Bool

    public init(count: Int = 0, updateDot: Bool = false, paused: Bool = false, monochrome: Bool = false) {
        self.count = count
        self.updateDot = updateDot
        self.paused = paused
        self.monochrome = monochrome
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
        History.unseenMissedIDs(entries, seenAt: seenAt).count
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
    /// Accounts whose "Where did you hear about stew?" was sent or skipped on this Mac, so
    /// it never shows again for them.
    public var heardFromDone: [String]
    /// A reply to that question that did not reach the server yet.
    public var heardFromPending: HeardFromPending?

    public struct InstalledUpdate: Codable, Equatable, Sendable {
        public var version: String
        public var notes: String?

        public init(version: String, notes: String?) {
            self.version = version
            self.notes = notes
        }
    }

    public init(
        pause: PauseState? = nil, historySeenAt: Date? = nil, lastRunVersion: String? = nil, installedUpdate: InstalledUpdate? = nil, announcedVersions: [String] = [],
        heardFromDone: [String] = [], heardFromPending: HeardFromPending? = nil
    ) {
        self.pause = pause
        self.historySeenAt = historySeenAt
        self.lastRunVersion = lastRunVersion
        self.installedUpdate = installedUpdate
        self.announcedVersions = announcedVersions
        self.heardFromDone = heardFromDone
        self.heardFromPending = heardFromPending
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pause = try? container.decodeIfPresent(PauseState.self, forKey: .pause)
        historySeenAt = try? container.decodeIfPresent(Date.self, forKey: .historySeenAt)
        lastRunVersion = try? container.decodeIfPresent(String.self, forKey: .lastRunVersion)
        installedUpdate = try? container.decodeIfPresent(InstalledUpdate.self, forKey: .installedUpdate)
        announcedVersions = (try? container.decodeIfPresent([String].self, forKey: .announcedVersions)) ?? []
        heardFromDone = (try? container.decodeIfPresent([String].self, forKey: .heardFromDone)) ?? []
        heardFromPending = try? container.decodeIfPresent(HeardFromPending.self, forKey: .heardFromPending)
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
