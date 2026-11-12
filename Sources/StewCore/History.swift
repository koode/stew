import Foundation

/// One finished request, as kept in history.jsonl. Commands are stored masked, so the
/// history never holds a secret that the panel would have hidden.
public struct HistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Outcome: String, Codable, Sendable, CaseIterable {
        case approved, denied, answered, acknowledged, timedOut, dismissed, callerGone
        /// Needs items: the user did it, Claude saw it was done, the user wrote to the
        /// session, or a later turn of the session ended without needing it any more.
        case done, resolvedByClaude, answeredInSession, movedOn

        public var label: String {
            switch self {
            case .approved: "Approved"
            case .denied: "Denied"
            case .answered: "Answered"
            case .acknowledged: "Acknowledged"
            case .timedOut: "Timed out"
            case .dismissed: "Dismissed"
            case .callerGone: "Caller gone"
            case .done: "Done"
            case .resolvedByClaude: "Resolved by Claude"
            case .answeredInSession: "Answered in session"
            case .movedOn: "Moved on"
            }
        }
    }

    public var id: UUID
    public var received: Date
    public var ended: Date
    public var session: String
    public var cwd: String?
    /// "permission", "question", "notify" or "needs".
    public var kind: String
    /// The action, the first question, or the notification title.
    public var summary: String
    /// The command with secrets replaced by ••••.
    public var command: String?
    /// The reason, the notification body, or every question with its options.
    public var detail: String?
    public var outcome: Outcome
    public var answers: [String: String]?
    public var grant: GrantChoice?
    /// What Claude was told besides the status: the user's note or the timeout note.
    public var note: String?
    /// Set for a call that auto mode blocked, so a missed one can still be allowed.
    public var blocked: BlockedCall?

    /// Missed means the time ran out. Closing a request yourself is an answer, not a miss.
    public var missed: Bool { outcome == .timedOut }

    public init(
        id: UUID = UUID(), received: Date, ended: Date, session: String, cwd: String?, kind: String, summary: String,
        command: String?, detail: String?, outcome: Outcome, answers: [String: String]? = nil, grant: GrantChoice? = nil,
        note: String? = nil, blocked: BlockedCall? = nil
    ) {
        self.id = id
        self.received = received
        self.ended = ended
        self.session = session
        self.cwd = cwd
        self.kind = kind
        self.summary = summary
        self.command = command
        self.detail = detail
        self.outcome = outcome
        self.answers = answers
        self.grant = grant
        self.note = note
        self.blocked = blocked
    }

    /// The entry for a request that ended with `response`, or with no response when
    /// the caller went away first.
    public static func record(_ request: StewRequest, received: Date, response: StewResponse?, ended: Date, id: UUID = UUID()) -> HistoryEntry {
        var summary: String
        var command: String?
        var detail: String?
        var blocked: BlockedCall?
        switch request.prompt {
        case .permission(let permission):
            summary = permission.action
            command = permission.command.map { CommandText.masked($0) }
            detail = permission.reason
            blocked = permission.blocked
        case .question(let set):
            summary = set.questions.first?.question ?? ""
            if set.questions.count > 1 { summary += " (+\(set.questions.count - 1) more)" }
            detail = set.questions.map { question in
                ([question.question] + question.options.map { "  - \($0.label)" }).joined(separator: "\n")
            }.joined(separator: "\n\n")
        case .notify(let notify):
            summary = notify.title
            detail = notify.body
        case .needs(let needs):
            summary = needs.title
            command = needs.maskedCommands
            detail = needs.historyDetail
        }
        return HistoryEntry(
            id: id, received: received, ended: ended, session: request.session.name, cwd: request.session.cwd,
            kind: request.prompt.kind, summary: summary, command: command, detail: detail,
            outcome: outcome(of: response), answers: response?.answers, grant: response?.grant,
            note: response?.note, blocked: blocked
        )
    }

    static func outcome(of response: StewResponse?) -> Outcome {
        guard let response else { return .callerGone }
        switch response.status {
        case .approved: return .approved
        case .denied: return .denied
        case .answered: return .answered
        case .acknowledged, .shown: return .acknowledged
        case .timeout: return .timedOut
        case .dismissed, .error: return .dismissed
        case .done: return .done
        case .resolved: return .resolvedByClaude
        }
    }

    /// The entry for a needs item that ended. Only final outcomes are recorded: "Not now"
    /// keeps the item open, so it is not one.
    public static func record(_ item: NeedsItem, outcome: Outcome, note: String?, ended: Date, id: UUID = UUID()) -> HistoryEntry {
        HistoryEntry(
            id: id, received: item.created, ended: ended, session: item.session.name, cwd: item.session.cwd,
            kind: "needs", summary: item.needs.title, command: item.needs.maskedCommands, detail: item.needs.historyDetail,
            outcome: outcome, note: note
        )
    }
}

extension NeedsRequest {
    /// Commands with secrets replaced by ••••, one per line, as the history keeps them.
    var maskedCommands: String? {
        commands.isEmpty ? nil : commands.map { CommandText.masked($0.command) }.joined(separator: "\n")
    }

    /// Why, the numbered steps and the links, as one block of text.
    var historyDetail: String? {
        var parts: [String] = []
        if let why, !why.isEmpty { parts.append(why) }
        if !steps.isEmpty { parts.append(steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")) }
        if !links.isEmpty { parts.append(links.map(\.url).joined(separator: "\n")) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}

/// Reading, pruning and filtering history.jsonl: one JSON entry per line.
public enum History {
    public static let defaultKeepDays = 30

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func line(_ entry: HistoryEntry) throws -> Data {
        try encoder.encode(entry) + Data("\n".utf8)
    }

    public static func lines(_ entries: [HistoryEntry]) throws -> Data {
        try entries.reduce(into: Data()) { data, entry in data += try line(entry) }
    }

    /// The entries in file order. A line that does not parse (a half-written line after
    /// a crash, or a field from a newer version) is skipped, not fatal.
    public static func parse(_ data: Data) -> [HistoryEntry] {
        data.split(separator: 0x0A).compactMap { line in try? decoder.decode(HistoryEntry.self, from: Data(line)) }
    }

    public static func json(_ entries: [HistoryEntry]) throws -> Data {
        try encoder.encode(entries)
    }

    /// Entries that ended within the last `keepDays` days.
    public static func pruned(_ entries: [HistoryEntry], now: Date, keepDays: Int) -> [HistoryEntry] {
        let cutoff = now.addingTimeInterval(-Double(max(keepDays, 0)) * 24 * 60 * 60)
        return entries.filter { $0.ended >= cutoff }
    }

    /// Newest first, optionally only the missed ones.
    public static func filtered(_ entries: [HistoryEntry], missedOnly: Bool) -> [HistoryEntry] {
        entries.filter { !missedOnly || $0.missed }.sorted { $0.ended > $1.ended }
    }

    /// Requests that timed out at or after `since`.
    public static func missed(_ entries: [HistoryEntry], since: Date) -> [HistoryEntry] {
        entries.filter { $0.missed && $0.ended >= since }
    }

    /// The return summary's title.
    public static func returnSummary(missedCount: Int) -> String {
        missedCount == 1 ? "1 request timed out while you were away" : "\(missedCount) requests timed out while you were away"
    }
}

/// Notices when the user comes back to the Mac: no input for `threshold` seconds, then
/// input again. Fed with the seconds since the last input event, every few seconds.
public struct AwayTracker: Sendable {
    public let threshold: TimeInterval
    public private(set) var awaySince: Date?

    public init(threshold: TimeInterval = 120) {
        self.threshold = threshold
    }

    /// Returns when the user left, at the moment they come back; nil otherwise.
    public mutating func observe(idleSeconds: TimeInterval, now: Date) -> Date? {
        if idleSeconds >= threshold {
            if awaySince == nil { awaySince = now.addingTimeInterval(-idleSeconds) }
            return nil
        }
        guard let since = awaySince else { return nil }
        awaySince = nil
        return since
    }
}
