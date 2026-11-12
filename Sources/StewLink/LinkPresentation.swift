import Foundation
import StewCore

/// A notification action, independent of UserNotifications so it is testable on the Mac.
public struct LinkNotificationAction: Equatable, Sendable {
    public enum Role: Equatable, Sendable {
        case approve, deny, moreTime
        case option(Int)
        case other
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
    public static let optionActionPrefix = "option."

    /// Same titles as the Mac panel header.
    public static func kindTitle(_ prompt: Prompt) -> String {
        switch prompt {
        case .permission: "Permission request"
        case .question: "Question"
        case .needs: "Needs you"
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
        case .notify, .needs:
            return nil
        case .permission:
            let base = request.hardDeny ? "stew.permission.macOnly" : "stew.permission"
            return canExtend(request) ? base : base + ".noTime"
        case .question:
            return notificationQuestion(request) == nil ? "stew.question.inApp" : "stew.question.\(request.requestId)"
        }
    }

    public static func canExtend(_ request: LinkRequest) -> Bool {
        request.extendBy != nil && (request.deadline != nil || request.queued)
    }

    public static func actions(_ request: LinkRequest) -> [LinkNotificationAction] {
        let moreTime = LinkNotificationAction(identifier: moreTimeAction, title: moreTimeTitle(request.extendBy ?? 0), role: .moreTime)
        switch request.request.prompt {
        case .notify, .needs:
            return []
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

    static func timeLine(_ request: LinkRequest, time: (Date) -> String) -> String {
        switch request.request.prompt {
        case .notify, .needs: return request.macName
        case .permission, .question: break
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
        case otherAction:
            let text = (typedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard notificationQuestion(request) != nil, !text.isEmpty else { return nil }
            return .answers([LinkQuestionAnswer(selected: [], other: text)])
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
        case nil: "This request is no longer open on \(macName)."
        }
    }

    public static let alreadyAnswered = "You already answered this request."
    public static let clockNotStarted = "This request waits behind another one on your Mac, so its clock has not started yet."
    public static let noTimeLimit = "This request has no time limit."

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
        case (.deny, .permission), (.answers, .question):
            return nil
        default:
            return "This answer does not fit this request."
        }
    }
}
