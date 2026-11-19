import Foundation

/// Where someone heard about stew, as the account service names it. stewcli.com has no
/// analytics, so this one optional question is how the launch channels are told apart.
public enum HeardFromSource: String, CaseIterable, Codable, Sendable {
    case hackerNews = "hacker_news"
    case reddit
    case x
    case bluesky
    case productHunt = "product_hunt"
    case github
    case claudePluginDirectory = "claude_plugin_directory"
    case youtube
    case friend
    case search
    case other

    /// How Settings names the source.
    public var label: String {
        switch self {
        case .hackerNews: "Hacker News"
        case .reddit: "Reddit"
        case .x: "X"
        case .bluesky: "Bluesky"
        case .productHunt: "Product Hunt"
        case .github: "GitHub"
        case .claudePluginDirectory: "Claude Code plugin directory"
        case .youtube: "YouTube"
        case .friend: "A friend or colleague"
        case .search: "Search engine"
        case .other: "Other"
        }
    }
}

/// What the Mac sends: a source with an optional line of text, or a skip. Encodes as the
/// body of POST /v1/account/heard-from.
public enum HeardFromReply: Equatable, Sendable, Codable {
    case answer(HeardFromSource, detail: String?)
    case skip

    private enum CodingKeys: String, CodingKey {
        case source, detail, skipped
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decodeIfPresent(Bool.self, forKey: .skipped) == true {
            self = .skip
        } else {
            let source = try container.decode(HeardFromSource.self, forKey: .source)
            self = .answer(source, detail: try container.decodeIfPresent(String.self, forKey: .detail))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .answer(let source, let detail):
            try container.encode(source, forKey: .source)
            try container.encodeIfPresent(detail, forKey: .detail)
        case .skip:
            try container.encode(true, forKey: .skipped)
        }
    }
}

/// The answer as the account object reports it. The Mac does not show it; it only needs to
/// know that there is one.
public struct HeardFromAnswer: Codable, Equatable, Sendable {
    public var source: String?
    public var detail: String?
    public var skipped: Bool
    public var answeredAt: Date?

    public init(source: String? = nil, detail: String? = nil, skipped: Bool = false, answeredAt: Date? = nil) {
        self.source = source
        self.detail = detail
        self.skipped = skipped
        self.answeredAt = answeredAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try? container.decodeIfPresent(String.self, forKey: .source)
        detail = try? container.decodeIfPresent(String.self, forKey: .detail)
        skipped = (try? container.decodeIfPresent(Bool.self, forKey: .skipped)) ?? false
        answeredAt = try? container.decodeIfPresent(Date.self, forKey: .answeredAt)
    }
}

/// The account object's `heardFrom`, by whether the server has it at all.
public enum AccountHeardFrom: Equatable, Sendable {
    /// The field is missing: the account service predates the question, so it is not asked.
    case notOffered
    /// null: not answered or skipped yet.
    case unanswered
    case answered(HeardFromAnswer)
}

/// The "Where did you hear about stew?" question in Settings ▸ Account: what the user
/// picked and typed, when it shows, and what an answer from the server means. Asked once:
/// once the user sends or skips it on this Mac it never shows again for that account,
/// whatever the server answers.
public struct HeardFromQuestion: Equatable, Sendable {
    /// The longest text the server takes with Other.
    public static let longestDetail = 200

    public var source: HeardFromSource?
    /// The text for Other, as typed.
    public var detail = ""

    public init(source: HeardFromSource? = nil, detail: String = "") {
        self.source = source
        self.detail = detail
    }

    public var showsDetail: Bool { source == .other }
    public var canSend: Bool { source != nil }

    /// The text field's value kept to the server's limit.
    public static func limited(_ text: String) -> String {
        String(text.prefix(longestDetail))
    }

    /// What Send sends, or nil before a source is picked. Only Other carries the text,
    /// trimmed; empty is none.
    public var reply: HeardFromReply? {
        guard let source else { return nil }
        guard source == .other else { return .answer(source, detail: nil) }
        let trimmed = Self.limited(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        return .answer(source, detail: trimmed.isEmpty ? nil : trimmed)
    }

    /// Whether Settings shows the question: the server asks for it (`heardFrom` is null)
    /// and this Mac has not sent or skipped it for this account.
    public static func shows(account: Account?, doneFor: [String]) -> Bool {
        guard let account, account.heardFrom == .unanswered else { return false }
        return !doneFor.contains(account.id)
    }

    /// What became of a reply the Mac sent.
    public enum Outcome: Equatable, Sendable {
        /// Stored; the account as it is now.
        case stored(Account)
        /// Done without storing it, and never sent again: answered before (409), a server
        /// without the question (404), or a refusal that would only repeat.
        case dropped
        /// The Mac or the server was briefly away: send it once more at the next refresh.
        case retryLater
        /// The session is gone; the reply goes with it.
        case signedOut
    }

    public static func outcome(_ result: Result<Account, AccountError>) -> Outcome {
        switch result {
        case .success(let account): .stored(account)
        case .failure(.signedOut): .signedOut
        case .failure(let error) where error.isTransient: .retryLater
        case .failure: .dropped
        }
    }

    /// Whether to send a reply kept from an earlier failed try, now that the account came
    /// back: only while the server still has no answer for that account.
    public static func shouldResend(_ pending: HeardFromPending?, account: Account) -> Bool {
        guard let pending, pending.accountId == account.id else { return false }
        return account.heardFrom == .unanswered
    }
}

/// A reply that did not reach the server yet, kept in daemon-state.json for one more try.
public struct HeardFromPending: Codable, Equatable, Sendable {
    public var accountId: String
    public var reply: HeardFromReply

    public init(accountId: String, reply: HeardFromReply) {
        self.accountId = accountId
        self.reply = reply
    }
}
