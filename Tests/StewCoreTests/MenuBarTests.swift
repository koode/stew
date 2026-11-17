import Foundation
import Testing
@testable import StewCore

private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let session = SessionInfo(name: "release job", id: "aaaa-1111", cwd: "~/code/app")

private func request(_ prompt: Prompt, in requestSession: SessionInfo = session) -> StewRequest {
    StewRequest(session: requestSession, prompt: prompt)
}

private let permission = Prompt.permission(PermissionRequest(action: "Push", reason: "ship it"))
private let question = Prompt.question(QuestionSet(questions: [Question(
    question: "Ship?", header: "Ship", options: [QuestionOption(label: "Yes", description: ""), QuestionOption(label: "No", description: "")]
)]))

private func entry(_ outcome: HistoryEntry.Outcome, minutesAfterStart minutes: Double, late: Bool = false) -> HistoryEntry {
    let ended = start.addingTimeInterval(minutes * 60)
    return HistoryEntry(
        received: ended, ended: ended, session: "job", cwd: nil, kind: "permission", summary: "x", command: nil, detail: nil,
        outcome: outcome, late: late ? LateOutcome(answered: ended, outcome: .approved, message: "approved late") : nil
    )
}

@Suite struct PauseTests {
    @Test func endsByItself() {
        let pause = PauseState.starting(at: start, minutes: 60)
        #expect(pause.isActive(now: start))
        #expect(pause.isActive(now: start.addingTimeInterval(59 * 60 + 59)))
        #expect(!pause.isActive(now: start.addingTimeInterval(60 * 60)))
        #expect(!pause.isActive(now: start.addingTimeInterval(2 * 60 * 60)))
    }

    @Test func remainingMinutesRoundUp() {
        let pause = PauseState.starting(at: start, minutes: 60)
        #expect(pause.remainingMinutes(now: start) == 60)
        #expect(pause.remainingMinutes(now: start.addingTimeInterval(30)) == 60)
        #expect(pause.remainingMinutes(now: start.addingTimeInterval(59 * 60 + 50)) == 1)
    }

    @Test func onlyRequestsThatNeedAnAnswerNowTimeOut() {
        #expect(PauseState.timesOut(permission))
        #expect(PauseState.timesOut(question))
        #expect(PauseState.timesOut(.input(InputRequest(question: "Domain?"))))
        #expect(!PauseState.timesOut(.notify(NotifyRequest(title: "Done"))))
        #expect(!PauseState.timesOut(.needs(NeedsRequest(title: "Log in"))))
    }

    @Test func minutesFromTheCommandLine() throws {
        #expect(try PauseState.minutes(from: nil) == 60)
        #expect(try PauseState.minutes(from: "15") == 15)
        #expect(try PauseState.minutes(from: "1440") == 1440)
        for refused in ["0", "-5", "1441", "1.5", "soon", ""] {
            #expect(throws: PauseState.MinutesError.self) { try PauseState.minutes(from: refused) }
        }
    }

    @Test func noteTellsClaudeTheUserIsAway() {
        let note = request(permission).pausedNote(resumes: "in about 42 min")
        #expect(note == "The user paused stew and is away, so nobody saw this request. Treat it as denied and continue another way, or ask again after stew resumes in about 42 min. If they answer later, stew passes their answer on to you as a late answer, which replaces this timeout.")
        let questionNote = request(question).pausedNote(resumes: "in about 5 min")
        #expect(questionNote.hasPrefix("The user paused stew and is away, so nobody saw this request. Continue with a safe choice"))
        #expect(questionNote.contains("in about 5 min."))
    }

    @Test func noteOffersNoLateAnswerWithoutASession() {
        let note = request(permission, in: SessionInfo(name: "script")).pausedNote(resumes: "in about 10 min")
        #expect(!note.contains("late answer"))
    }
}

@Suite struct MenuBarStateTests {
    private let needs = [
        NeedsItem(id: "a1", created: start, session: session, needs: NeedsRequest(title: "Log in to npm")),
        NeedsItem(id: "b2", created: start, session: session, needs: NeedsRequest(title: "Plug in the key")),
    ]

    private func titles(_ state: MenuBarState) -> [String] {
        state.entries(timeText: { _ in "15:40" }).map { $0.isSeparator ? "-" : $0.title }
    }

    @Test func badgeCountsNeedsAndUnseenMissed() {
        let state = MenuBarState(openNeeds: needs, missedCount: 3)
        #expect(state.badgeCount == 5)
        #expect(state.icon == MenuBarIcon(count: 5, updateDot: false, paused: false))
        #expect(MenuBarState().icon.countText == nil)
        #expect(MenuBarIcon(count: 7).countText == "7")
        #expect(MenuBarIcon(count: 120).countText == "99+")
    }

    @Test func unseenMissedCountsOnlyAfterHistoryWasOpened() {
        let entries = [
            entry(.timedOut, minutesAfterStart: -10),
            entry(.timedOut, minutesAfterStart: 5),
            entry(.later, minutesAfterStart: 6),
            entry(.timedOut, minutesAfterStart: 7, late: true),
            entry(.approved, minutesAfterStart: 8),
            entry(.dismissed, minutesAfterStart: 9),
        ]
        #expect(MenuBarBadge.unseenMissed(entries, seenAt: start) == 2)
        #expect(MenuBarBadge.unseenMissed(entries, seenAt: nil) == 3)
        #expect(MenuBarBadge.unseenMissed(entries, seenAt: start.addingTimeInterval(60 * 60)) == 0)
    }

    @Test func iconShowsPauseAndUpdate() {
        let state = MenuBarState(pause: .until(start), update: .ready("0.2.0"))
        #expect(state.icon == MenuBarIcon(count: 0, updateDot: true, paused: true))
    }

    @Test func visibleWhenSetOrWhileSomethingNeedsTheUser() {
        #expect(MenuBarState().isVisible)
        #expect(!MenuBarState(showsAlways: false).isVisible)
        #expect(!MenuBarState(missedCount: 2, showsAlways: false).isVisible)
        #expect(MenuBarState(openNeeds: needs, showsAlways: false).isVisible)
    }

    @Test func plainMenu() {
        #expect(titles(MenuBarState()) == ["History…", "Settings…", "Set up stew…", "-", "Pause stew", "-", "Hide menu bar icon"])
    }

    @Test func pauseSubmenuListsTheChoices() throws {
        var amsterdam = Calendar(identifier: .gregorian)
        amsterdam.timeZone = try #require(TimeZone(identifier: "Europe/Amsterdam"))
        // 2026-11-14 14:00 in Amsterdam: the morning hour is tomorrow.
        let afternoon = Date(timeIntervalSince1970: 1_794_661_200)
        let entries = MenuBarState(morningHour: 7).entries(now: afternoon, calendar: amsterdam) { date in
            amsterdam.component(.day, from: date) == 14 ? "today" : "tomorrow"
        }
        let pause = try #require(entries.first { $0.title == "Pause stew" })
        #expect(pause.isEnabled)
        #expect(pause.action == MenuEntry.Action.none)
        #expect(pause.submenu.map(\.title) == ["For 1 hour", "For 2 hours", "Until tomorrow", "Until I'm back"])
        #expect(pause.submenu.map(\.action) == [.pause(.minutes(60)), .pause(.minutes(120)), .pause(.until(hour: 7, minute: 0)), .pause(.untilBack)])
        #expect(MenuBarState(morningHour: 7).pauseChoices == pause.submenu.compactMap { entry in
            if case .pause(let choice) = entry.action { return choice } else { return nil }
        })
    }

    @Test func untilBackShowsTheCountdownThenThePause() {
        let starting = MenuBarState(pause: .startsAt(start.addingTimeInterval(45)))
        let startingTitles = starting.entries(now: start, timeText: { _ in "15:40" }).map { $0.isSeparator ? "-" : $0.title }
        #expect(startingTitles == ["Pausing in 0:45…", "-", "History…", "Settings…", "Set up stew…", "-", "Cancel pause", "-", "Hide menu bar icon"])
        #expect(!starting.icon.paused)
        let paused = MenuBarState(pause: .untilBack)
        #expect(titles(paused) == ["Paused until you're back", "-", "History…", "Settings…", "Set up stew…", "-", "Resume stew", "-", "Hide menu bar icon"])
        #expect(paused.icon.paused)
        #expect(paused.entries(timeText: { _ in "" }).first { $0.title == "Resume stew" }?.action == .resume)
    }

    @Test func describeSpellsOutTheSubmenu() {
        let line = MenuBarState().describe(now: start, timeText: { _ in "08:00" })
        #expect(line.contains("| Pause stew ▸ {For 1 hour; For 2 hours; Until 08:00; Until I'm back} |"))
    }

    @Test func fullMenu() {
        let state = MenuBarState(openNeeds: needs, missedCount: 2, pause: .until(start), update: .ready("0.2.0"))
        #expect(titles(state) == [
            "Paused until 15:40", "-",
            "2 things need you", "release job · Log in to npm", "release job · Plug in the key", "-",
            "History…", "Settings…", "Set up stew…", "-",
            "Resume stew", "stew 0.2.0 is ready, restart to update", "-",
            "Hide menu bar icon",
        ])
        let entries = state.entries(timeText: { _ in "15:40" })
        #expect(entries.first(where: { $0.title == "History…" })?.badge == 2)
        #expect(entries.first(where: { $0.title == "release job · Log in to npm" })?.action == .openNeeds("a1"))
        #expect(entries.first?.action == MenuEntry.Action.none)
    }

    @Test func updateEntryFollowsTheRoute() {
        func updateTitle(_ update: MenuBarState.Update) -> String? {
            titles(MenuBarState(update: update)).first { $0.hasPrefix("stew 0.2.0") }
        }
        #expect(updateTitle(.available("0.2.0")) == "stew 0.2.0 is available, install now")
        #expect(updateTitle(.homebrew("0.2.0")) == "stew 0.2.0 is available, copy the brew command")
        #expect(updateTitle(.manual("0.2.0")) == "stew 0.2.0 is available, see Settings")
        #expect(UpdateNotice.menuEntry("0.2.0", route: .inPlace) == .available("0.2.0"))
        #expect(UpdateNotice.menuEntry("0.2.0", route: .homebrew) == .homebrew("0.2.0"))
        #expect(UpdateNotice.menuEntry("0.2.0", route: .notWritable(folder: "/Applications")) == .manual("0.2.0"))
    }

    @Test func noHideEntryWhenTheSettingIsOff() {
        #expect(!titles(MenuBarState(openNeeds: needs, showsAlways: false)).contains("Hide menu bar icon"))
    }
}

@Suite struct DaemonStateTests {
    @Test func menuBarDefaultsOnAndDecodes() throws {
        #expect(StewConfig().menuBar)
        #expect(try JSONDecoder().decode(StewConfig.self, from: Data("{}".utf8)).menuBar)
        #expect(try !JSONDecoder().decode(StewConfig.self, from: Data(#"{"menuBar":false}"#.utf8)).menuBar)
    }

    @Test func iconStyleDefaultsToColorAndDecodes() throws {
        func style(_ json: String) throws -> String {
            try JSONDecoder().decode(StewConfig.self, from: Data(json.utf8)).menuBarIcon
        }
        #expect(StewConfig().menuBarIcon == MenuBarIconStyle.color)
        #expect(try style("{}") == "color")
        #expect(try style(#"{"menuBarIcon":"color"}"#) == "color")
        #expect(try style(#"{"menuBarIcon":"monochrome"}"#) == "monochrome")
        #expect(try style(#"{"menuBarIcon":"neon"}"#) == "color")
        #expect(!MenuBarState().icon.monochrome)
        #expect(MenuBarState(missedCount: 2, monochromeIcon: true).icon == MenuBarIcon(count: 2, monochrome: true))
    }

    @Test func roundTripsAndToleratesDamage() throws {
        let state = DaemonState(
            pause: PauseState.starting(at: start, minutes: 30), historySeenAt: start, lastRunVersion: "0.1.0",
            installedUpdate: DaemonState.InstalledUpdate(version: "0.2.0", notes: "https://stewcli.com/changelog#0.2.0"),
            announcedVersions: ["0.2.0"]
        )
        #expect(DaemonState.decode(try state.encoded()) == state)
        #expect(DaemonState.decode(Data("not json".utf8)) == DaemonState())
        let partial = DaemonState.decode(Data(#"{"lastRunVersion":"0.1.0","pause":{"since":3}}"#.utf8))
        #expect(partial.lastRunVersion == "0.1.0")
        #expect(partial.pause == nil)
    }
}

@Suite struct UpdateNoticeTests {
    @Test func announcesANewerVersionOnce() {
        let installed = DaemonState.InstalledUpdate(version: "0.2.0", notes: "https://stewcli.com/changelog#0.2.0")
        let notice = UpdateNotice.afterStart(DaemonState(lastRunVersion: "0.1.0", installedUpdate: installed), running: "0.2.0")
        #expect(notice?.title == "stew updated to 0.2.0")
        #expect(notice?.link == NotifyLink(title: "What's new", url: "https://stewcli.com/changelog#0.2.0"))
        #expect(notice?.action == nil)
        // The same version again, or an older one: nothing.
        #expect(UpdateNotice.afterStart(DaemonState(lastRunVersion: "0.2.0"), running: "0.2.0") == nil)
        #expect(UpdateNotice.afterStart(DaemonState(lastRunVersion: "0.3.0"), running: "0.2.0") == nil)
        // A first start ever: nothing to compare with.
        #expect(UpdateNotice.afterStart(DaemonState(), running: "0.2.0") == nil)
    }

    @Test func linksOnlyToWebNotesOfThisVersion() {
        func link(_ notes: String?, version: String = "0.2.0") -> NotifyLink? {
            let state = DaemonState(lastRunVersion: "0.1.0", installedUpdate: DaemonState.InstalledUpdate(version: version, notes: notes))
            return UpdateNotice.afterStart(state, running: "0.2.0")?.link
        }
        #expect(link(nil) == nil)
        #expect(link("Faster panels and a menu bar item") == nil)
        #expect(link("file:///etc/passwd") == nil)
        #expect(link("https://stewcli.com/changelog", version: "0.1.5") == nil)
        #expect(link("https://stewcli.com/changelog")?.url == "https://stewcli.com/changelog")
        // An update from another installer (a new cask, the install script): no notes.
        #expect(UpdateNotice.afterStart(DaemonState(lastRunVersion: "0.1.0"), running: "0.2.0")?.link == nil)
    }

    @Test func availableOncePerVersionAndByRoute() {
        let notice = UpdateNotice.available("0.2.0", route: .inPlace, state: DaemonState())
        #expect(notice?.title == "stew 0.2.0 is available")
        #expect(notice?.action == .installUpdate)
        #expect(UpdateNotice.available("0.2.0", route: .inPlace, state: DaemonState(announcedVersions: ["0.2.0"])) == nil)
        let brew = UpdateNotice.available("0.2.0", route: .homebrew, state: DaemonState())
        #expect(brew?.action == nil)
        #expect(brew?.body == "Update it with Homebrew: brew upgrade --cask stew")
        let folder = UpdateNotice.available("0.2.0", route: .notWritable(folder: "/Applications"), state: DaemonState())
        #expect(folder?.body?.contains("/Applications") == true)
        #expect(folder?.action == nil)
    }
}
