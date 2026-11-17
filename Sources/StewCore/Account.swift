import Foundation

/// The "account" object in config.json: where the account service runs.
public struct AccountConfig: Codable, Equatable, Sendable {
    public static let defaultServer = "https://account.stewcli.com"

    /// Base URL of the account service. Tests and development point it at a local relay.
    public var server: String

    public init(server: String = AccountConfig.defaultServer) {
        self.server = server
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        server = try container.decodeIfPresent(String.self, forKey: .server) ?? Self.defaultServer
    }

    /// The server without a trailing slash, or nil when it is not an http(s) URL.
    public var serverURL: URL? {
        var trimmed = server.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }
}

/// A plan's status as the account service names it. A status this build does not know
/// keeps its name and counts as not paid, so a newer server never breaks the pane.
public enum AccountPlanStatus: Equatable, Sendable, Codable {
    case trial, active, pastDue, canceled, expired
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "trial": self = .trial
        case "active": self = .active
        case "past_due": self = .pastDue
        case "canceled": self = .canceled
        case "expired": self = .expired
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .trial: "trial"
        case .active: "active"
        case .pastDue: "past_due"
        case .canceled: "canceled"
        case .expired: "expired"
        case .other(let name): name
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// How often a paid plan renews. An interval this build does not know keeps its name.
public enum AccountBillingInterval: Equatable, Sendable, Codable {
    case month, year
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "month": self = .month
        case "year": self = .year
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .month: "month"
        case .year: "year"
        case .other(let name): name
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct AccountPlan: Codable, Equatable, Sendable {
    public var status: AccountPlanStatus
    public var trialEndsAt: Date?
    public var currentPeriodEnd: Date?
    public var cancelAtPeriodEnd: Bool
    public var interval: AccountBillingInterval?

    public init(
        status: AccountPlanStatus, trialEndsAt: Date? = nil, currentPeriodEnd: Date? = nil, cancelAtPeriodEnd: Bool = false,
        interval: AccountBillingInterval? = nil
    ) {
        self.status = status
        self.trialEndsAt = trialEndsAt
        self.currentPeriodEnd = currentPeriodEnd
        self.cancelAtPeriodEnd = cancelAtPeriodEnd
        self.interval = interval
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(AccountPlanStatus.self, forKey: .status)
        trialEndsAt = try container.decodeIfPresent(Date.self, forKey: .trialEndsAt)
        currentPeriodEnd = try container.decodeIfPresent(Date.self, forKey: .currentPeriodEnd)
        cancelAtPeriodEnd = try container.decodeIfPresent(Bool.self, forKey: .cancelAtPeriodEnd) ?? false
        interval = try container.decodeIfPresent(AccountBillingInterval.self, forKey: .interval)
    }
}

/// One way to subscribe: the Mac shows `label` on a button that opens `url` in the browser,
/// and never shows a price of its own.
public struct AccountOffer: Codable, Equatable, Sendable {
    public var interval: AccountBillingInterval
    public var amount: Int?
    public var currency: String?
    public var label: String
    public var url: URL

    public init(interval: AccountBillingInterval, amount: Int? = nil, currency: String? = nil, label: String, url: URL) {
        self.interval = interval
        self.amount = amount
        self.currency = currency
        self.label = label
        self.url = url
    }

    /// Hosts whose pages the Mac opens for checkout and billing, with their subdomains.
    public static let allowedHosts = ["stripe.com", "stewcli.com"]

    /// Whether the Mac may open `url` in the browser: https on an allowed host, or a page of
    /// the account server itself (a local server in development). Anything else could send
    /// the user to a page whoever runs the server chose.
    public static func mayOpen(_ url: URL, server: URL?) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil,
              let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased(), !host.isEmpty else { return false }
        if let server, let serverHost = server.host?.lowercased(), host == serverHost,
           scheme == server.scheme?.lowercased(), components.port == server.port {
            return true
        }
        guard scheme == "https", components.port == nil || components.port == 443 else { return false }
        return allowedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// The account as GET /v1/account returns it.
public struct Account: Codable, Equatable, Sendable {
    public var id: String
    public var email: String
    public var plan: AccountPlan
    public var entitled: Bool
    public var offers: [AccountOffer]
    /// Present while `entitled`. The Mac stores and forwards it, and never reads it.
    public var lease: String?

    public init(id: String, email: String, plan: AccountPlan, entitled: Bool, offers: [AccountOffer] = [], lease: String? = nil) {
        self.id = id
        self.email = email
        self.plan = plan
        self.entitled = entitled
        self.offers = offers
        self.lease = lease
    }

    /// One offer that does not decode, such as one with a missing label or a bad URL, is
    /// left out; the rest still show.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        email = try container.decode(String.self, forKey: .email)
        plan = try container.decode(AccountPlan.self, forKey: .plan)
        entitled = try container.decodeIfPresent(Bool.self, forKey: .entitled) ?? false
        let lossy = try container.decodeIfPresent([Lossy<AccountOffer>].self, forKey: .offers) ?? []
        offers = lossy.compactMap(\.value)
        let leaseText = try container.decodeIfPresent(String.self, forKey: .lease)
        lease = leaseText?.isEmpty == false ? leaseText : nil
    }

    /// The offers the Mac shows and may open, in the server's order. None while a payment
    /// failed: the fix is a new payment method in billing, and a second checkout would
    /// start a second subscription.
    public func openableOffers(server: URL?) -> [AccountOffer] {
        guard plan.status != .pastDue else { return [] }
        return offers.filter { AccountOffer.mayOpen($0.url, server: server) && !$0.label.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

/// Decodes an element, or holds nil when it does not decode.
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// What POST /v1/sign-in returns: the handle the Mac polls with and sends the code with.
public struct SignInStart: Codable, Equatable, Sendable {
    public var signInId: String
    public var pollToken: String
    /// On the server's clock.
    public var expiresAt: Date
    /// The response's Date header: the server's clock when it answered. Not in the body.
    public var serverDate: Date?

    private enum CodingKeys: String, CodingKey {
        case signInId, pollToken, expiresAt
    }

    public init(signInId: String, pollToken: String, expiresAt: Date, serverDate: Date? = nil) {
        self.signInId = signInId
        self.pollToken = pollToken
        self.expiresAt = expiresAt
        self.serverDate = serverDate
    }

    /// How long the sign-in had left when the server answered, independent of this Mac's
    /// clock; nil without the server's Date header.
    public var lifetime: TimeInterval? {
        serverDate.map { max(0, expiresAt.timeIntervalSince($0)) }
    }
}

/// A finished sign-in: the session token to keep and the account it opens.
public struct SignedIn: Codable, Equatable, Sendable {
    public var sessionToken: String
    public var account: Account

    public init(sessionToken: String, account: Account) {
        self.sessionToken = sessionToken
        self.account = account
    }
}

/// What one poll of a sign-in learned.
public enum SignInPoll: Equatable, Sendable {
    case pending
    case approved(SignedIn)
}

/// The account service's refusals, read by error code, and the ways a call can fail
/// before the service answers.
public enum AccountError: Error, Equatable, Sendable {
    /// No response: the Mac is offline or the server is down.
    case offline
    case invalidEmail
    /// Seconds to wait, when the server named them.
    case rateLimited(retryAfter: Int?)
    /// The sign-in expired, was used, or took too many wrong codes.
    case expired
    case wrongCode(attemptsLeft: Int?)
    /// The session token is unknown or revoked.
    case signedOut
    /// Billing has nothing to manage: the account never paid.
    case noCustomer
    /// A 5xx without an error code: a proxy's page in place of the server's answer.
    case unavailable(status: Int)
    /// Any other refusal, with the server's code and message.
    case server(status: Int, code: String?, message: String?)
    /// A success whose body the Mac cannot read.
    case badResponse

    private struct Body: Decodable {
        let error: String
        let message: String?
        let retryAfter: Int?
        let attemptsLeft: Int?
    }

    /// Reads a response that is not a success. The code decides; the status only where
    /// the body has none.
    public static func read(status: Int, body: Data, retryAfterHeader: String? = nil) -> AccountError {
        let decoded = try? JSONDecoder().decode(Body.self, from: body)
        let headerWait = retryAfterHeader.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        switch decoded?.error {
        case "invalid_email": return .invalidEmail
        case "rate_limited": return .rateLimited(retryAfter: decoded?.retryAfter ?? headerWait)
        case "expired": return .expired
        case "wrong_code": return .wrongCode(attemptsLeft: decoded?.attemptsLeft)
        case "signed_out": return .signedOut
        case "no_customer": return .noCustomer
        case let code?: return .server(status: status, code: code, message: decoded?.message)
        case nil:
            switch status {
            case 401: return .signedOut
            case 410: return .expired
            case 429: return .rateLimited(retryAfter: headerWait)
            case 500..<600: return .unavailable(status: status)
            default: return .server(status: status, code: nil, message: nil)
            }
        }
    }

    /// One line for the user. `host` names the account server, as in "Cannot reach …".
    public func message(host: String) -> String {
        switch self {
        case .offline: return "Cannot reach \(host). Check the connection, then try again."
        case .invalidEmail: return "This email address does not look right."
        case .rateLimited(let seconds):
            guard let seconds, seconds > 0 else { return "Too many sign-in emails. Try again later." }
            return "Too many sign-in emails. Try again in \(Self.waitText(seconds))."
        case .expired: return "This sign-in expired. Send a new sign-in email."
        case .wrongCode(let attemptsLeft):
            guard let attemptsLeft else { return "That code is not right." }
            return "That code is not right. \(attemptsLeft) \(attemptsLeft == 1 ? "try" : "tries") left."
        case .signedOut: return "You were signed out. Sign in again."
        case .noCustomer: return "There is no billing to manage until you subscribe."
        case .unavailable(let status): return "\(host) is not available right now (\(status)). Try again later."
        case .server(let status, let code, let message):
            if let message, !message.trimmingCharacters(in: .whitespaces).isEmpty { return message }
            return "\(host) refused this (\(code ?? String(status)))."
        case .badResponse: return "\(host) sent an answer stew cannot read. Update stew, then try again."
        }
    }

    /// "45 seconds", "1 minute", "12 minutes".
    static func waitText(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) \(seconds == 1 ? "second" : "seconds")" }
        let minutes = (seconds + 59) / 60
        return "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
    }
}

/// Sends a request and returns the response. URLSession in the app; a stub in tests.
public protocol AccountTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// URLSession's own `data(for:)` has another signature (a task delegate with a default),
/// so the conformance forwards to it.
public struct URLSessionAccountTransport: AccountTransport {
    let session: URLSession

    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

/// The account API. Every call throws an `AccountError`.
public struct AccountClient: Sendable {
    public let server: URL
    let transport: AccountTransport
    let userAgent: String
    static let timeout: TimeInterval = 20

    public init(server: URL, transport: AccountTransport, userAgent: String) {
        self.server = server
        self.transport = transport
        self.userAgent = userAgent
    }

    /// The server's host, for messages: "account.stewcli.com".
    public var host: String { server.host ?? server.absoluteString }

    public func startSignIn(email: String, deviceName: String) async throws -> SignInStart {
        let (data, response) = try await send("POST", "/v1/sign-in", token: nil, body: ["email": email, "deviceName": deviceName])
        var start: SignInStart = try Self.decode(data)
        start.serverDate = response.value(forHTTPHeaderField: "date").flatMap(AccountTime.httpDate)
        return start
    }

    public func pollSignIn(_ start: SignInStart) async throws -> SignInPoll {
        struct Reply: Decodable {
            let status: String
            let sessionToken: String?
            let account: Account?
        }
        let reply: Reply = try await call("POST", "/v1/sign-in/poll", body: ["signInId": start.signInId, "pollToken": start.pollToken])
        switch reply.status {
        case "approved":
            guard let sessionToken = reply.sessionToken, !sessionToken.isEmpty, let account = reply.account else { throw AccountError.badResponse }
            return .approved(SignedIn(sessionToken: sessionToken, account: account))
        case "pending":
            return .pending
        default:
            throw AccountError.badResponse
        }
    }

    public func submitCode(_ start: SignInStart, code: String) async throws -> SignedIn {
        try await call("POST", "/v1/sign-in/code", body: ["signInId": start.signInId, "pollToken": start.pollToken, "code": code])
    }

    public func account(token: String) async throws -> Account {
        try await call("GET", "/v1/account", token: token)
    }

    public func billingPortal(token: String) async throws -> URL {
        struct Reply: Decodable { let url: URL }
        let reply: Reply = try await call("POST", "/v1/account/billing-portal", token: token)
        return reply.url
    }

    public func signOut(token: String) async throws {
        _ = try await send("POST", "/v1/sign-out", token: token, body: nil)
    }

    public func deleteAccount(token: String) async throws {
        _ = try await send("DELETE", "/v1/account", token: token, body: nil)
    }

    /// The request a call sends, for tests to inspect.
    func request(_ method: String, _ path: String, token: String?, body: [String: String]?) throws -> URLRequest {
        var request = URLRequest(url: server.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = method
        request.timeoutInterval = Self.timeout
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue(userAgent, forHTTPHeaderField: "user-agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        if let body {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        } else if method == "POST" {
            // An empty JSON object, so servers that require a body for POST accept it.
            request.httpBody = Data("{}".utf8)
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        return request
    }

    private func call<Reply: Decodable>(_ method: String, _ path: String, token: String? = nil, body: [String: String]? = nil) async throws -> Reply {
        try Self.decode(try await send(method, path, token: token, body: body).data)
    }

    private static func decode<Reply: Decodable>(_ data: Data) throws -> Reply {
        do {
            return try decoder.decode(Reply.self, from: data)
        } catch {
            throw AccountError.badResponse
        }
    }

    private func send(_ method: String, _ path: String, token: String?, body: [String: String]?) async throws -> (data: Data, response: HTTPURLResponse) {
        let request: URLRequest
        do {
            request = try self.request(method, path, token: token, body: body)
        } catch {
            throw AccountError.badResponse
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            throw AccountError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw AccountError.offline }
        guard (200..<300).contains(http.statusCode) else {
            throw AccountError.read(status: http.statusCode, body: data, retryAfterHeader: http.value(forHTTPHeaderField: "retry-after"))
        }
        return (data, http)
    }

    /// ISO 8601 times, with or without fractional seconds.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = AccountTime.parse(text) { return date }
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "not an ISO 8601 time: \(text)"))
        }
        return decoder
    }()

    /// Decodes an account the way the client does, for tests and samples.
    public static func decodeAccount(_ data: Data) throws -> Account {
        try decoder.decode(Account.self, from: data)
    }
}

enum AccountTime {
    /// An HTTP Date header: "Tue, 17 Nov 2026 13:30:55 GMT".
    static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }

    static func parse(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: .iso8601) { return date }
        return try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}

extension AccountError {
    /// Whether waiting and asking again may help: the Mac or the server was briefly away.
    public var isTransient: Bool {
        switch self {
        case .offline, .unavailable, .rateLimited: true
        default: false
        }
    }
}
