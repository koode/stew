import Foundation

/// stew paused by the user, who is away. Requests that need an answer now time out at
/// once with a note saying so; notifications and needs items still arrive. A pause ends
/// at its time, or, for a pause until the user is back, when they use the Mac again.
public struct PauseState: Codable, Equatable, Sendable {
    /// How the pause ends.
    public enum Ending: String, Codable, Sendable {
        /// After a number of minutes: For 1 hour, `stew pause MINUTES`.
        case afterMinutes
        /// At a time of day: Until 08:00, `stew pause --until HH:MM`.
        case atTime
        /// When the user is back at the Mac: Until I'm back, `stew pause --until-back`.
        case whenBack
    }

    /// When the pause began. A pause until the user is back that has not armed yet
    /// begins in the future, when it arms.
    public var since: Date
    /// When the pause ends by itself. Nil for a pause until the user is back.
    public var until: Date?
    public var ending: Ending
    /// For a pause until the user is back: input before this moment does not end it, so
    /// moving the mouse right after choosing it does not.
    public var armsAt: Date?

    public init(since: Date, until: Date) {
        self.init(since: since, until: until, ending: .afterMinutes)
    }

    public init(since: Date, until: Date?, ending: Ending, armsAt: Date? = nil) {
        self.since = since
        self.until = until
        self.ending = ending
        self.armsAt = armsAt
    }

    /// A file written before pauses had kinds holds only `since` and `until`: a pause
    /// for some minutes. Only a pause until the user is back may lack `until`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        since = try container.decode(Date.self, forKey: .since)
        until = try container.decodeIfPresent(Date.self, forKey: .until)
        ending = try container.decodeIfPresent(Ending.self, forKey: .ending) ?? .afterMinutes
        armsAt = try container.decodeIfPresent(Date.self, forKey: .armsAt)
        if ending == .whenBack {
            armsAt = armsAt ?? since
        } else if until == nil {
            throw DecodingError.dataCorruptedError(forKey: .until, in: container, debugDescription: "a pause that ends at a time needs until")
        }
    }

    /// For 1 hour, and `stew pause` without a number.
    public static let defaultMinutes = 60
    /// Longest pause `stew pause MINUTES` accepts: a day.
    public static let maximumMinutes = 24 * 60
    /// How long a pause until the user is back waits before it watches for them.
    public static let armingDelay: TimeInterval = 60

    public static func starting(at now: Date, minutes: Int) -> PauseState {
        PauseState(since: now, until: now.addingTimeInterval(Double(minutes) * 60))
    }

    /// Paused now: requests that need an answer time out at once.
    public func isActive(now: Date) -> Bool {
        switch ending {
        case .whenBack: now >= since
        case .afterMinutes, .atTime: until.map { now < $0 } ?? false
        }
    }

    /// Chosen and not begun yet: a pause until the user is back, in its first minute.
    public func isPending(now: Date) -> Bool {
        ending == .whenBack && now < since
    }

    /// Past its end. A pause until the user is back never ends by the clock.
    public func hasEnded(now: Date) -> Bool {
        until.map { now >= $0 } ?? false
    }

    /// Whole minutes left, rounded up, so the last seconds still read "1 min".
    public func remainingMinutes(now: Date) -> Int {
        max(1, Int(((until ?? now).timeIntervalSince(now) / 60).rounded(.up)))
    }

    /// For a pause until the user is back: true once they used the keyboard or mouse
    /// after it armed, with the screen unlocked. `idleSeconds` is the time since the
    /// last input event.
    public func userIsBack(now: Date, idleSeconds: TimeInterval, screenLocked: Bool) -> Bool {
        guard ending == .whenBack, let armsAt, !screenLocked, now >= armsAt else { return false }
        return idleSeconds < now.timeIntervalSince(armsAt)
    }

    /// Locking the screen says the user is leaving: a pause until they are back that is
    /// still arming arms, and begins, at once.
    public func lockingScreen(at now: Date) -> PauseState {
        guard ending == .whenBack, let armsAt, now < armsAt else { return self }
        var locked = self
        locked.armsAt = now
        locked.since = min(since, now)
        return locked
    }

    /// Unlocking the screen is the user coming back, once the pause has armed.
    public func endsOnUnlock(at now: Date) -> Bool {
        guard ending == .whenBack, let armsAt else { return false }
        return now >= armsAt
    }

    /// What the menu bar shows for this pause at `now`; nil once it has ended.
    public func display(now: Date) -> PauseDisplay? {
        if hasEnded(now: now) { return nil }
        if isPending(now: now) { return .startsAt(since) }
        if ending == .whenBack { return .untilBack }
        return until.map(PauseDisplay.until)
    }

    /// When stew resumes, for the note Claude reads: "in about 42 min", "at 08:00",
    /// "when the user is back". `timeText` formats a time of day as `PauseState.endText`.
    public func resumesText(now: Date, timeText: (Date) -> String) -> String {
        switch ending {
        case .afterMinutes: "in about \(remainingMinutes(now: now)) min"
        case .atTime: "at \(until.map(timeText) ?? "")"
        case .whenBack: "when the user is back"
        }
    }

    /// The end of a pause, in one form everywhere: the time alone today ("08:00"),
    /// "08:00 tomorrow" for tomorrow, else the date and time.
    public static func endText(_ date: Date, now: Date, calendar: Calendar, time: (Date) -> String, dateAndTime: (Date) -> String) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return time(date) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "\(time(date)) tomorrow"
        }
        return dateAndTime(date)
    }

    /// A time of day as the user's clock shows it: "08:00" or "8:00 AM", following the
    /// locale and its 12- or 24-hour setting.
    public static func timeOfDay(_ date: Date, locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.locale = locale
        style.timeZone = timeZone
        return date.formatted(style)
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

/// A pause as the menu bar and the settings window show it.
public enum PauseDisplay: Equatable, Sendable {
    /// Paused until a time.
    case until(Date)
    /// Paused until the user is back at the Mac.
    case untilBack
    /// Until I'm back was chosen; the pause begins at this moment.
    case startsAt(Date)

    /// Requests time out at once: everything but the minute before a pause begins.
    public var isPaused: Bool {
        if case .startsAt = self { return false }
        return true
    }

    /// The state line: "Paused until 15:40", "Paused until you're back", "Pausing in 0:45…".
    public func title(now: Date, timeText: (Date) -> String) -> String {
        switch self {
        case .until(let date): "Paused until \(timeText(date))"
        case .untilBack: "Paused until you're back"
        case .startsAt(let date): "Pausing in \(Self.countdown(to: date, now: now))…"
        }
    }

    /// Minutes and seconds left, rounded up: "0:45", "1:00".
    public static func countdown(to date: Date, now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now).rounded(.up)))
        let paddedSeconds = seconds % 60 < 10 ? "0\(seconds % 60)" : "\(seconds % 60)"
        return "\(seconds / 60):\(paddedSeconds)"
    }
}

/// One way to pause stew, as the menu bar's Pause stew submenu, the settings window and
/// `stew pause` offer it.
public enum PauseChoice: Equatable, Hashable, Sendable {
    /// For 1 hour, For 2 hours, `stew pause MINUTES`.
    case minutes(Int)
    /// Until the next time the clock shows this local time: Until 08:00, `--until HH:MM`.
    case until(hour: Int, minute: Int)
    /// Until I'm back, `--until-back`.
    case untilBack

    /// The hour the morning choice, Until 08:00, ends at when config.json sets none.
    public static let defaultMorningHour = 8

    /// The Pause stew submenu, top to bottom: an hour, two hours, until the morning hour,
    /// until the user is back.
    public static func menu(morningHour: Int) -> [PauseChoice] {
        [.minutes(60), .minutes(120), .until(hour: morningHour, minute: 0), .untilBack]
    }

    /// The entry's title at `now`: "For 1 hour", "Until 08:00", "Until 08:00 tomorrow",
    /// "Until I'm back". `timeText` formats the end as `PauseState.endText` does.
    public func title(now: Date, calendar: Calendar, timeText: (Date) -> String) -> String {
        switch self {
        case .minutes(let minutes) where minutes == 60: "For 1 hour"
        case .minutes(let minutes) where minutes % 60 == 0: "For \(minutes / 60) hours"
        case .minutes(let minutes): "For \(minutes) min"
        case .until: "Until \(end(now: now, calendar: calendar).map(timeText) ?? "")"
        case .untilBack: "Until I'm back"
        }
    }

    /// When a pause chosen at `now` ends by itself; nil for until the user is back.
    public func end(now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .minutes(let minutes): now.addingTimeInterval(Double(minutes) * 60)
        case .until(let hour, let minute): Self.nextOccurrence(hour: hour, minute: minute, after: now, calendar: calendar)
        case .untilBack: nil
        }
    }

    /// The next moment after `now` the clock shows `hour:minute`: today while that is
    /// still ahead, else tomorrow. On a day a clock change skips that time, the first
    /// time after the gap.
    public static func nextOccurrence(hour: Int, minute: Int, after now: Date, calendar: Calendar) -> Date {
        let wanted = DateComponents(hour: hour, minute: minute, second: 0)
        return calendar.nextDate(after: now, matching: wanted, matchingPolicy: .nextTime) ?? now.addingTimeInterval(24 * 60 * 60)
    }

    /// The pause this choice starts at `now`. Pausing again while paused keeps when the
    /// pause began, for the summary on Resume. Until the user is back begins after
    /// `armingDelay`, or at once while the screen is locked.
    public func pause(now: Date, calendar: Calendar, current: PauseState?, screenLocked: Bool, armingDelay: TimeInterval = PauseState.armingDelay) -> PauseState {
        let pausedSince = current.flatMap { $0.isActive(now: now) ? $0.since : nil }
        switch self {
        case .minutes:
            return PauseState(since: pausedSince ?? now, until: end(now: now, calendar: calendar), ending: .afterMinutes)
        case .until:
            return PauseState(since: pausedSince ?? now, until: end(now: now, calendar: calendar), ending: .atTime)
        case .untilBack:
            let armsAt = screenLocked ? now : now.addingTimeInterval(armingDelay)
            return PauseState(since: pausedSince ?? armsAt, until: nil, ending: .whenBack, armsAt: armsAt)
        }
    }

    /// The words after "pause " on the control line from `stew pause` to the daemon:
    /// "60", "until 08:00", "back".
    public var controlArgument: String {
        switch self {
        case .minutes(let minutes): "\(minutes)"
        case .until(let hour, let minute): "until \(Self.clockText(hour: hour, minute: minute))"
        case .untilBack: "back"
        }
    }

    public init?(controlArgument: String) {
        if controlArgument == "back" {
            self = .untilBack
        } else if controlArgument.hasPrefix("until ") {
            guard let time = Self.clockTime(from: String(controlArgument.dropFirst("until ".count))) else { return nil }
            self = .until(hour: time.hour, minute: time.minute)
        } else {
            guard let minutes = try? PauseState.minutes(from: controlArgument) else { return nil }
            self = .minutes(minutes)
        }
    }

    public struct UsageError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// The forms `--until` takes, for its error.
    public static let untilForms = "--until takes a local time: 08:00, 8:00, 20:30, 8am, 8 am, 8:30pm, 12am (midnight) or 12pm (noon)"

    /// `stew pause [MINUTES] | --until HH:MM | --until-back`: one of the three, or an
    /// hour when none is given.
    public static func parse(positional: [String], until: String?, untilBack: Bool) throws -> PauseChoice {
        var positional = positional
        var until = until
        // `--until 8 am` without quotes: the shell splits off "am".
        if let time = until, positional.count == 1, ["am", "pm"].contains(positional[0].lowercased()) {
            until = "\(time) \(positional[0])"
            positional = []
        }
        let given = (positional.isEmpty ? 0 : 1) + (until == nil ? 0 : 1) + (untilBack ? 1 : 0)
        guard given <= 1 else { throw UsageError(description: "pause takes MINUTES, --until HH:MM or --until-back, only one of them") }
        if untilBack { return .untilBack }
        if let until {
            guard let time = clockTime(from: until) else { throw UsageError(description: untilForms) }
            return .until(hour: time.hour, minute: time.minute)
        }
        guard positional.count <= 1 else { throw UsageError(description: "pause takes one number of minutes") }
        do {
            return .minutes(try PauseState.minutes(from: positional.first))
        } catch {
            throw UsageError(description: "\(error)")
        }
    }

    /// A time of day on a 24-hour clock ("8:30", "08:30", "20:30") or a 12-hour one
    /// ("8am", "8 am", "8:30pm", "8:30 PM"; "12am" is midnight, "12pm" noon). Hours
    /// out of range, such as "13pm" or "25:00", give nil.
    public static func clockTime(from text: String) -> (hour: Int, minute: Int)? {
        var clock = text
        var halfDay: String?
        for suffix in ["am", "pm"] where clock.lowercased().hasSuffix(suffix) {
            halfDay = suffix
            clock = String(clock.dropLast(suffix.count))
            if clock.hasSuffix(" ") { clock = String(clock.dropLast()) }
        }
        let parts = clock.split(separator: ":", omittingEmptySubsequences: false)
        let digitsOnly = parts.allSatisfy { part in !part.isEmpty && part.allSatisfy { character in character.isASCII && character.isNumber } }
        guard digitsOnly, (1...2).contains(parts[0].count), parts.count == 1 || (parts.count == 2 && parts[1].count == 2),
              let hour = Int(parts[0]), let minute = parts.count == 2 ? Int(parts[1]) : 0, (0...59).contains(minute) else { return nil }
        switch halfDay {
        case nil:
            // A bare number is no time; "8" could be minutes or a typo.
            guard parts.count == 2, (0...23).contains(hour) else { return nil }
            return (hour, minute)
        case let suffix?:
            guard (1...12).contains(hour) else { return nil }
            return (hour % 12 + (suffix == "pm" ? 12 : 0), minute)
        }
    }

    /// "08:00": the form of the control line.
    static func clockText(hour: Int, minute: Int) -> String {
        "\(hour < 10 ? "0" : "")\(hour):\(minute < 10 ? "0" : "")\(minute)"
    }
}

extension StewRequest {
    /// What Claude reads about a request that timed out at once because stew is paused.
    /// `resumes` says when stew resumes, as `PauseState.resumesText` gives it.
    public func pausedNote(resumes: String) -> String {
        let late = LateMailbox.canAnswerLate(self)
            ? " If they answer later, stew passes their answer on to you as a late answer, which replaces this timeout."
            : ""
        switch prompt {
        case .permission, .notify, .needs:
            return "The user paused stew and is away, so nobody saw this request. Treat it as denied and continue another way, or ask again after stew resumes \(resumes).\(late)"
        case .question, .input:
            return "The user paused stew and is away, so nobody saw this request. Continue with a safe choice that does not need this answer, or ask again after stew resumes \(resumes).\(late)"
        }
    }
}
