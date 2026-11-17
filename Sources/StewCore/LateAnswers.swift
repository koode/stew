import Foundation

/// Where a request came from inside the agent, beyond the session: kept so a late
/// answer reaches the right agent and an approved blocked call can be retried.
public struct RequestOrigin: Codable, Equatable, Sendable {
    /// The subagent that asked, from the hook input's `agent_id`. Nil for the main agent.
    public var agentID: String?
    /// The tool auto mode blocked.
    public var toolName: String?
    /// Canonical JSON of the blocked call's input, the key of its one-shot retry grant.
    /// Raw, like the grants: it never goes into the history.
    public var callKey: String?
    /// True when the agent asks in its own prompt once stew gives no answer, as Codex
    /// does for an approval. The user answers there, so stew keeps no late answer.
    public var agentAsksOnTimeout: Bool?

    public init(agentID: String? = nil, toolName: String? = nil, callKey: String? = nil, agentAsksOnTimeout: Bool? = nil) {
        self.agentID = agentID
        self.toolName = toolName
        self.callKey = callKey
        self.agentAsksOnTimeout = agentAsksOnTimeout
    }
}

/// A request that timed out and can still be answered from the history.
public struct LateRequest: Codable, Equatable, Sendable {
    /// The history entry of the timeout.
    public var entryID: UUID
    /// The request as it was asked. Raw, so the file is private (0600) like the grants.
    public var request: StewRequest
    public var missed: Date

    public init(entryID: UUID, request: StewRequest, missed: Date) {
        self.entryID = entryID
        self.request = request
        self.missed = missed
    }

    public var sessionID: String? { request.session.id.flatMap { $0.isEmpty ? nil : $0 } }
}

/// An answer given after the time ran out, waiting for the session's next hook call.
public struct LateAnswer: Codable, Equatable, Sendable {
    public var entryID: UUID
    public var sessionID: String
    /// Only this subagent, or the main agent, may receive it. Nil: the main agent.
    public var agentID: String?
    /// What Claude reads, with secrets masked.
    public var message: String
    public var answered: Date
    public var delivered: Date?
    /// The hook event that delivered it, such as "Stop".
    public var deliveredBy: String?
    /// Set for a secret input: the question it answers. The message then holds
    /// `LateWording.secretToken` instead of the secret, which only the daemon keeps, in
    /// memory, until a hook fetches it.
    public var secretQuestion: String?

    public init(
        entryID: UUID, sessionID: String, agentID: String?, message: String, answered: Date,
        delivered: Date? = nil, deliveredBy: String? = nil, secretQuestion: String? = nil
    ) {
        self.entryID = entryID
        self.sessionID = sessionID
        self.agentID = agentID
        self.message = message
        self.answered = answered
        self.delivered = delivered
        self.deliveredBy = deliveredBy
        self.secretQuestion = secretQuestion
    }

    /// The message with the secret in it, or, when the daemon no longer has the secret
    /// (it restarted), a message that says it is lost.
    public func revealing(_ secret: String?) -> LateAnswer {
        guard let secretQuestion else { return self }
        var revealed = self
        if let secret {
            revealed.message = message.replacingOccurrences(of: LateWording.secretToken, with: secret)
        } else {
            revealed.message = LateWording.secretLost(question: secretQuestion)
        }
        return revealed
    }
}

/// late-answers.json: timed-out requests that can still be answered, and answers given
/// late, per agent session. Pure: callers load and save it under a lock.
public struct LateMailbox: Codable, Equatable, Sendable {
    /// A timed-out request can be answered for this long, and an answer that no hook
    /// picked up is dropped after it. Delivered answers stay as long, for the history.
    public static let lifetime: TimeInterval = 24 * 60 * 60

    public var waiting: [LateRequest]
    public var answers: [LateAnswer]

    public init(waiting: [LateRequest] = [], answers: [LateAnswer] = []) {
        self.waiting = waiting
        self.answers = answers
    }

    public var isEmpty: Bool { waiting.isEmpty && answers.isEmpty }

    /// After the history is cleared: requests that wait for a late answer have no row
    /// left to answer them from, and delivered answers have no row to show in. Answers
    /// not yet delivered stay, because Claude still has to get them.
    public mutating func forgetHistory() {
        waiting.removeAll()
        answers.removeAll { $0.delivered != nil }
    }

    public mutating func prune(now: Date) {
        waiting.removeAll { now.timeIntervalSince($0.missed) >= Self.lifetime }
        answers.removeAll { now.timeIntervalSince($0.answered) >= Self.lifetime }
    }

    /// Only requests of a known session can be answered late after a timeout: the
    /// answer needs a session to go to. Permission requests, questions and inputs; a
    /// secret's late answer is held in the daemon's memory, never in this file.
    public static func canAnswerLate(_ request: StewRequest) -> Bool {
        guard let id = request.session.id, !id.isEmpty, request.origin?.agentAsksOnTimeout != true else { return false }
        switch request.prompt {
        case .permission, .question, .input: return true
        case .notify, .needs: return false
        }
    }

    /// Adds a request that timed out, or a secret input the user will enter later.
    public mutating func addWaiting(_ request: StewRequest, entryID: UUID, now: Date) {
        guard Self.canAnswerLate(request) || request.offersEnterLater else { return }
        waiting.removeAll { $0.entryID == entryID }
        waiting.append(LateRequest(entryID: entryID, request: request, missed: now))
    }

    public func waiting(_ entryID: UUID, now: Date) -> LateRequest? {
        waiting.first { $0.entryID == entryID && now.timeIntervalSince($0.missed) < Self.lifetime }
    }

    public func answer(_ entryID: UUID) -> LateAnswer? {
        answers.first { $0.entryID == entryID }
    }

    /// Records the user's late answer to a waiting request and returns it. Nil when the
    /// request is no longer waiting (answered already, or too old), or the response is
    /// not an answer: closing the panel leaves the request waiting.
    @discardableResult
    public mutating func answer(_ entryID: UUID, with response: StewResponse, now: Date) -> LateAnswer? {
        prune(now: now)
        guard let index = waiting.firstIndex(where: { $0.entryID == entryID }),
              let sessionID = waiting[index].sessionID,
              let message = LateWording.message(for: waiting[index].request, response: response) else { return nil }
        let request = waiting.remove(at: index).request
        var secretQuestion: String?
        if case .input(let input) = request.prompt, input.secret { secretQuestion = CommandText.masked(input.question) }
        let late = LateAnswer(
            entryID: entryID, sessionID: sessionID, agentID: request.origin?.agentID, message: message, answered: now,
            secretQuestion: secretQuestion
        )
        answers.append(late)
        return late
    }

    /// Whether a hook call from this session and agent has something to receive.
    public func hasMail(sessionID: String?, agentID: String?, now: Date) -> Bool {
        !pending(sessionID: sessionID, agentID: agentID, now: now).isEmpty
    }

    /// Marks the session's undelivered answers delivered and returns them, oldest first.
    /// The main agent (no agent id) gets every answer of its session; a subagent only
    /// its own. Another session never gets anything.
    public mutating func deliver(sessionID: String?, agentID: String?, event: String, now: Date) -> [LateAnswer] {
        prune(now: now)
        let indices = pending(sessionID: sessionID, agentID: agentID, now: now)
        for index in indices {
            answers[index].delivered = now
            answers[index].deliveredBy = event
        }
        return indices.map { answers[$0] }
    }

    private func pending(sessionID: String?, agentID: String?, now: Date) -> [Int] {
        guard let sessionID, !sessionID.isEmpty else { return [] }
        return answers.indices.filter { index in
            let late = answers[index]
            return late.sessionID == sessionID && late.delivered == nil
                && now.timeIntervalSince(late.answered) < Self.lifetime
                && (agentID == nil || late.agentID == agentID)
        }
        .sorted { answers[$0].answered < answers[$1].answered }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func decode(_ data: Data) -> LateMailbox {
        guard !data.isEmpty else { return LateMailbox() }
        return (try? decoder.decode(LateMailbox.self, from: data)) ?? LateMailbox()
    }

    public static func encode(_ mailbox: LateMailbox) throws -> Data {
        try encoder.encode(mailbox)
    }
}

/// What Claude reads when a late answer arrives. Plain and short, marked as the user's
/// answer through stew, with commands masked the way the history masks them.
public enum LateWording {
    static let prefix = "Late answer from the user, through stew."

    public static func message(for request: StewRequest, response: StewResponse) -> String? {
        let note = response.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let noteText = note.isEmpty ? "" : " Their note: \(note)"
        switch (request.prompt, response.status) {
        case (.permission(let permission), .approved):
            let call = describe(permission)
            if permission.blocked != nil, request.origin?.callKey != nil {
                return "\(prefix) Your earlier request timed out, and the user has now approved it: \(call). Auto mode blocked this call; retry it if it is still needed, and the identical call will go through once.\(noteText)"
            }
            return "\(prefix) Your earlier request timed out, and the user has now approved it: \(call). You may run it now if it is still relevant.\(noteText)"
        case (.permission(let permission), .denied):
            return "\(prefix) Your earlier request timed out, and the user has now declined it: \(describe(permission)). Do not run it.\(noteText)"
        case (.question(let questionSet), .answered):
            let answers = response.answers ?? [:]
            let pairs = questionSet.questions.compactMap { question in
                answers[question.question].map { "\"\(question.question)\"=\"\($0)\"" }
            }
            guard !pairs.isEmpty else { return nil }
            return "\(prefix) Your earlier question timed out, and the user has now answered it: \(pairs.joined(separator: ", ")). These answers replace the timeout; continue with them in mind if they are still relevant.\(noteText)"
        case (.input(let input), .answered) where input.secret:
            // The secret itself never goes into the file: the daemon puts it in place of
            // the token when a hook fetches the answer.
            return "\(prefix) The user has now entered the secret you asked for (\"\(CommandText.masked(input.question))\"): \(secretToken) Use it only for what you asked it for, and do not write it to files, logs or messages."
        case (.input(let input), .answered):
            guard let text = response.text else { return nil }
            return "\(prefix) Your earlier question timed out, and the user has now answered it: \"\(CommandText.masked(input.question))\"=\"\(text)\". This answer replaces the timeout; continue with it in mind if it is still relevant."
        default:
            return nil
        }
    }

    /// Stands for a secret in a stored message, until the daemon puts the secret in.
    public static let secretToken = "[secret kept in stew's memory]"

    /// Told when the daemon restarted between the user entering a secret and a hook
    /// fetching it: it was never written down, so it is gone.
    public static func secretLost(question: String) -> String {
        "\(prefix) The user entered the secret you asked for (\"\(question)\"), but stew restarted before it reached you, and stew never stores secrets, so it is gone. If you still need it, ask again with stew input --secret."
    }

    /// Several answers for one hook call, in the order they were given.
    public static func combined(_ answers: [LateAnswer]) -> String? {
        answers.isEmpty ? nil : answers.map(\.message).joined(separator: "\n\n")
    }

    private static func describe(_ permission: PermissionRequest) -> String {
        let action = CommandText.masked(permission.action)
        guard let command = permission.command, !command.isEmpty else { return action }
        return "\(action) (`\(CommandText.masked(command))`)"
    }
}
