import Foundation

/// Identifies the Claude session a request comes from, so several sessions can share one panel.
public struct SessionInfo: Codable, Equatable, Sendable {
    public var name: String
    public var id: String?
    public var cwd: String?

    public init(name: String, id: String? = nil, cwd: String? = nil) {
        self.name = name
        self.id = id
        self.cwd = cwd
    }

    /// First block of the session UUID, enough to tell sessions apart at a glance.
    public var shortID: String? {
        guard let id, !id.isEmpty else { return nil }
        return String(id.split(separator: "-").first ?? Substring(id))
    }
}

public struct PermissionRequest: Codable, Equatable, Sendable {
    /// What Claude will do, in plain words.
    public var action: String
    /// The exact command, when there is one.
    public var command: String?
    /// Why Claude needs it.
    public var reason: String
    /// Set when the request comes from the auto mode hook: the call auto mode blocked.
    public var blocked: BlockedCall?

    public init(action: String, command: String? = nil, reason: String, blocked: BlockedCall? = nil) {
        self.action = action
        self.command = command
        self.reason = reason
        self.blocked = blocked
    }
}

public enum NotifyLevel: String, Codable, Sendable, CaseIterable {
    case info, success, warning, error
}

/// What the OK button of a notification does besides closing it.
public enum NotifyAction: String, Codable, Sendable {
    /// The return summary: open the history of missed requests.
    case openHistory
    /// A new version is available: "Install now" installs it, "Later" closes the panel.
    case installUpdate
}

/// A link shown beside the buttons of a notification, such as the release notes.
public struct NotifyLink: Codable, Equatable, Sendable {
    public var title: String
    public var url: String

    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

public struct NotifyRequest: Codable, Equatable, Sendable {
    public var title: String
    public var body: String?
    public var level: NotifyLevel
    public var action: NotifyAction?
    public var link: NotifyLink?

    public init(title: String, body: String? = nil, level: NotifyLevel = .info, action: NotifyAction? = nil, link: NotifyLink? = nil) {
        self.title = title
        self.body = body
        self.level = level
        self.action = action
        self.link = link
    }
}

/// Same shape as the AskUserQuestion tool input.
public struct QuestionOption: Codable, Equatable, Sendable {
    public var label: String
    public var description: String
    public var preview: String?

    public init(label: String, description: String, preview: String? = nil) {
        self.label = label
        self.description = description
        self.preview = preview
    }
}

public struct Question: Codable, Equatable, Sendable {
    public var question: String
    public var header: String
    public var options: [QuestionOption]
    public var multiSelect: Bool

    public init(question: String, header: String, options: [QuestionOption], multiSelect: Bool = false) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        question = try container.decode(String.self, forKey: .question)
        header = try container.decodeIfPresent(String.self, forKey: .header) ?? ""
        options = try container.decode([QuestionOption].self, forKey: .options)
        multiSelect = try container.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
    }
}

public struct QuestionSet: Codable, Equatable, Sendable {
    public var questions: [Question]

    public init(questions: [Question]) {
        self.questions = questions
    }

    public struct ValidationError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// Enforces the same limits as AskUserQuestion: 1-4 questions, 2-4 options each.
    public func validate() throws {
        guard (1...4).contains(questions.count) else {
            throw ValidationError(description: "expected 1-4 questions, got \(questions.count)")
        }
        var seenQuestions = Set<String>()
        for question in questions {
            guard !question.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError(description: "a question has empty text")
            }
            guard seenQuestions.insert(question.question).inserted else {
                throw ValidationError(description: "duplicate question text: \(question.question)")
            }
            guard (2...4).contains(question.options.count) else {
                throw ValidationError(description: "\"\(question.question)\": expected 2-4 options, got \(question.options.count)")
            }
            let labels = question.options.map(\.label)
            guard Set(labels).count == labels.count else {
                throw ValidationError(description: "\"\(question.question)\": option labels must be unique")
            }
        }
    }
}

public enum Prompt: Equatable, Sendable {
    case permission(PermissionRequest)
    case notify(NotifyRequest)
    case question(QuestionSet)
    case needs(NeedsRequest)
    case input(InputRequest)

    public var kind: String {
        switch self {
        case .permission: "permission"
        case .notify: "notify"
        case .question: "question"
        case .needs: "needs"
        case .input: "input"
        }
    }
}

public struct StewRequest: Codable, Equatable, Sendable {
    public var session: SessionInfo
    public var prompt: Prompt
    /// Seconds the user has to answer once the request is on screen. Nil uses the
    /// configured `responseTimeout` (permissions and questions only); 0 means no limit.
    public var timeout: Double?
    /// Hard ceiling in seconds from arrival, even with "more time". The hook sets it to
    /// stay inside Claude Code's hook timeout.
    public var maxWait: Double?
    /// For notifications and needs items: block until the user acknowledges, or marks it
    /// done or declines it. Other kinds always wait.
    public var wait: Bool
    /// Set by the hooks: the asking agent and the blocked call, for a late answer.
    public var origin: RequestOrigin?

    public init(session: SessionInfo, prompt: Prompt, timeout: Double? = nil, maxWait: Double? = nil, wait: Bool = true, origin: RequestOrigin? = nil) {
        self.session = session
        self.prompt = prompt
        self.timeout = timeout
        self.maxWait = maxWait
        self.wait = wait
        self.origin = origin
    }

    private enum CodingKeys: String, CodingKey {
        case kind, session, timeout, maxWait, wait, origin, permission, notify, question, needs, input
    }

    /// The effective time limit, given the configured default. Nil means none.
    public func timeLimit(defaultTimeout: Double) -> Double? {
        let fallback: Double?
        switch prompt {
        case .permission, .question, .input: fallback = defaultTimeout
        case .notify: fallback = nil
        case .needs:
            // A needs item has no time to answer: it stays open until it is done.
            // `timeout` only limits how long a waiting caller waits.
            return nil
        }
        guard let limit = timeout ?? fallback, limit > 0 else { return nil }
        return limit
    }

    /// The note Claude gets when nobody answered in time.
    public func timeoutNote(after seconds: Double) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        let span = seconds < 60 ? "\(Int(seconds)) s" : "\(minutes) min"
        // A late answer can reach only a request with a known session.
        let late = LateMailbox.canAnswerLate(self)
            ? " If they answer later, stew passes their answer on to you as a late answer, which replaces this timeout."
            : ""
        switch prompt {
        case .question, .input:
            return "The user didn't answer within \(span). They may be away: continue with a safe choice that does not need this answer, or ask again later.\(late)"
        case .permission, .notify:
            return "The user didn't respond within \(span). They may be away: treat this as denied and continue another way, or ask again later.\(late)"
        case .needs:
            return "The user has not done this within \(span). It stays open in stew: continue with work that does not need it, and run `stew needs resolve ID` once you can see it is done."
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        session = try container.decode(SessionInfo.self, forKey: .session)
        timeout = try container.decodeIfPresent(Double.self, forKey: .timeout)
        maxWait = try container.decodeIfPresent(Double.self, forKey: .maxWait)
        wait = try container.decodeIfPresent(Bool.self, forKey: .wait) ?? true
        origin = try container.decodeIfPresent(RequestOrigin.self, forKey: .origin)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "permission":
            prompt = .permission(try container.decode(PermissionRequest.self, forKey: .permission))
        case "notify":
            prompt = .notify(try container.decode(NotifyRequest.self, forKey: .notify))
        case "question":
            prompt = .question(try container.decode(QuestionSet.self, forKey: .question))
        case "needs":
            prompt = .needs(try container.decode(NeedsRequest.self, forKey: .needs))
        case "input":
            prompt = .input(try container.decode(InputRequest.self, forKey: .input))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown kind \(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(prompt.kind, forKey: .kind)
        try container.encode(session, forKey: .session)
        try container.encodeIfPresent(timeout, forKey: .timeout)
        try container.encodeIfPresent(maxWait, forKey: .maxWait)
        try container.encode(wait, forKey: .wait)
        try container.encodeIfPresent(origin, forKey: .origin)
        switch prompt {
        case .permission(let permission): try container.encode(permission, forKey: .permission)
        case .notify(let notify): try container.encode(notify, forKey: .notify)
        case .question(let questionSet): try container.encode(questionSet, forKey: .question)
        case .needs(let needs): try container.encode(needs, forKey: .needs)
        case .input(let input): try container.encode(input, forKey: .input)
        }
    }
}

public enum StewStatus: String, Codable, Sendable {
    case approved, denied, answered, acknowledged, shown, dismissed, timeout, error
    /// A needs item: the user marked it done, or Claude or a new message cleared it.
    /// One of its other answers is `answered`.
    case done, resolved
    /// A secret input: the user will enter it on the Mac later, and it reaches Claude as
    /// a late answer.
    case later
}

public struct QuestionAnnotation: Codable, Equatable, Sendable {
    public var notes: String?
    public var preview: String?

    public init(notes: String? = nil, preview: String? = nil) {
        self.notes = notes
        self.preview = preview
    }
}

public struct StewResponse: Codable, Equatable, Sendable {
    public var status: StewStatus
    /// Free text the user typed alongside a permission answer.
    public var note: String?
    /// AskUserQuestion-style answers: question text to chosen label(s) or typed text.
    public var answers: [String: String]?
    public var annotations: [String: QuestionAnnotation]?
    /// The risk assessment the user saw, for permission requests.
    public var risk: RiskAssessment?
    /// A standing approval chosen alongside the answer.
    public var grant: GrantChoice?
    /// The needs item this answer is about, for `stew needs resolve ID`.
    public var id: String?
    /// For a needs item with its own answers: the label of the one the user picked,
    /// the Done label with "done" or one of the other answers with "answered".
    public var answer: String?
    /// What the user typed into an input.
    public var text: String?
    public var error: String?

    public init(
        status: StewStatus,
        note: String? = nil,
        answers: [String: String]? = nil,
        annotations: [String: QuestionAnnotation]? = nil,
        risk: RiskAssessment? = nil,
        grant: GrantChoice? = nil,
        id: String? = nil,
        answer: String? = nil,
        text: String? = nil,
        error: String? = nil
    ) {
        self.status = status
        self.note = note
        self.answers = answers
        self.annotations = annotations
        self.risk = risk
        self.grant = grant
        self.id = id
        self.answer = answer
        self.text = text
        self.error = error
    }

    /// Exit codes let a shell caller branch without parsing JSON: `stew permit ... && run`.
    public var exitCode: Int32 {
        switch status {
        case .approved, .answered, .acknowledged, .shown, .done, .resolved: 0
        case .denied: 1
        case .dismissed: 2
        case .timeout: 3
        case .error: 4
        case .later: 5
        }
    }

    /// What Claude reads when the user will enter a secret later.
    public static let laterNote = "The user will enter this secret on their Mac later. stew passes it to you as a late answer when they do, which replaces this status. Do not ask for it again meanwhile: continue with work that does not need it."
}

/// Verdict of the auto mode style check, shown above a command.
public struct RiskAssessment: Codable, Equatable, Sendable {
    public enum Verdict: String, Codable, Sendable {
        case allow
        case softDeny = "soft_deny"
        case hardDeny = "hard_deny"
    }

    public enum Level: String, Codable, Sendable {
        case low, medium, high
    }

    public var verdict: Verdict
    public var risk: Level
    /// Name of the auto mode rule that decided it, when one did.
    public var rule: String?
    public var summary: String

    public init(verdict: Verdict, risk: Level, rule: String?, summary: String) {
        self.verdict = verdict
        self.risk = risk
        self.rule = rule
        self.summary = summary
    }

    /// Auto mode rule names carry a bracketed hint after the name ("Git Destructive [named+specifics ...]").
    public var ruleName: String? {
        guard let rule, !rule.isEmpty else { return nil }
        let name = rule.split(separator: "[").first.map(String.init) ?? rule
        let trimmed = name.split(separator: ":").first.map(String.init) ?? name
        return trimmed.trimmingCharacters(in: .whitespaces)
    }
}

/// One JSON object per line on the socket.
public enum Wire {
    public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<Value: Decodable>(_ type: Value.Type, line: Data) throws -> Value {
        try JSONDecoder().decode(type, from: line)
    }
}

/// Control messages that are not prompts.
public struct ControlMessage: Codable, Sendable {
    public var control: String

    public init(control: String) {
        self.control = control
    }
}
