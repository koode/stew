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
    /// Nil for notifications, which have no actions.
    public var categoryIdentifier: String?
    public var actions: [LinkNotificationAction]
    /// Groups notifications per Mac in Notification Center.
    public var threadIdentifier: String
    public var requestId: String
}

/// What the phone shows for a request: the same facts as the Mac panel, in the same
/// words, so an answer on the phone is as informed as one on the Mac.
public enum LinkPresentation {
    public static let approveAction = "approve"
    public static let denyAction = "deny"
    public static let moreTimeAction = "moreTime"
    public static let otherAction = "other"
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
    /// Secret inputs: no text field, only the two ways to say "on the Mac".
    public static let secretCategory = "stew.secret"
    public static let enterSoonTitle = "Give me 5 min"
    public static let enterLaterTitle = "I'll enter it later"

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
            return nil
        case .needs(let needs):
            return needs.hasCustomAnswers ? needsCategoryPrefix + request.requestId : needsCategory
        case .permission:
            let base = request.hardDeny ? "stew.permission.macOnly" : "stew.permission"
            return canExtend(request) ? base : base + ".noTime"
        case .question:
            return notificationQuestion(request) == nil ? "stew.question.inApp" : "stew.question.\(request.requestId)"
        case .input(let input):
            guard input.secret else { return inputCategoryPrefix + request.requestId }
            return secretCategory + (canExtend(request) ? "" : ".noTime") + (request.request.offersEnterLater ? "" : ".noLater")
        }
    }

    public static func canExtend(_ request: LinkRequest) -> Bool {
        request.extendBy != nil && (request.deadline != nil || request.queued)
    }

    public static func actions(_ request: LinkRequest) -> [LinkNotificationAction] {
        let moreTime = LinkNotificationAction(identifier: moreTimeAction, title: moreTimeTitle(request.extendBy ?? 0), role: .moreTime)
        switch request.request.prompt {
        case .notify:
            return []
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
            if !request.hardDeny {
                actions.append(LinkNotificationAction(identifier: approveAction, title: "Approve", role: .approve, requiresAuthentication: true))
            }
            actions.append(LinkNotificationAction(identifier: denyAction, title: "Deny", role: .deny, isDestructive: true))
            if canExtend(request) { actions.append(moreTime) }
            return actions
        case .question:
            guard let question = notificationQuestion(request) else { return [] }
            var actions = question.options.prefix(4).enumerated().map { index, option in
                LinkNotificationAction(identifier: optionActionPrefix + String(index), title: option.label, role: .option(index))
            }
            actions.append(LinkNotificationAction(identifier: otherAction, title: "Other…", role: .other, textPlaceholder: "Your answer"))
            return actions
        case .input(let input):
            // A notification text field cannot hide what is typed, so a secret is
            // entered on the Mac only. Neither choice for it needs Face ID: they only
            // move the time, they answer nothing.
            guard input.secret else {
                let placeholder = input.placeholder.flatMap { $0.isEmpty ? nil : $0 } ?? "Your answer"
                return [LinkNotificationAction(identifier: replyAction, title: "Reply", role: .reply, textPlaceholder: placeholder)]
            }
            var actions: [LinkNotificationAction] = []
            if canExtend(request) {
                actions.append(LinkNotificationAction(identifier: enterSoonAction, title: enterSoonTitle, role: .enterSoon))
            }
            if request.request.offersEnterLater {
                actions.append(LinkNotificationAction(identifier: enterLaterAction, title: enterLaterTitle, role: .enterLater))
            }
            return actions
        }
    }

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
            } else if let risk = request.risk, risk.verdict == .softDeny {
                lines.append((["Auto mode would block this", risk.ruleName].compactMap { $0 }).joined(separator: " · "))
            }
            lines.append(permission.action)
            if let command = permission.command, !command.isEmpty {
                lines.append("$ " + CommandText.masked(command))
            }
            lines.append((permission.blocked == nil ? "Why: " : "Claude's last message: ") + permission.reason)
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
            lines += inputLines(input)
        }
        lines.append(timeLine(request, time: time))
        return LinkNotificationContent(
            title: title,
            subtitle: subtitleParts.joined(separator: " · "),
            body: lines.joined(separator: "\n"),
            categoryIdentifier: categoryIdentifier(request),
            actions: actions(request),
            threadIdentifier: pairingId,
            requestId: request.requestId
        )
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
    public static func inputLines(_ input: InputRequest) -> [String] {
        var lines = [CommandText.masked(input.question)]
        if let why = input.why, !why.isEmpty { lines.append("Why: " + CommandText.masked(why)) }
        if input.secret { lines.append(InputRequest.enterOnMacMessage) }
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
        case approveAction: return request.hardDeny ? nil : .approve
        case denyAction: return .deny
        case moreTimeAction: return .moreTime
        case doneAction:
            guard case .needs = request.request.prompt else { return nil }
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
    public static func tooLate(macName: String, deadline: Date, time: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }) -> String {
        "Too late: the request on \(macName) timed out at \(time(deadline)). Claude was told you did not respond in time."
    }

    public static let macOnly = "Approve this on your Mac. Auto mode never allows it, so the phone can only deny it."

    public static func closed(_ outcome: LinkOutcome?, macName: String) -> String {
        switch outcome {
        case .answeredOnMac: "Already answered on \(macName)."
        case .timedOut: "Too late: the request on \(macName) timed out. Claude was told you did not respond in time."
        case .dismissed: "The request on \(macName) was dismissed."
        case .approved, .denied, .answered: "Already answered on another device."
        case .done: "Already marked done."
        case .resolvedByClaude: "Claude saw that this is done."
        case .answeredInSession: "You already answered this in the Claude session."
        case .movedOn: "Claude moved on from this."
        case .later: "You chose to enter this on \(macName) later, from its History."
        case nil: "This request is no longer open on \(macName)."
        }
    }

    public static let alreadyAnswered = "You already answered this request."
    public static let riskChecking = "Your Mac is still checking this command against your auto mode rules. Try again in a few seconds."
    /// An answer older than this is refused, so a relay that held it back cannot apply it
    /// after the user has moved on.
    public static let answerLifetime: TimeInterval = 30
    public static let tooSlow = "This answer took too long to reach your Mac. Answer again."
    public static let clockNotStarted = "This request waits behind another one on your Mac, so its clock has not started yet."
    public static let noTimeLimit = "This request has no time limit."
    public static let unknownAnswer = "This item does not offer that answer. Open stew to see its answers."

    /// Checked on the phone before anything is sent.
    public static func beforeSending(_ choice: LinkChoice, for request: LinkRequest, now: Date = Date()) -> String? {
        if let deadline = request.deadline, deadline <= now {
            return tooLate(macName: request.macName, deadline: deadline)
        }
        switch (choice, request.request.prompt) {
        case (.approve, .permission):
            return request.hardDeny ? macOnly : nil
        case (.moreTime, _):
            if request.queued { return clockNotStarted }
            return request.deadline == nil ? noTimeLimit : nil
        case (.deny, .permission), (.answers, .question), (.done, .needs):
            return nil
        case (.needsAnswer(let label), .needs(let needs)):
            return needs.answers.contains(label) ? nil : unknownAnswer
        case (.text(let text), .input(let input)):
            return inputRefusal(text, for: input)
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
    public static let secretOnMac = "This is a secret. " + InputRequest.enterOnMacMessage

    /// Why a typed answer cannot be sent, or nil when it can. The phone checks first and
    /// the Mac checks again with the same rules.
    public static func inputRefusal(_ text: String, for input: InputRequest) -> String? {
        guard !input.secret else { return secretOnMac }
        switch input.check(text) {
        case .empty: return emptyAnswer
        case .mismatch: return InputRequest.mismatchMessage + (input.pattern.map { " Expected: \($0)" } ?? "")
        case .valid: return nil
        }
    }
}
