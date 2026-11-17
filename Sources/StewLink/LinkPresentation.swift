import Foundation
import StewCore

/// A notification action, independent of UserNotifications so it is testable on the Mac.
public struct LinkNotificationAction: Equatable, Sendable {
    public enum Role: Equatable, Sendable {
        case approve, deny, moreTime
        case option(Int)
        case other
        case done, notNow
        /// One of a needs item's other answers, by index.
        case answer(Int)
        /// The typed answer to an input.
        case reply
        /// A secret input: "Give me 5 min" and "I'll enter it later".
        case enterSoon, enterLater
        /// A secret input: opens the request in the app, to type it there.
        case enterInApp
        /// Opens the request in the app, for a permission that needs the extra confirmation.
        case review
        /// A notification's OK: the user saw it.
        case acknowledge
    }

    public var identifier: String
    public var title: String
    public var role: Role
    /// Face ID or the passcode first. Approve always needs it.
    public var requiresAuthentication: Bool
    public var isDestructive: Bool
    /// Placeholder of the text field, for the "Other…" action.
    public var textPlaceholder: String?

    public init(identifier: String, title: String, role: Role, requiresAuthentication: Bool = false, isDestructive: Bool = false, textPlaceholder: String? = nil) {
        self.identifier = identifier
        self.title = title
        self.role = role
        self.requiresAuthentication = requiresAuthentication
        self.isDestructive = isDestructive
        self.textPlaceholder = textPlaceholder
    }
}

public struct LinkNotificationContent: Equatable, Sendable {
    public var title: String
    public var subtitle: String
    public var body: String
    public var categoryIdentifier: String?
    public var actions: [LinkNotificationAction]
    /// Groups notifications per Mac in Notification Center.
    public var threadIdentifier: String
    public var requestId: String
    /// A request with a time limit (a permission, a question, an input) breaks through
    /// Focus modes as a Time Sensitive notification; it would otherwise time out unseen.
    /// Needs items and notifications have no deadline and stay ordinary.
    public var timeSensitive: Bool = false
    /// No sound and no screen wake: the notification of a closed request, which only
    /// replaces what was on screen.
    public var passive: Bool = false
}

/// What the phone shows for a request: the same facts as the Mac panel, in the same
/// words, so an answer on the phone is as informed as one on the Mac.
public enum LinkPresentation {
    public static let approveAction = "approve"
    public static let denyAction = "deny"
    public static let moreTimeAction = "moreTime"
    public static let otherAction = "other"
    /// Opens the request in the app, where Approve asks for the extra confirmation.
    public static let reviewAction = "review"
    public static let reviewCategory = "stew.permission.review"
    public static let doneAction = "done"
    /// Handled on the phone alone: the notification goes, the item stays open on the Mac.
    public static let notNowAction = "notNow"
    public static let needsCategory = "stew.needs"
    /// Needs items with their own answers get a category per request, because the
    /// action titles are the item's labels.
    public static let needsCategoryPrefix = "stew.needs."
    public static let needsAnswerActionPrefix = "answer."
    /// The text field of an input that is not secret.
    public static let replyAction = "reply"
    public static let enterSoonAction = "enterSoon"
    public static let enterLaterAction = "enterLater"
    /// Inputs that are not secret get a category per request, because the reply field's
    /// placeholder is the request's own.
    public static let inputCategoryPrefix = "stew.input."
    /// Secret inputs: no text field, because a notification cannot hide what is typed.
    /// From a Mac that takes the secret typed in the app, the category ends in `.app` and
    /// its first action opens the request there.
    public static let secretCategory = "stew.secret"
    public static let enterSoonTitle = "Give me 5 min"
    public static let enterLaterTitle = "I'll enter it later"
    /// Opens the secret input in the app, where its masked field is.
    public static let enterInAppAction = "enterInApp"
    public static let enterInAppTitle = "Enter in app"
    /// A notification's only action: OK, which clears it here and in the Mac panel.
    public static let notifyCategory = "stew.notify"
    public static let acknowledgeAction = "ok"
    public static let acknowledgeTitle = "OK"

    /// Whether the app may offer a field for this secret input.
    public static func takesSecretInApp(_ request: LinkRequest) -> Bool {
        guard case .input(let input) = request.request.prompt, input.secret else { return false }
        return request.secretInApp == true
    }

    /// Request ids for needs items, which have short ids of their own on the Mac.
    public static func needsRequestId(_ needsID: String) -> String { "needs-" + needsID }
    public static let optionActionPrefix = "option."

    /// Same titles as the Mac panel header.
    public static func kindTitle(_ prompt: Prompt) -> String {
        switch prompt {
        case .permission: "Permission request"
        case .question: "Question"
        case .needs: "Needs you"
        case .input(let input): input.secret ? "Secret" : "Input"
        case .notify(let notify):
            switch notify.level {
            case .info: "Notification"
            case .success: "Done"
            case .warning: "Warning"
            case .error: "Error"
            }
        }
    }

    /// Same SF Symbols as the Mac panel header.
    public static func kindSymbol(_ prompt: Prompt) -> String {
        switch prompt {
        case .permission: "hand.raised.fill"
        case .question: "questionmark.bubble.fill"
        case .needs: "hand.point.up.left.fill"
        case .input(let input): input.secret ? "key.fill" : "character.cursor.ibeam"
        case .notify(let notify):
            switch notify.level {
            case .info: "bell.fill"
            case .success: "checkmark"
            case .warning: "exclamationmark.triangle.fill"
            case .error: "xmark.octagon.fill"
            }
        }
    }

    /// `/Users/name/Projects/x` becomes `~/Projects/x`: the phone has less room.
    public static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0].isEmpty, parts[1] == "Users" else { return path }
        let rest = parts.dropFirst(3).joined(separator: "/")
        return rest.isEmpty ? "~" : "~/" + rest
    }

    /// The single question a notification can answer with buttons. Several questions or
    /// a multi-select question need the app.
    public static func notificationQuestion(_ request: LinkRequest) -> Question? {
        guard case .question(let set) = request.request.prompt, set.questions.count == 1,
              let question = set.questions.first, !question.multiSelect else { return nil }
        return question
    }

    public static func categoryIdentifier(_ request: LinkRequest) -> String? {
        switch request.request.prompt {
        case .notify:
            return notifyCategory
        case .needs(let needs):
            return needs.hasCustomAnswers ? needsCategoryPrefix + request.requestId : needsCategory
        case .permission:
            let base = request.hardDeny ? "stew.permission.macOnly" : request.confirmation != nil ? reviewCategory : "stew.permission"
            return canExtend(request) ? base : base + ".noTime"
        case .question:
            guard notificationQuestion(request) != nil else { return "stew.question.inApp" + (canExtend(request) ? "" : ".noTime") }
            return "stew.question.\(request.requestId)"
        case .input(let input):
            guard input.secret else { return inputCategoryPrefix + request.requestId }
            return secretCategory + (canExtend(request) ? "" : ".noTime") + (request.request.offersEnterLater ? "" : ".noLater")
                + (takesSecretInApp(request) ? ".app" : "")
        }
    }

    public static func canExtend(_ request: LinkRequest) -> Bool {
        request.extendBy != nil && (request.deadline != nil || request.queued)
    }

    /// Whether the phone may still answer the request after its time ran out: the Mac
    /// then passes the answer to the Claude session as a late answer, as History's
    /// preview does. It needs the session's id. A secret only from a Mac that takes it typed
    /// in the app; the notification never has a field for it.
    public static func canAnswerLate(_ request: LinkRequest) -> Bool {
        if case .input(let input) = request.request.prompt, input.secret, !takesSecretInApp(request) { return false }
        return LateMailbox.canAnswerLate(request.request)
    }

    /// True once the time to answer has run out.
    public static func isOverdue(_ request: LinkRequest, now: Date = Date()) -> Bool {
        guard let deadline = request.deadline else { return false }
        return deadline <= now
    }

    public static func actions(_ request: LinkRequest) -> [LinkNotificationAction] {
        let moreTime = LinkNotificationAction(identifier: moreTimeAction, title: moreTimeTitle(request.extendBy ?? 0), role: .moreTime)
        switch request.request.prompt {
        case .notify:
            return [LinkNotificationAction(identifier: acknowledgeAction, title: acknowledgeTitle, role: .acknowledge)]
        case .needs(let needs):
            // Done and the other answers need no Face ID: they only tell Claude how to go
            // on, they run nothing.
            let answers = needs.answers.prefix(NeedsRequest.maxAnswers).enumerated().map { index, label in
                LinkNotificationAction(identifier: needsAnswerActionPrefix + String(index), title: label, role: .answer(index))
            }
            return [LinkNotificationAction(identifier: doneAction, title: needs.doneTitle, role: .done)]
                + answers
                + [LinkNotificationAction(identifier: notNowAction, title: "Not now", role: .notNow)]
        case .permission:
            var actions: [LinkNotificationAction] = []
            if request.confirmation != nil, !request.hardDeny {
                // No inline Approve: the extra confirmation needs the app.
                actions.append(LinkNotificationAction(identifier: reviewAction, title: "Review", role: .review))
            } else if !request.hardDeny {
                actions.append(LinkNotificationAction(identifier: approveAction, title: "Approve", role: .approve, requiresAuthentication: true))
            }
            actions.append(LinkNotificationAction(identifier: denyAction, title: "Deny", role: .deny, isDestructive: true))
            if canExtend(request) { actions.append(moreTime) }
            return actions
        case .question:
            guard let question = notificationQuestion(request) else { return canExtend(request) ? [moreTime] : [] }
            var actions = question.options.prefix(4).enumerated().map { index, option in
                LinkNotificationAction(identifier: optionActionPrefix + String(index), title: option.label, role: .option(index))
            }
            actions.append(LinkNotificationAction(identifier: otherAction, title: "Other…", role: .other, textPlaceholder: "Your answer"))
            if canExtend(request) { actions.append(moreTime) }
            return actions
        case .input(let input):
            // A notification text field cannot hide what is typed, so a secret is never
            // entered in one: on the Mac, or in the app's masked field. None of these
            // needs Face ID: they open the app or move the time, they answer nothing.
            guard input.secret else {
                let placeholder = input.placeholder.flatMap { $0.isEmpty ? nil : $0 } ?? "Your answer"
                let reply = LinkNotificationAction(identifier: replyAction, title: "Reply", role: .reply, textPlaceholder: placeholder)
                return canExtend(request) ? [reply, moreTime] : [reply]
            }
            var actions: [LinkNotificationAction] = []
            if takesSecretInApp(request) {
                actions.append(LinkNotificationAction(identifier: enterInAppAction, title: enterInAppTitle, role: .enterInApp))
            }
            if canExtend(request) {
                actions.append(LinkNotificationAction(identifier: enterSoonAction, title: enterSoonTitle, role: .enterSoon))
            }
            if request.request.offersEnterLater {
                actions.append(LinkNotificationAction(identifier: enterLaterAction, title: enterLaterTitle, role: .enterLater))
            }
            return actions
        }
    }

    /// The risk check's verdict on the call: the Mac's own check, or for a call auto mode
    /// blocked, stew's explanation of it, which the Mac adds once its check is done.
    public static func assessment(_ request: LinkRequest) -> RiskAssessment? {
        if let risk = request.risk { return risk }
        guard case .permission(let permission) = request.request.prompt else { return nil }
        return permission.blocked?.explanation
    }

    /// The severity chip and the reversibility line as one line of text, such as
    /// "High risk · Deletes files permanently; no undo." Nil without a severity.
    public static func severityLine(_ risk: RiskAssessment?) -> String? {
        guard let severity = risk?.severity else { return nil }
        return ([severity.label, risk?.reversibilityLine].compactMap { $0 }).joined(separator: " · ")
    }

    /// The phone shows this while the Mac took its "viewing" message.
    public static let viewingPaused = "No rush: the clock is paused while you answer."

    /// The Mac panel's header while a phone has the request open, in place of the clock.
    /// Short, after `viewingSymbol`, so the session name beside it keeps its room.
    public static func viewingOn(_ phoneName: String) -> String { "On \(phoneName)" }
    /// The SF Symbol in front of `viewingOn`.
    public static let viewingSymbol = "iphone"

    public static func moreTimeTitle(_ seconds: Double) -> String {
        seconds >= 60 && seconds.truncatingRemainder(dividingBy: 60) == 0 ? "More time (+\(Int(seconds / 60)) min)" : "More time (+\(Int(seconds)) s)"
    }

    public static func notification(
        for request: LinkRequest,
        pairingId: String,
        time: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }
    ) -> LinkNotificationContent {
        let session = request.request.session
        var subtitleParts = [kindTitle(request.request.prompt)]
        if let cwd = session.cwd, !cwd.isEmpty { subtitleParts.append(shortPath(cwd)) }
        var lines: [String] = []
        var title = session.name
        switch request.request.prompt {
        case .permission(let permission):
            if request.hardDeny {
                lines.append("Auto mode never allows this. Approve it on your Mac, or deny it here.")
            } else if let blocked = permission.blocked {
                lines.append((["Auto mode blocked this", blocked.category].compactMap { $0 }).joined(separator: " · "))
                if let summary = blocked.explanation?.summary, !summary.isEmpty { lines.append(CommandText.masked(summary)) }
            } else if let risk = request.risk, risk.verdict == .softDeny {
                lines.append((["Auto mode would block this", risk.ruleName].compactMap { $0 }).joined(separator: " · "))
            }
            if let line = severityLine(assessment(request)) { lines.append(line) }
            lines.append(permission.action)
            if let command = permission.command, !command.isEmpty {
                lines.append("$ " + CommandText.masked(command))
            }
            lines.append((permission.blocked == nil ? "Why: " : "\(session.codingAgent.name)'s last message: ") + permission.reason)
        case .question(let set):
            if let question = notificationQuestion(request) {
                lines.append(question.question)
            } else {
                lines.append(set.questions[0].question)
                lines.append(set.questions.count > 1 ? "Open stew to answer \(set.questions.count) questions." : "Open stew to choose any of the options.")
            }
        case .notify(let notify):
            title = notify.title
            subtitleParts = [kindTitle(request.request.prompt), session.name]
            if let body = notify.body, !body.isEmpty { lines.append(body) }
        case .needs(let needs):
            title = needs.title
            subtitleParts = [kindTitle(request.request.prompt), session.name]
            lines += needsLines(needs)
        case .input(let input):
            lines += inputLines(input, inApp: takesSecretInApp(request))
        }
        lines.append(timeLine(request, time: time))
        return LinkNotificationContent(
            title: title,
            subtitle: subtitleParts.joined(separator: " · "),
            body: lines.joined(separator: "\n"),
            categoryIdentifier: categoryIdentifier(request),
            actions: actions(request),
            threadIdentifier: pairingId,
            requestId: request.requestId,
            timeSensitive: hasDeadline(request.request.prompt)
        )
    }

    /// The category of a closed request's notification. It has no actions, so a stale
    /// Approve can never remain. The relay's closed alert push names the same one.
    public static let closedCategory = "stew.closed"

    /// How a closed request's notification names the phone that shows it.
    public static let thisPhone = "this iPhone"

    /// One line for how a request ended, in the notification that replaces its own.
    /// `agent` is the agent that asked, for the outcomes that name it.
    public static func closedLine(_ resolved: LinkResolved, macName: String, canAnswerLate: Bool = false, agent: CodingAgent = .claudeCode) -> String {
        let phone = resolved.answeredHere == true ? thisPhone : resolved.answeredOn
        switch resolved.outcome {
        case .approved, .denied, .answered:
            // A Mac from before `answeredOn` does not say which phone answered.
            return phone.map { "\(resolved.outcome.label) on \($0)" } ?? resolved.outcome.label
        case .done:
            return phone.map { "Marked done on \($0)" } ?? "Marked done"
        case .answeredOnMac:
            return "Answered on \(macName)"
        case .timedOut:
            return canAnswerLate ? "Timed out. Open stew to answer late." : "Timed out"
        case .dismissed:
            return "Dismissed on \(macName)"
        case .later:
            return "Waiting for you to enter it later"
        case .resolvedByClaude, .answeredInSession, .movedOn:
            return resolved.outcome.label(for: agent)
        }
    }

    /// The notification that replaces a request's own once it is closed: the same title
    /// and subtitle, how it ended, no actions, and passive, so it makes no sound. Without
    /// the request (the phone never opened it) the title is "stew".
    public static func closedNotification(_ resolved: LinkResolved, request: LinkRequest?, macName: String, pairingId: String) -> LinkNotificationContent {
        let original = request.map { notification(for: $0, pairingId: pairingId) }
        let lateAnswerPossible = resolved.outcome == .timedOut && request.map(canAnswerLate) == true
        return LinkNotificationContent(
            title: original?.title ?? "stew",
            subtitle: original?.subtitle ?? macName,
            body: closedLine(resolved, macName: macName, canAnswerLate: lateAnswerPossible, agent: request?.request.session.codingAgent ?? .claudeCode),
            categoryIdentifier: closedCategory,
            actions: [],
            threadIdentifier: pairingId,
            requestId: resolved.requestId,
            passive: true
        )
    }

    public static func hasDeadline(_ prompt: Prompt) -> Bool {
        switch prompt {
        case .permission, .question, .input: true
        case .notify, .needs: false
        }
    }

    /// The same parts as the Mac panel, in its order: why, numbered steps, then the
    /// commands with secrets masked.
    public static func needsLines(_ needs: NeedsRequest) -> [String] {
        var lines: [String] = []
        if let why = needs.why, !why.isEmpty { lines.append(why) }
        lines += needs.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }
        lines += needs.commands.map { "$ " + CommandText.masked($0.command) }
        return lines
    }

    /// The question, why (both masked like a command), and for a secret where to enter it.
    /// `inApp`: the Mac also takes the secret typed in the app.
    public static func inputLines(_ input: InputRequest, inApp: Bool = false) -> [String] {
        var lines = [CommandText.masked(input.question)]
        if let why = input.why, !why.isEmpty { lines.append("Why: " + CommandText.masked(why)) }
        if input.secret { lines.append(inApp ? InputRequest.enterOnMacOrAppMessage : InputRequest.enterOnMacMessage) }
        return lines
    }

    /// The last line of a notification and the subtitle of a request row: the Mac, and
    /// when the time to answer runs out.
    public static func timeLine(_ request: LinkRequest, time: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }) -> String {
        switch request.request.prompt {
        case .notify, .needs: return request.macName
        case .permission, .question, .input: break
        }
        if request.queued { return "\(request.macName) · waits behind another request" }
        if let deadline = request.deadline { return "\(request.macName) · answer by \(time(deadline))" }
        return request.macName
    }

    /// The choice a notification action stands for. Nil for an unknown action, or for
    /// "Other…" with nothing typed.
    public static func choice(forAction identifier: String, typedText: String?, request: LinkRequest) -> LinkChoice? {
        switch identifier {
        case approveAction: return request.hardDeny || request.confirmation != nil ? nil : .approve
        case denyAction: return .deny
        case moreTimeAction: return .moreTime
        case doneAction:
            guard case .needs = request.request.prompt else { return nil }
            return .done
        case acknowledgeAction:
            guard case .notify = request.request.prompt else { return nil }
            return .done
        case _ where identifier.hasPrefix(needsAnswerActionPrefix):
            guard case .needs(let needs) = request.request.prompt,
                  let index = Int(identifier.dropFirst(needsAnswerActionPrefix.count)),
                  needs.answers.indices.contains(index) else { return nil }
            return .needsAnswer(needs.answers[index])
        case otherAction:
            let text = (typedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard notificationQuestion(request) != nil, !text.isEmpty else { return nil }
            return .answers([LinkQuestionAnswer(selected: [], other: text)])
        case replyAction:
            // Sent as typed: LinkRefusal.beforeSending says why a reply cannot go, such
            // as one that does not match the pattern.
            guard case .input(let input) = request.request.prompt, !input.secret else { return nil }
            return .text(typedText ?? "")
        case enterSoonAction:
            guard case .input(let input) = request.request.prompt, input.secret else { return nil }
            return .enterSoon
        case enterLaterAction:
            guard request.request.offersEnterLater else { return nil }
            return .enterLater
        default:
            guard identifier.hasPrefix(optionActionPrefix), let index = Int(identifier.dropFirst(optionActionPrefix.count)),
                  let question = notificationQuestion(request), question.options.indices.contains(index) else { return nil }
            return .answers([LinkQuestionAnswer(selected: [index])])
        }
    }
}

/// The sentences either side shows when an answer cannot be taken. The phone checks
/// first, so most refusals need no network; the Mac checks again, because only its
/// state counts.
public enum LinkRefusal {
    /// `agent` is the agent that asked: requests that do not say come from Claude Code.
    public static func tooLate(
        macName: String, deadline: Date, agent: CodingAgent = .claudeCode,
        time: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }
    ) -> String {
        "Too late: the request on \(macName) timed out at \(time(deadline)). \(agent.name) was told you did not respond in time."
    }

    public static let macOnly = "Approve this on your Mac. Auto mode never allows it, so the phone can only deny it."

    public static func closed(_ outcome: LinkOutcome?, macName: String, agent: CodingAgent = .claudeCode) -> String {
        switch outcome {
        case .answeredOnMac: "Already answered on \(macName)."
        case .timedOut: "Too late: the request on \(macName) timed out. \(agent.name) was told you did not respond in time."
        case .dismissed: "The request on \(macName) was dismissed."
        case .approved, .denied, .answered: "Already answered on another device."
        case .done: "Already marked done."
        case .resolvedByClaude: "\(agent.name) saw that this is done."
        case .answeredInSession: "You already answered this in the \(agent.name) session."
        case .movedOn: "\(agent.name) moved on from this."
        case .later: "You chose to enter this on \(macName) later, from its History."
        case nil: "This request is no longer open on \(macName)."
        }
    }

    /// The Mac's refusal of an approval that skipped the extra confirmation, such as one
    /// from a phone app that does not know severity yet.
    public static let needsConfirmation = "This request needs an extra confirmation. Open it in the stew app to approve it, or update the app if Approve does not ask you to confirm."

    public static let alreadyAnswered = "You already answered this request."
    public static let viewingCapReached = "The clock is no longer paused for this request: it was open on your iPhone for the longest time stew pauses it."
    public static let riskChecking = "Your Mac is still checking this command against your auto mode rules. Try again in a few seconds."
    /// An answer older than this is refused, so a relay that held it back cannot apply it
    /// after the user has moved on.
    public static let answerLifetime: TimeInterval = 30
    public static let tooSlow = "This answer took too long to reach your Mac. Answer again."
    public static let clockNotStarted = "This request waits behind another one on your Mac, so its clock has not started yet."
    public static let noTimeLimit = "This request has no time limit."
    public static let unknownAnswer = "This item does not offer that answer. Open stew to see its answers."

    /// The phone shows this when the Mac took an answer as a late answer.
    public static let lateAnswerSent = "Sent as a late answer"
    public static let lateAnswerDetail = lateAnswerDetail(for: .claudeCode)

    public static func lateAnswerDetail(for agent: CodingAgent) -> String {
        "The request had timed out. \(agent.name) gets this answer at its next step, in place of the timeout."
    }

    /// Checked on the phone before anything is sent. After the deadline only an answer
    /// that can go as a late answer passes: approve, deny, the question's answers or a
    /// typed reply, for a request of a known Claude session.
    public static func beforeSending(_ choice: LinkChoice, for request: LinkRequest, now: Date = Date()) -> String? {
        if let deadline = request.deadline, deadline <= now {
            let isAnswer: Bool
            switch choice {
            case .approve, .deny, .answers, .text, .secret: isAnswer = true
            case .moreTime, .done, .needsAnswer, .enterSoon, .enterLater, .viewing, .left: isAnswer = false
            }
            guard isAnswer, LinkPresentation.canAnswerLate(request) else {
                return tooLate(macName: request.macName, deadline: deadline, agent: request.request.session.codingAgent)
            }
        }
        switch (choice, request.request.prompt) {
        case (.approve, .permission):
            return request.hardDeny ? macOnly : nil
        case (.moreTime, _):
            if request.queued { return clockNotStarted }
            return request.deadline == nil ? noTimeLimit : nil
        case (.deny, .permission), (.answers, .question), (.done, .needs), (.done, .notify):
            return nil
        case (.viewing, _), (.left, _):
            // Only the clock depends on these; a request without one simply ignores them.
            return nil
        case (.needsAnswer(let label), .needs(let needs)):
            return needs.answers.contains(label) ? nil : unknownAnswer
        case (.text(let text), .input(let input)):
            return inputRefusal(text, for: input)
        case (.secret(let text), .input(let input)):
            return LinkPresentation.takesSecretInApp(request) ? secretRefusal(text, for: input) : secretOnMac
        case (.enterSoon, .input(let input)) where input.secret:
            if request.queued { return clockNotStarted }
            return request.deadline == nil ? noTimeLimit : nil
        case (.enterLater, .input):
            return request.request.offersEnterLater ? nil : "This request cannot wait for later."
        default:
            return "This answer does not fit this request."
        }
    }

    public static let emptyAnswer = "Type an answer first."
    /// A secret sent as a plain reply, or to a Mac that does not take it from the app.
    public static let secretOnMac = "This is a secret. " + InputRequest.enterOnMacMessage
    public static let notASecret = "This input is not a secret. Reply to it instead."

    /// Why a typed answer cannot be sent, or nil when it can. The phone checks first and
    /// the Mac checks again with the same rules.
    public static func inputRefusal(_ text: String, for input: InputRequest) -> String? {
        guard !input.secret else { return secretOnMac }
        return checkRefusal(input.check(text), for: input)
    }

    /// The same for a secret typed in the app's masked field. The refusal never repeats
    /// what was typed.
    public static func secretRefusal(_ text: String, for input: InputRequest) -> String? {
        guard input.secret else { return notASecret }
        return checkRefusal(input.check(text), for: input)
    }

    private static func checkRefusal(_ check: InputRequest.Check, for input: InputRequest) -> String? {
        switch check {
        case .empty: return emptyAnswer
        case .mismatch: return input.mismatchText
        case .valid: return nil
        }
    }
}
