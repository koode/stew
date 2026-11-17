import Foundation
import StewCore

/// Phone to Mac while pairing. Its keys must equal the ones the relay passed on in the
/// clear, or the Mac refuses the pairing.
public struct LinkHello: Codable, Equatable, Sendable {
    public var phoneName: String
    public var phoneKeys: LinkPublicKeys

    public init(phoneName: String, phoneKeys: LinkPublicKeys) {
        self.phoneName = phoneName
        self.phoneKeys = phoneKeys
    }
}

/// Mac to phone: everything the Mac panel shows for one request.
public struct LinkRequest: Codable, Equatable, Sendable {
    public var requestId: String
    public var macName: String
    public var request: StewRequest
    public var receivedAt: Date
    /// When the time to answer runs out. Nil while the request waits behind another one
    /// on the Mac (its clock has not started), and for requests without a limit.
    public var deadline: Date?
    /// True while the request waits behind another one on the Mac.
    public var queued: Bool
    /// Seconds one "More time" adds. Nil when the request has no time limit.
    public var extendBy: Double?
    /// Auto mode never allows this call: it can be approved on the Mac only.
    public var hardDeny: Bool
    public var risk: RiskAssessment?
    /// The extra step the phone asks for before it approves, from the risk check's
    /// severity and the Mac's setting. Nil: none. An older phone ignores it, and the Mac
    /// then refuses its approval.
    public var confirmation: PhoneConfirmation?
    /// The name of the phone the request is open on, while its clock is paused for that.
    /// Nil from a Mac that does not pause for viewing.
    public var viewingOn: String?
    /// True for a secret input from a Mac that takes the secret typed in the app
    /// (`LinkChoice.secret`). Nil from an older Mac, so the app offers no field for it.
    public var secretInApp: Bool?
    /// True while the Mac's own risk check of a call auto mode blocked still runs; the
    /// explanation follows in an update, inside `PermissionRequest.blocked`. Nil from an
    /// older Mac, and once the check ended.
    public var explaining: Bool?

    public init(
        requestId: String,
        macName: String,
        request: StewRequest,
        receivedAt: Date,
        deadline: Date?,
        queued: Bool,
        extendBy: Double?,
        hardDeny: Bool,
        risk: RiskAssessment?,
        confirmation: PhoneConfirmation? = nil,
        viewingOn: String? = nil,
        secretInApp: Bool? = nil,
        explaining: Bool? = nil
    ) {
        self.requestId = requestId
        self.macName = macName
        self.request = request
        self.receivedAt = receivedAt
        self.deadline = deadline
        self.queued = queued
        self.extendBy = extendBy
        self.hardDeny = hardDeny
        self.risk = risk
        self.confirmation = confirmation
        self.viewingOn = viewingOn
        self.secretInApp = secretInApp
        self.explaining = explaining
    }
}

/// One question's answer, by option index, so the Mac rebuilds it with the same
/// QuestionFlow rules as its own panel.
public struct LinkQuestionAnswer: Codable, Equatable, Sendable {
    public var selected: [Int]
    public var other: String?

    public init(selected: [Int], other: String? = nil) {
        self.selected = selected
        self.other = other
    }
}

public enum LinkChoice: Codable, Equatable, Sendable {
    case approve
    case deny
    case moreTime
    /// One entry per question, in order.
    case answers([LinkQuestionAnswer])
    /// A needs item is done. "Not now" sends nothing: on the Mac it changes nothing.
    case done
    /// One of a needs item's other answers, by its label. The Mac refuses a label the
    /// item does not offer. Done stays `done`, also with a label of its own, so a phone
    /// that does not know the labels can still answer it.
    case needsAnswer(String)
    /// The typed answer to an input that is not secret. The Mac checks it against the
    /// pattern again and refuses one that does not match.
    case text(String)
    /// A secret input: "Give me 5 min" adds `InputRequest.enterSoonSeconds` to its clock.
    case enterSoon
    /// A secret input: "I'll enter it later" ends Claude's wait with "later".
    case enterLater
    /// The value of a secret input, typed in the app's masked field, never in a
    /// notification. Only for a request with `secretInApp`: an older Mac cannot read it.
    /// The Mac checks it against the pattern again and keeps it like a secret typed in
    /// its own panel: never in a file, a late one in memory only.
    case secret(String)
    /// The request is on screen in the app: the Mac pauses its clock. Not an answer.
    case viewing
    /// The request left the screen in the app: the clock runs again after a short grace
    /// period. Not an answer.
    case left
}

/// Phone to Mac.
public struct LinkAnswer: Codable, Equatable, Sendable {
    public var requestId: String
    public var choice: LinkChoice
    /// A note for Claude, sent with approve or deny.
    public var note: String?
    public var phoneName: String
    public var answeredAt: Date
    /// True when the user went through the extra confirmation the request asked for.
    /// The Mac refuses an approval of such a request without it.
    public var confirmed: Bool?

    public init(requestId: String, choice: LinkChoice, note: String? = nil, phoneName: String, answeredAt: Date = Date(), confirmed: Bool? = nil) {
        self.requestId = requestId
        self.choice = choice
        self.note = note
        self.phoneName = phoneName
        self.answeredAt = answeredAt
        self.confirmed = confirmed
    }
}

/// Mac to phone, in reply to an answer.
public struct LinkResult: Codable, Equatable, Sendable {
    public var requestId: String
    public var accepted: Bool
    /// One sentence for the phone to show, such as why an answer came too late.
    public var message: String
    /// The new deadline after "More time".
    public var deadline: Date?
    /// True when the request had timed out and the answer went to Claude as a late
    /// answer. Nil from a Mac that does not take late answers from the phone.
    public var late: Bool?

    public init(requestId: String, accepted: Bool, message: String, deadline: Date? = nil, late: Bool? = nil) {
        self.requestId = requestId
        self.accepted = accepted
        self.message = message
        self.deadline = deadline
        self.late = late
    }
}

/// How a request ended, with the labels both the phone and the Mac's history use.
public enum LinkOutcome: String, Codable, Sendable, CaseIterable {
    case approved, denied, answered, timedOut, dismissed, answeredOnMac
    /// How a needs item ended, with the labels of the Mac's History tab.
    case done, resolvedByClaude, answeredInSession, movedOn
    /// A secret input the user will enter on the Mac later.
    case later

    public var label: String {
        switch self {
        case .approved: "Approved"
        case .denied: "Denied"
        case .answered: "Answered"
        case .timedOut: "Timed out"
        case .dismissed: "Dismissed"
        case .answeredOnMac: "Answered on Mac"
        case .done: "Done"
        case .resolvedByClaude: "Resolved by Claude"
        case .answeredInSession: "Answered in session"
        case .movedOn: "Moved on"
        case .later: "Enter later"
        }
    }

    /// Expired before anyone answered.
    public var isMissed: Bool { self == .timedOut }

    /// The outcome for an answer given on a phone. The Mac's own answers are
    /// `answeredOnMac`, whatever they were.
    public init(phoneStatus status: StewStatus) {
        switch status {
        case .approved: self = .approved
        case .denied: self = .denied
        case .answered, .acknowledged: self = .answered
        case .timeout: self = .timedOut
        case .dismissed, .shown, .error: self = .dismissed
        case .done: self = .done
        case .resolved: self = .resolvedByClaude
        case .later: self = .later
        }
    }
}

/// Mac to phone: the request is closed. First answer wins; the phone removes its
/// notification.
public struct LinkResolved: Codable, Equatable, Sendable {
    public var requestId: String
    public var outcome: LinkOutcome
    public var resolvedAt: Date
    /// The name of the phone that answered, as the Mac knows it. Nil when the Mac
    /// answered, the request ended without an answer, or the Mac is older.
    public var answeredOn: String?
    /// True in the copy for the phone that answered, so it says "this iPhone".
    public var answeredHere: Bool?

    public init(requestId: String, outcome: LinkOutcome, resolvedAt: Date = Date(), answeredOn: String? = nil, answeredHere: Bool? = nil) {
        self.requestId = requestId
        self.outcome = outcome
        self.resolvedAt = resolvedAt
        self.answeredOn = answeredOn
        self.answeredHere = answeredHere
    }
}

extension QuestionFlow {
    /// Rebuilds a phone's answers with the panel's own rules, so a phone answer reaches
    /// Claude in exactly the form a panel answer would. Nil when a question is left
    /// unanswered, an option is out of range, or a single-select question has several.
    public init?(set: QuestionSet, linkAnswers: [LinkQuestionAnswer]) {
        guard linkAnswers.count == set.questions.count else { return nil }
        var flow = QuestionFlow(questions: set.questions)
        for (questionIndex, answer) in linkAnswers.enumerated() {
            let question = set.questions[questionIndex]
            let selected = Array(Set(answer.selected)).sorted()
            guard selected.allSatisfy(question.options.indices.contains), question.multiSelect || selected.count <= 1 else { return nil }
            for optionIndex in selected {
                flow.go(to: questionIndex)
                _ = flow.choose(optionIndex)
            }
            if let other = answer.other, !other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                flow.go(to: questionIndex)
                _ = flow.answerOther(other)
            }
        }
        guard flow.isComplete else { return nil }
        self = flow
    }
}

/// Either side, to end a pairing.
public struct LinkUnpair: Codable, Equatable, Sendable {
    public var reason: String

    public init(reason: String) {
        self.reason = reason
    }
}
