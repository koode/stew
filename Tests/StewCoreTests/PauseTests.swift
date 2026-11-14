import Foundation
import Testing
@testable import StewCore

private let amsterdam: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
    return calendar
}()

/// A local time in Amsterdam.
private func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, second: Int = 0) -> Date {
    amsterdam.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
}

/// "14 08:00": the day of the month and the local time, to check where a pause ends.
private func dayAndTime(_ date: Date) -> String {
    let parts = amsterdam.dateComponents([.day, .hour, .minute], from: date)
    let minute = parts.minute! < 10 ? "0\(parts.minute!)" : "\(parts.minute!)"
    let hour = parts.hour! < 10 ? "0\(parts.hour!)" : "\(parts.hour!)"
    return "\(parts.day!) \(hour):\(minute)"
}

private let morning = PauseChoice.until(hour: 8, minute: 0)

@Suite struct PauseChoiceTests {
    @Test func beforeTheMorningHourPausesUntilItToday() {
        let end = morning.end(now: local(2026, 11, 14, 7, 30), calendar: amsterdam)
        #expect(end.map(dayAndTime) == "14 08:00")
    }

    @Test func afterTheMorningHourPausesUntilTomorrow() {
        let end = morning.end(now: local(2026, 11, 14, 9, 15), calendar: amsterdam)
        #expect(end.map(dayAndTime) == "15 08:00")
    }

    @Test func exactlyAtTheMorningHourPausesUntilTomorrow() {
        #expect(morning.end(now: local(2026, 11, 14, 8), calendar: amsterdam).map(dayAndTime) == "15 08:00")
        #expect(morning.end(now: local(2026, 11, 14, 7, 59, second: 59), calendar: amsterdam).map(dayAndTime) == "14 08:00")
    }

    @Test func clockChangesKeepTheLocalTime() {
        // The night the clocks go forward an hour: 8 hours from 23:00 to 08:00.
        let spring = local(2026, 3, 28, 23)
        let springEnd = morning.end(now: spring, calendar: amsterdam)
        #expect(springEnd.map(dayAndTime) == "29 08:00")
        #expect(springEnd.map { end in end.timeIntervalSince(spring).rounded() } == TimeInterval(8 * 3600))
        // The night they go back: 10 hours.
        let autumn = local(2026, 10, 24, 23)
        let autumnEnd = morning.end(now: autumn, calendar: amsterdam)
        #expect(autumnEnd.map(dayAndTime) == "25 08:00")
        #expect(autumnEnd.map { end in end.timeIntervalSince(autumn).rounded() } == TimeInterval(10 * 3600))
        // 02:30 does not exist that spring night: the first time after the gap.
        let skipped = PauseChoice.until(hour: 2, minute: 30).end(now: local(2026, 3, 29, 1), calendar: amsterdam)
        #expect(skipped.map(dayAndTime) == "29 03:00")
    }

    @Test func titles() {
        let now = local(2026, 11, 14, 14)
        let timeText = { (date: Date) in dayAndTime(date) }
        #expect(PauseChoice.menu(morningHour: 8).map { $0.title(now: now, calendar: amsterdam, timeText: timeText) }
            == ["For 1 hour", "For 2 hours", "Until 15 08:00", "Until I'm back"])
        #expect(PauseChoice.minutes(90).title(now: now, calendar: amsterdam, timeText: timeText) == "For 90 min")
        #expect(PauseChoice.minutes(180).title(now: now, calendar: amsterdam, timeText: timeText) == "For 3 hours")
    }

    @Test func pausingAgainKeepsWhenThePauseBegan() {
        let began = local(2026, 11, 14, 13)
        let now = local(2026, 11, 14, 14)
        let current = PauseState.starting(at: began, minutes: 120)
        let longer = PauseChoice.minutes(60).pause(now: now, calendar: amsterdam, current: current, screenLocked: false)
        #expect(longer == PauseState(since: began, until: now.addingTimeInterval(3600), ending: .afterMinutes))
        let tomorrow = morning.pause(now: now, calendar: amsterdam, current: current, screenLocked: false)
        #expect(tomorrow == PauseState(since: began, until: local(2026, 11, 15, 8), ending: .atTime))
        // A pause that ran out does not count.
        let fresh = morning.pause(now: now, calendar: amsterdam, current: PauseState.starting(at: began, minutes: 10), screenLocked: false)
        #expect(fresh.since == now)
    }

    @Test func untilBackBeginsAfterTheArmingDelay() {
        let now = local(2026, 11, 14, 14)
        let pause = PauseChoice.untilBack.pause(now: now, calendar: amsterdam, current: nil, screenLocked: false)
        #expect(pause == PauseState(since: now.addingTimeInterval(60), until: nil, ending: .whenBack, armsAt: now.addingTimeInterval(60)))
        // With the screen locked the user is already away.
        let locked = PauseChoice.untilBack.pause(now: now, calendar: amsterdam, current: nil, screenLocked: true)
        #expect(locked.armsAt == now)
        #expect(locked.isActive(now: now))
        // Already paused: it stays paused through the arming minute.
        let began = now.addingTimeInterval(-600)
        let switched = PauseChoice.untilBack.pause(now: now, calendar: amsterdam, current: PauseState.starting(at: began, minutes: 60), screenLocked: false, armingDelay: 5)
        #expect(switched.since == began)
        #expect(switched.armsAt == now.addingTimeInterval(5))
        #expect(switched.isActive(now: now))
        #expect(switched.display(now: now) == .untilBack)
    }
}

@Suite struct UntilBackTests {
    private let chosen = local(2026, 11, 14, 14)
    private var pause: PauseState { PauseChoice.untilBack.pause(now: chosen, calendar: amsterdam, current: nil, screenLocked: false) }
    private var armsAt: Date { chosen.addingTimeInterval(60) }

    @Test func pendingForTheFirstMinuteThenPaused() {
        #expect(pause.isPending(now: chosen))
        #expect(!pause.isActive(now: chosen.addingTimeInterval(59)))
        #expect(pause.display(now: chosen.addingTimeInterval(15)) == .startsAt(armsAt))
        #expect(pause.isActive(now: armsAt))
        #expect(!pause.isPending(now: armsAt))
        #expect(pause.display(now: armsAt) == .untilBack)
        // It never ends by the clock.
        #expect(!pause.hasEnded(now: chosen.addingTimeInterval(7 * 24 * 3600)))
    }

    @Test func inputInTheArmingMinuteDoesNotEndIt() {
        #expect(!pause.userIsBack(now: chosen.addingTimeInterval(10), idleSeconds: 0, screenLocked: false))
        #expect(!pause.userIsBack(now: chosen.addingTimeInterval(59), idleSeconds: 0, screenLocked: false))
        // The first sample after it armed sees input from before: still away.
        #expect(!pause.userIsBack(now: armsAt.addingTimeInterval(2), idleSeconds: 30, screenLocked: false))
        #expect(!pause.userIsBack(now: armsAt.addingTimeInterval(2), idleSeconds: 2, screenLocked: false))
    }

    @Test func inputAfterItArmedEndsIt() {
        #expect(pause.userIsBack(now: armsAt.addingTimeInterval(2), idleSeconds: 1, screenLocked: false))
        #expect(pause.userIsBack(now: armsAt.addingTimeInterval(3600), idleSeconds: 0.5, screenLocked: false))
        #expect(!pause.userIsBack(now: armsAt.addingTimeInterval(3600), idleSeconds: 3601, screenLocked: false))
    }

    @Test func aLockedScreenMeansAway() {
        #expect(!pause.userIsBack(now: armsAt.addingTimeInterval(600), idleSeconds: 0, screenLocked: true))
    }

    @Test func lockingInTheArmingMinuteBeginsItAtOnce() {
        let lockedAt = chosen.addingTimeInterval(20)
        let locked = pause.lockingScreen(at: lockedAt)
        #expect(locked.armsAt == lockedAt)
        #expect(locked.since == lockedAt)
        #expect(locked.isActive(now: lockedAt))
        #expect(locked.endsOnUnlock(at: lockedAt.addingTimeInterval(5)))
        // Once armed, locking changes nothing.
        #expect(pause.lockingScreen(at: armsAt.addingTimeInterval(5)) == pause)
    }

    @Test func unlockingEndsItOnlyOnceArmed() {
        #expect(!pause.endsOnUnlock(at: chosen.addingTimeInterval(30)))
        #expect(pause.endsOnUnlock(at: armsAt))
        #expect(!PauseState.starting(at: chosen, minutes: 60).endsOnUnlock(at: chosen.addingTimeInterval(120)))
        #expect(!PauseState.starting(at: chosen, minutes: 60).userIsBack(now: chosen.addingTimeInterval(120), idleSeconds: 0, screenLocked: false))
    }

    @Test func countdown() {
        #expect(PauseDisplay.countdown(to: armsAt, now: chosen) == "1:00")
        #expect(PauseDisplay.countdown(to: armsAt, now: chosen.addingTimeInterval(15)) == "0:45")
        #expect(PauseDisplay.countdown(to: armsAt, now: chosen.addingTimeInterval(59.8)) == "0:01")
        #expect(PauseDisplay.countdown(to: armsAt, now: armsAt.addingTimeInterval(3)) == "0:00")
        #expect(PauseDisplay.startsAt(armsAt).title(now: chosen.addingTimeInterval(15), timeText: { _ in "" }) == "Pausing in 0:45…")
        #expect(PauseDisplay.untilBack.title(now: chosen, timeText: { _ in "" }) == "Paused until you're back")
        #expect(PauseDisplay.until(armsAt).title(now: chosen, timeText: { _ in "15:40" }) == "Paused until 15:40")
    }
}

@Suite struct PauseNoteTests {
    private let now = local(2026, 11, 14, 14)
    private let request = StewRequest(
        session: SessionInfo(name: "release job", id: "aaaa-1111", cwd: "~/code/app"),
        prompt: .permission(PermissionRequest(action: "Push", reason: "ship it"))
    )

    @Test func saysWhenStewResumes() {
        let timeText = { (date: Date) in dayAndTime(date) }
        #expect(PauseState.starting(at: now, minutes: 42).resumesText(now: now, timeText: timeText) == "in about 42 min")
        let untilMorning = morning.pause(now: now, calendar: amsterdam, current: nil, screenLocked: false)
        #expect(untilMorning.resumesText(now: now, timeText: timeText) == "at 15 08:00")
        let untilBack = PauseChoice.untilBack.pause(now: now, calendar: amsterdam, current: nil, screenLocked: true)
        let resumes = untilBack.resumesText(now: now, timeText: timeText)
        #expect(resumes == "when the user is back")
        #expect(request.pausedNote(resumes: resumes).contains("or ask again after stew resumes when the user is back. If they answer later"))
    }

    @Test func endTextNamesTomorrow() {
        let time = { (date: Date) in dayAndTime(date) }
        let dateAndTime = { (_: Date) in "dated" }
        #expect(PauseState.endText(local(2026, 11, 14, 23, 59), now: now, calendar: amsterdam, time: time, dateAndTime: dateAndTime) == "14 23:59")
        #expect(PauseState.endText(local(2026, 11, 15, 8), now: now, calendar: amsterdam, time: time, dateAndTime: dateAndTime) == "15 08:00 tomorrow")
        #expect(PauseState.endText(local(2026, 11, 16, 8), now: now, calendar: amsterdam, time: time, dateAndTime: dateAndTime) == "dated")
    }
}

@Suite struct PauseStateCodingTests {
    private func decode(_ json: String) -> PauseState? {
        DaemonState.decode(Data(#"{"pause":\#(json)}"#.utf8)).pause
    }

    @Test func readsTheFormatBeforePauseKinds() {
        let pause = decode(#"{"since":"2026-11-14T13:00:00Z","until":"2026-11-14T14:00:00Z"}"#)
        #expect(pause == PauseState(since: Date(timeIntervalSince1970: 1_794_661_200), until: Date(timeIntervalSince1970: 1_794_664_800)))
        #expect(pause?.ending == .afterMinutes)
    }

    @Test func roundTripsEveryKind() throws {
        let now = local(2026, 11, 14, 14)
        for choice in [PauseChoice.minutes(30), morning, .untilBack] {
            let state = DaemonState(pause: choice.pause(now: now, calendar: amsterdam, current: nil, screenLocked: false))
            #expect(DaemonState.decode(try state.encoded()) == state)
        }
        let encoded = String(decoding: try DaemonState(pause: PauseChoice.untilBack.pause(now: now, calendar: amsterdam, current: nil, screenLocked: false)).encoded(), as: UTF8.self)
        #expect(!encoded.contains("until\""))
        #expect(encoded.contains(#""ending" : "whenBack""#))
    }

    @Test func refusesAPauseWithoutAnEnd() {
        #expect(decode(#"{"since":"2026-11-14T13:00:00Z"}"#) == nil)
        #expect(decode(#"{"since":"2026-11-14T13:00:00Z","ending":"atTime"}"#) == nil)
        #expect(decode(#"{"since":"2026-11-14T13:00:00Z","until":"2026-11-14T14:00:00Z","ending":"someday"}"#) == nil)
        // A pause until the user is back without armsAt arms when it began.
        let back = decode(#"{"since":"2026-11-14T13:00:00Z","ending":"whenBack"}"#)
        #expect(back?.armsAt == back?.since)
    }
}

@Suite struct PauseCommandLineTests {
    private func parse(_ positional: [String] = [], until: String? = nil, untilBack: Bool = false) throws -> PauseChoice {
        try PauseChoice.parse(positional: positional, until: until, untilBack: untilBack)
    }

    @Test func oneOfTheThree() throws {
        #expect(try parse() == .minutes(60))
        #expect(try parse(["15"]) == .minutes(15))
        #expect(try parse(until: "08:00") == .until(hour: 8, minute: 0))
        #expect(try parse(until: "7:05") == .until(hour: 7, minute: 5))
        #expect(try parse(until: "23:59") == .until(hour: 23, minute: 59))
        #expect(try parse(until: "20:30") == .until(hour: 20, minute: 30))
        #expect(try parse(untilBack: true) == .untilBack)
    }

    @Test func twelveHourTimes() throws {
        let accepted: [(String, Int, Int)] = [
            ("8am", 8, 0), ("8 am", 8, 0), ("8AM", 8, 0), ("08am", 8, 0), ("8:30pm", 20, 30), ("8:30 PM", 20, 30),
            ("12am", 0, 0), ("12:15am", 0, 15), ("12pm", 12, 0), ("12:45 pm", 12, 45), ("1pm", 13, 0), ("11:59pm", 23, 59),
        ]
        for (text, hour, minute) in accepted {
            #expect(try parse(until: text) == .until(hour: hour, minute: minute), "\(text)")
        }
        // `--until 8 am` without quotes.
        #expect(try parse(["am"], until: "8") == .until(hour: 8, minute: 0))
        #expect(try parse(["PM"], until: "8:30") == .until(hour: 20, minute: 30))
    }

    @Test func refusesMoreThanOneOrBadValues() {
        #expect(throws: PauseChoice.UsageError(description: "pause takes MINUTES, --until HH:MM or --until-back, only one of them")) {
            try parse(["30"], untilBack: true)
        }
        #expect(throws: PauseChoice.UsageError.self) { try parse(until: "08:00", untilBack: true) }
        #expect(throws: PauseChoice.UsageError(description: "pause takes one number of minutes")) { try parse(["1", "2"]) }
        #expect(throws: PauseChoice.UsageError(description: "pause takes a whole number of minutes from 1 to 1440")) { try parse(["0"]) }
        let refusedTimes = [
            "24:00", "25:00", "8", "08:0", "8:60", "08:60", "ab:cd", " 8:00", "08:00:00", "-1:00", "+8:00", "٠٨:٠٠", "",
            "13pm", "0am", "00:30am", "8:5pm", "8  am", "8.30pm", "pm", "8 a.m.", "20:30pm",
        ]
        for refused in refusedTimes {
            #expect(throws: PauseChoice.UsageError(description: PauseChoice.untilForms), "\(refused)") { try parse(until: refused) }
        }
        #expect(PauseChoice.untilForms == "--until takes a local time: 08:00, 8:00, 20:30, 8am, 8 am, 8:30pm, 12am (midnight) or 12pm (noon)")
    }

    @Test func timesFollowTheLocaleClock() {
        let evening = local(2026, 11, 14, 20, 30)
        let amsterdamZone = amsterdam.timeZone
        #expect(PauseState.timeOfDay(evening, locale: Locale(identifier: "nl_NL"), timeZone: amsterdamZone) == "20:30")
        #expect(PauseState.timeOfDay(evening, locale: Locale(identifier: "en_US"), timeZone: amsterdamZone).hasPrefix("8:30"))
        #expect(PauseState.timeOfDay(evening, locale: Locale(identifier: "en_US"), timeZone: amsterdamZone).hasSuffix("PM"))
    }

    @Test func controlLineRoundTrips() {
        for choice in [PauseChoice.minutes(45), .until(hour: 7, minute: 5), .untilBack] {
            #expect(PauseChoice(controlArgument: choice.controlArgument) == choice)
        }
        #expect(PauseChoice.until(hour: 7, minute: 5).controlArgument == "until 07:05")
        #expect(PauseChoice(controlArgument: "60") == .minutes(60))
        #expect(PauseChoice(controlArgument: "soon") == nil)
        #expect(PauseChoice(controlArgument: "until 25:00") == nil)
    }

    @Test func morningHourComesFromTheConfig() throws {
        #expect(StewConfig().pauseMorningHour == 8)
        #expect(try JSONDecoder().decode(StewConfig.self, from: Data(#"{"pauseMorningHour":6}"#.utf8)).pauseMorningHour == 6)
        #expect(try JSONDecoder().decode(StewConfig.self, from: Data(#"{"pauseMorningHour":31}"#.utf8)).pauseMorningHour == 8)
    }
}
