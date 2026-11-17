import Foundation
import Testing
@testable import StewCore

/// Answers each request with the next queued response, and keeps the requests.
private final class StubTransport: AccountTransport, @unchecked Sendable {
    enum Reply {
        case http(Int, String, headers: [String: String] = [:])
        case failure
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var recorded: [URLRequest] = []

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let reply: Reply = lock.withLock {
            recorded.append(request)
            return replies.isEmpty ? .failure : replies.removeFirst()
        }
        switch reply {
        case .failure:
            throw URLError(.notConnectedToInternet)
        case .http(let status, let body, let headers):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (Data(body.utf8), response)
        }
    }
}

private let server = URL(string: "https://account.stewcli.com")!

private func client(_ replies: [StubTransport.Reply]) -> (AccountClient, StubTransport) {
    let transport = StubTransport(replies)
    return (AccountClient(server: server, transport: transport, userAgent: "stew/9.9.9"), transport)
}

private func bodyObject(_ request: URLRequest) -> [String: String]? {
    request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
}

private let accountJSON = """
{"id":"acc_01HZY","email":"abby@example.com",
 "plan":{"status":"trial","trialEndsAt":"2026-12-01T10:00:00Z","currentPeriodEnd":null,"cancelAtPeriodEnd":false,"interval":null},
 "entitled":true,
 "offers":[
  {"interval":"month","amount":500,"currency":"usd","label":"Monthly","url":"https://buy.stripe.com/test_month?client_reference_id=acc_01HZY"},
  {"interval":"year","amount":5000,"currency":"usd","label":"Yearly","url":"https://buy.stripe.com/test_year"}
 ],
 "lease":"eyJ2IjoxfQ.c2ln"}
"""

private func sampleAccount(status: AccountPlanStatus = .trial, cancelAtPeriodEnd: Bool = false) -> Account {
    Account(id: "acc_1", email: "abby@example.com", plan: AccountPlan(status: status, cancelAtPeriodEnd: cancelAtPeriodEnd), entitled: true)
}

private let start = SignInStart(signInId: "sgn_1", pollToken: "poll", expiresAt: Date(timeIntervalSince1970: 2_000_000_000))

@Suite struct AccountConfigTests {
    @Test func defaultsToTheHostedService() throws {
        let config = try JSONDecoder().decode(StewConfig.self, from: Data("{}".utf8))
        #expect(config.account.server == "https://account.stewcli.com")
        #expect(config.account.serverURL == URL(string: "https://account.stewcli.com"))
    }

    @Test func takesALocalServerAndTrimsTheSlash() throws {
        let config = try JSONDecoder().decode(StewConfig.self, from: Data(#"{"account":{"server":"http://localhost:4000/"}}"#.utf8))
        #expect(config.account.serverURL == URL(string: "http://localhost:4000"))
    }

    @Test func refusesWhatIsNotAnHTTPURL() {
        #expect(AccountConfig(server: "account.stewcli.com").serverURL == nil)
        #expect(AccountConfig(server: "ftp://account.stewcli.com").serverURL == nil)
    }

    @Test func roundTripsThroughTheConfigFile() throws {
        var config = StewConfig()
        config.account.server = "http://127.0.0.1:4100"
        let decoded = try JSONDecoder().decode(StewConfig.self, from: try JSONEncoder().encode(config))
        #expect(decoded.account.server == "http://127.0.0.1:4100")
    }
}

@Suite struct AccountModelDecodingTests {
    @Test func decodesTheContractExample() throws {
        let account = try AccountClient.decodeAccount(Data(accountJSON.utf8))
        #expect(account.id == "acc_01HZY")
        #expect(account.plan.status == .trial)
        #expect(account.plan.trialEndsAt == Date(timeIntervalSince1970: 1_796_119_200))
        #expect(account.plan.currentPeriodEnd == nil)
        #expect(account.plan.interval == nil)
        #expect(account.entitled)
        #expect(account.offers.map(\.label) == ["Monthly", "Yearly"])
        #expect(account.offers.first?.interval == .month)
        #expect(account.lease == "eyJ2IjoxfQ.c2ln")
    }

    @Test func keepsAnUnknownStatusAndInterval() throws {
        let json = #"{"id":"a","email":"e@x.io","plan":{"status":"paused","interval":"week","cancelAtPeriodEnd":false},"entitled":false,"offers":[],"lease":null}"#
        let account = try AccountClient.decodeAccount(Data(json.utf8))
        #expect(account.plan.status == .other("paused"))
        #expect(account.plan.interval == .other("week"))
        #expect(account.lease == nil)
    }

    @Test func readsEveryKnownStatus() {
        let names = ["trial": AccountPlanStatus.trial, "active": .active, "past_due": .pastDue, "canceled": .canceled, "expired": .expired]
        for (name, status) in names {
            #expect(AccountPlanStatus(rawValue: name) == status)
            #expect(status.rawValue == name)
        }
    }

    @Test func leavesOutAnOfferThatDoesNotDecode() throws {
        let json = #"{"id":"a","email":"e@x.io","plan":{"status":"expired"},"entitled":false,"offers":[{"interval":"month","label":"Monthly"},{"interval":"year","label":"Yearly","url":"https://buy.stripe.com/y"}]}"#
        let account = try AccountClient.decodeAccount(Data(json.utf8))
        #expect(account.offers.map(\.label) == ["Yearly"])
        #expect(account.plan.cancelAtPeriodEnd == false)
    }

    @Test func readsTimesWithFractionalSeconds() throws {
        let json = #"{"id":"a","email":"e@x.io","plan":{"status":"active","currentPeriodEnd":"2026-12-01T10:00:00.250Z","interval":"year"},"entitled":true}"#
        let account = try AccountClient.decodeAccount(Data(json.utf8))
        #expect(account.plan.currentPeriodEnd == Date(timeIntervalSince1970: 1_796_119_200.25))
        #expect(account.offers.isEmpty)
    }
}

@Suite struct AccountOfferTests {
    @Test func opensStripeAndStewPagesOverHTTPS() {
        #expect(AccountOffer.mayOpen(URL(string: "https://buy.stripe.com/abc")!, server: server))
        #expect(AccountOffer.mayOpen(URL(string: "https://billing.stripe.com/p/session/x")!, server: server))
        #expect(AccountOffer.mayOpen(URL(string: "https://stewcli.com/pricing")!, server: server))
    }

    @Test func refusesOtherPages() {
        #expect(!AccountOffer.mayOpen(URL(string: "http://buy.stripe.com/abc")!, server: server))
        #expect(!AccountOffer.mayOpen(URL(string: "https://stripe.com.example.org/abc")!, server: server))
        #expect(!AccountOffer.mayOpen(URL(string: "https://user:pw@buy.stripe.com/abc")!, server: server))
        #expect(!AccountOffer.mayOpen(URL(string: "https://buy.stripe.com:8443/abc")!, server: server))
        #expect(!AccountOffer.mayOpen(URL(string: "file:///etc/passwd")!, server: server))
    }

    @Test func opensPagesOfALocalServer() {
        let local = URL(string: "http://localhost:4000")!
        #expect(AccountOffer.mayOpen(URL(string: "http://localhost:4000/checkout/done")!, server: local))
        #expect(!AccountOffer.mayOpen(URL(string: "http://localhost:4001/checkout/done")!, server: local))
        #expect(!AccountOffer.mayOpen(URL(string: "http://localhost:4000/x")!, server: server))
    }

    @Test func showsNoOffersWhileAPaymentFailed() throws {
        var account = try AccountClient.decodeAccount(Data(accountJSON.utf8))
        #expect(account.openableOffers(server: server).count == 2)
        account.plan.status = .pastDue
        #expect(account.openableOffers(server: server).isEmpty)
    }

    @Test func dropsOffersItMayNotOpenOrThatHaveNoLabel() {
        var account = sampleAccount(status: .expired)
        account.offers = [
            AccountOffer(interval: .month, label: "Monthly", url: URL(string: "https://evil.example.com/pay")!),
            AccountOffer(interval: .year, label: "  ", url: URL(string: "https://buy.stripe.com/y")!),
            AccountOffer(interval: .year, label: "Yearly", url: URL(string: "https://buy.stripe.com/y")!),
        ]
        #expect(account.openableOffers(server: server).map(\.label) == ["Yearly"])
    }
}

@Suite struct AccountClientTests {
    @Test func startsASignIn() async throws {
        let (client, transport) = client([.http(200, #"{"signInId":"sgn_1","pollToken":"p","expiresAt":"2026-12-01T10:10:00Z"}"#)])
        let started = try await client.startSignIn(email: "abby@example.com", deviceName: "Abby's MacBook Pro")
        #expect(started.signInId == "sgn_1")
        #expect(started.pollToken == "p")
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://account.stewcli.com/v1/sign-in")
        #expect(request.value(forHTTPHeaderField: "user-agent") == "stew/9.9.9")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "authorization") == nil)
        #expect(bodyObject(request) == ["email": "abby@example.com", "deviceName": "Abby's MacBook Pro"])
    }

    @Test func pollsPendingThenApproved() async throws {
        let (client, transport) = client([
            .http(200, #"{"status":"pending"}"#),
            .http(200, #"{"status":"approved","sessionToken":"tok","account":\#(accountJSON)}"#),
        ])
        #expect(try await client.pollSignIn(start) == .pending)
        guard case .approved(let signedIn) = try await client.pollSignIn(start) else {
            Issue.record("expected approved")
            return
        }
        #expect(signedIn.sessionToken == "tok")
        #expect(signedIn.account.email == "abby@example.com")
        #expect(transport.requests.first?.url?.path == "/v1/sign-in/poll")
        #expect(bodyObject(transport.requests[0]) == ["signInId": "sgn_1", "pollToken": "poll"])
    }

    @Test func refusesAnApprovalWithoutToken() async {
        let (client, _) = client([.http(200, #"{"status":"approved"}"#), .http(200, #"{"status":"maybe"}"#)])
        await #expect(throws: AccountError.badResponse) { try await client.pollSignIn(start) }
        await #expect(throws: AccountError.badResponse) { try await client.pollSignIn(start) }
    }

    @Test func sendsTheCode() async throws {
        let (client, transport) = client([.http(200, #"{"sessionToken":"tok","account":\#(accountJSON)}"#)])
        let signedIn = try await client.submitCode(start, code: "123456")
        #expect(signedIn.sessionToken == "tok")
        #expect(transport.requests.first?.url?.path == "/v1/sign-in/code")
        #expect(bodyObject(transport.requests[0]) == ["signInId": "sgn_1", "pollToken": "poll", "code": "123456"])
    }

    @Test func authenticatedCallsCarryTheToken() async throws {
        let (client, transport) = client([
            .http(200, accountJSON),
            .http(200, #"{"url":"https://billing.stripe.com/p/session/abc"}"#),
            .http(204, ""),
            .http(204, ""),
        ])
        _ = try await client.account(token: "tok")
        #expect(try await client.billingPortal(token: "tok") == URL(string: "https://billing.stripe.com/p/session/abc"))
        try await client.signOut(token: "tok")
        try await client.deleteAccount(token: "tok")
        let calls = transport.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
        #expect(calls == ["GET /v1/account", "POST /v1/account/billing-portal", "POST /v1/sign-out", "DELETE /v1/account"])
        #expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "authorization") == "Bearer tok" })
        #expect(transport.requests[0].httpBody == nil)
    }

    @Test func keepsAPathInTheServerAddress() throws {
        let client = AccountClient(server: URL(string: "http://localhost:4000/stew")!, transport: StubTransport([]), userAgent: "stew/1")
        let request = try client.request("GET", "/v1/account", token: nil, body: nil)
        #expect(request.url?.absoluteString == "http://localhost:4000/stew/v1/account")
    }

    @Test func mapsRefusalsByCode() async {
        let cases: [(StubTransport.Reply, AccountError)] = [
            (.http(400, #"{"error":"invalid_email","message":"x"}"#), .invalidEmail),
            (.http(429, #"{"error":"rate_limited","retryAfter":120}"#), .rateLimited(retryAfter: 120)),
            (.http(429, #"{"error":"rate_limited"}"#, headers: ["Retry-After": "30"]), .rateLimited(retryAfter: 30)),
            (.http(410, #"{"error":"expired"}"#), .expired),
            (.http(400, #"{"error":"wrong_code","attemptsLeft":2}"#), .wrongCode(attemptsLeft: 2)),
            (.http(401, #"{"error":"signed_out"}"#), .signedOut),
            (.http(409, #"{"error":"no_customer"}"#), .noCustomer),
            (.http(502, "<html>Bad gateway</html>"), .unavailable(status: 502)),
            (.http(401, ""), .signedOut),
            (.http(418, #"{"error":"teapot","message":"Short and stout."}"#), .server(status: 418, code: "teapot", message: "Short and stout.")),
            (.http(200, "not json"), .badResponse),
            (.failure, .offline),
        ]
        for (reply, expected) in cases {
            let (client, _) = client([reply])
            await #expect(throws: expected) { _ = try await client.account(token: "tok") }
        }
    }
}

@Suite struct AccountErrorMessageTests {
    @Test func saysHowLongToWait() {
        #expect(AccountError.waitText(1) == "1 second")
        #expect(AccountError.waitText(45) == "45 seconds")
        #expect(AccountError.waitText(60) == "1 minute")
        #expect(AccountError.waitText(61) == "2 minutes")
        #expect(AccountError.rateLimited(retryAfter: 720).message(host: "h") == "Too many sign-in emails. Try again in 12 minutes.")
        #expect(AccountError.rateLimited(retryAfter: nil).message(host: "h") == "Too many sign-in emails. Try again later.")
    }

    @Test func countsTriesLeft() {
        #expect(AccountError.wrongCode(attemptsLeft: 3).message(host: "h") == "That code is not right. 3 tries left.")
        #expect(AccountError.wrongCode(attemptsLeft: 1).message(host: "h") == "That code is not right. 1 try left.")
        #expect(AccountError.wrongCode(attemptsLeft: nil).message(host: "h") == "That code is not right.")
    }

    @Test func namesTheServerWhenOffline() {
        #expect(AccountError.offline.message(host: "account.stewcli.com").hasPrefix("Cannot reach account.stewcli.com."))
        #expect(AccountError.server(status: 500, code: "boom", message: nil).message(host: "h") == "h refused this (boom).")
    }
}

@Suite struct SignInFlowTests {
    private func waitingFlow() -> SignInFlow {
        var flow = SignInFlow(email: " abby@example.com ")
        #expect(flow.send() == "abby@example.com")
        flow.sent(.success(start))
        return flow
    }

    @Test func checksTheAddressBeforeSending() {
        for bad in ["", "abby", "abby@", "@example.com", "abby@example", "ab by@example.com", "a@b@c.com", "abby@.com"] {
            var flow = SignInFlow(email: bad)
            #expect(!flow.canSend, "\(bad)")
            #expect(flow.send() == nil)
        }
        #expect(SignInFlow.looksLikeEmail("abby+stew@mail.example.co.uk"))
    }

    @Test func waitsAndPollsOnceTheEmailWent() {
        let flow = waitingFlow()
        #expect(flow.phase == .waiting(start))
        #expect(flow.shouldPoll)
        #expect(flow.sentTo == "abby@example.com")
        #expect(SignInFlow.pollInterval == 2)
    }

    @Test func showsWhySendingFailed() {
        var flow = SignInFlow(email: "abby@example.com")
        _ = flow.send()
        #expect(flow.phase == .sending)
        #expect(!flow.canSend)
        flow.sent(.failure(.rateLimited(retryAfter: 60)))
        #expect(flow.phase == .enterEmail)
        #expect(flow.problem == .rateLimited(retryAfter: 60))
        #expect(!flow.shouldPoll)
    }

    @Test func signsInWhenTheLinkIsApproved() {
        var flow = waitingFlow()
        #expect(flow.polled(start, .success(.pending)) == nil)
        let session = SignedIn(sessionToken: "tok", account: sampleAccount())
        #expect(flow.polled(start, .success(.approved(session))) == session)
        #expect(!flow.shouldPoll)
    }

    @Test func ignoresAPollForASignInItLeft() {
        var flow = waitingFlow()
        flow.useAnotherEmail()
        let session = SignedIn(sessionToken: "tok", account: sampleAccount())
        #expect(flow.polled(start, .success(.approved(session))) == nil)
        #expect(flow.phase == .enterEmail)
    }

    @Test func keepsPollingWhileOffline() {
        var flow = waitingFlow()
        #expect(flow.polled(start, .failure(.offline)) == nil)
        #expect(flow.shouldPoll)
        #expect(flow.problem == .offline)
        _ = flow.polled(start, .success(.pending))
        #expect(flow.problem == nil)
    }

    @Test func endsWhenTheSignInExpires() {
        var flow = waitingFlow()
        _ = flow.polled(start, .failure(.expired))
        #expect(flow.phase == .enterEmail)
        #expect(flow.problem == .expired)
        #expect(flow.email == " abby@example.com ")
    }

    @Test func endsAtTheExpiryTimeWithoutAnAnswer() {
        var flow = waitingFlow()
        flow.tick(now: start.expiresAt.addingTimeInterval(-1))
        #expect(flow.shouldPoll)
        flow.tick(now: start.expiresAt)
        #expect(!flow.shouldPoll)
        #expect(flow.problem == .expired)
    }

    @Test func takesOnlySixDigits() {
        var flow = waitingFlow()
        #expect(flow.checkCode("12345") == nil)
        #expect(flow.checkCode("12345a") == nil)
        #expect(flow.checkCode("１２３４５６") == nil)
        #expect(flow.checkCode("123456") == start)
        #expect(flow.isCheckingCode)
        #expect(flow.shouldPoll)
        #expect(flow.checkCode("123456") == nil)
    }

    @Test func aWrongCodeStaysUntilTheCodeChanges() {
        var flow = waitingFlow()
        _ = flow.checkCode("123456")
        #expect(flow.codeChecked(start, .failure(.wrongCode(attemptsLeft: 4))) == nil)
        #expect(flow.phase == .waiting(start))
        #expect(flow.problem == .wrongCode(attemptsLeft: 4))
        flow.codeChanged(to: "123456")
        #expect(flow.problem == .wrongCode(attemptsLeft: 4))
        _ = flow.polled(start, .failure(.offline))
        #expect(flow.problem == .wrongCode(attemptsLeft: 4))
        flow.codeChanged(to: "12345")
        #expect(flow.problem == nil)
    }

    @Test func tooManyWrongCodesEndTheSignIn() {
        var flow = waitingFlow()
        _ = flow.checkCode("123456")
        _ = flow.codeChecked(start, .failure(.expired))
        #expect(flow.phase == .enterEmail)
        #expect(flow.problem == .expired)
    }

    @Test func aRightCodeSignsIn() {
        var flow = waitingFlow()
        _ = flow.checkCode("123456")
        let session = SignedIn(sessionToken: "tok", account: sampleAccount())
        #expect(flow.codeChecked(start, .success(session)) == session)
        #expect(!flow.shouldPoll)
    }
}

@Suite struct PaymentWaitTests {
    private let started = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func endsWhenThePlanRenews() {
        let wait = PaymentWait(startedAt: started)
        #expect(wait.step(account: sampleAccount(status: .trial), now: started.addingTimeInterval(5)) == .keepWaiting)
        #expect(wait.step(account: sampleAccount(status: .active, cancelAtPeriodEnd: true), now: started.addingTimeInterval(10)) == .keepWaiting)
        #expect(wait.step(account: sampleAccount(status: .active), now: started.addingTimeInterval(15)) == .paid)
    }

    @Test func givesUpAfterTenMinutes() {
        let wait = PaymentWait(startedAt: started)
        #expect(PaymentWait.pollInterval == 5)
        #expect(wait.step(account: nil, now: started.addingTimeInterval(599)) == .keepWaiting)
        #expect(wait.step(account: sampleAccount(status: .pastDue), now: started.addingTimeInterval(600)) == .gaveUp)
        #expect(wait.step(account: sampleAccount(status: .active), now: started.addingTimeInterval(900)) == .paid)
    }

    @Test func refreshesOnceADay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(AccountRefresh.isDue(lastRefresh: nil, now: now))
        #expect(!AccountRefresh.isDue(lastRefresh: now.addingTimeInterval(-23 * 3600), now: now))
        #expect(AccountRefresh.isDue(lastRefresh: now.addingTimeInterval(-24 * 3600), now: now))
    }
}

@Suite struct LeaseForwardingTests {
    @Test func sendsANewLeaseToARelayThatTakesLeases() {
        #expect(LeaseForwarding.decide(lease: "a.b", relayAcceptsLeases: true, lastSent: nil) == .send)
        #expect(LeaseForwarding.decide(lease: "c.d", relayAcceptsLeases: true, lastSent: "a.b") == .send)
    }

    @Test func sendsNothingElse() {
        #expect(LeaseForwarding.decide(lease: nil, relayAcceptsLeases: true, lastSent: nil) == .noLease)
        #expect(LeaseForwarding.decide(lease: "", relayAcceptsLeases: true, lastSent: nil) == .noLease)
        #expect(LeaseForwarding.decide(lease: "a.b", relayAcceptsLeases: false, lastSent: nil) == .relayWithoutLeases)
        #expect(LeaseForwarding.decide(lease: "a.b", relayAcceptsLeases: true, lastSent: "a.b") == .alreadySent)
    }

    @Test func retriesOncePerLeaseAfterAPlanStop() {
        #expect(LeaseForwarding.retryAfterPlanStop(lease: "a.b", lastRetried: nil))
        #expect(!LeaseForwarding.retryAfterPlanStop(lease: "a.b", lastRetried: "a.b"))
        #expect(LeaseForwarding.retryAfterPlanStop(lease: "c.d", lastRetried: "a.b"))
        #expect(!LeaseForwarding.retryAfterPlanStop(lease: nil, lastRetried: nil))
        #expect(!LeaseForwarding.retryAfterPlanStop(lease: "", lastRetried: nil))
    }

    @Test func putsTheLeaseInAClaimOnlyForARelayThatTakesLeases() {
        #expect(LeaseForwarding.claimLease("a.b", relayAcceptsLeases: true) == "a.b")
        #expect(LeaseForwarding.claimLease("a.b", relayAcceptsLeases: false) == nil)
        #expect(LeaseForwarding.claimLease(nil, relayAcceptsLeases: true) == nil)
    }
}

@Suite struct AccountPlanSummaryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func summary(_ plan: AccountPlan) -> AccountPlanSummary {
        AccountPlanSummary(plan: plan, now: now, dateText: { "D\(Int($0.timeIntervalSince(self.now) / 86_400))" })
    }

    @Test func countsTrialDaysUp() {
        #expect(AccountPlanSummary.daysLeft(until: now.addingTimeInterval(30 * 3600), now: now) == 2)
        #expect(AccountPlanSummary.daysLeft(until: now.addingTimeInterval(86_400), now: now) == 1)
        #expect(AccountPlanSummary.daysLeft(until: now.addingTimeInterval(-10), now: now) == 0)
    }

    @Test func trial() {
        let plan = summary(AccountPlan(status: .trial, trialEndsAt: now.addingTimeInterval(9 * 86_400)))
        #expect(plan.name == "Trial")
        #expect(plan.status == "9 days left")
        #expect(plan.tone == .good)
        #expect(plan.hint == "The trial ends D9. Subscribe to keep the iPhone relay after that.")
        #expect(!plan.hasBilling)
        let lastDay = summary(AccountPlan(status: .trial, trialEndsAt: now.addingTimeInterval(3600)))
        #expect(lastDay.status == "1 day left")
        #expect(lastDay.tone == .attention)
        #expect(summary(AccountPlan(status: .trial, trialEndsAt: now.addingTimeInterval(-60))).status == "Expired")
    }

    @Test func activeMonthlyAndYearly() {
        let monthly = summary(AccountPlan(status: .active, currentPeriodEnd: now.addingTimeInterval(20 * 86_400), interval: .month))
        #expect(monthly.name == "stew Pro, monthly")
        #expect(monthly.status == "Active")
        #expect(monthly.tone == .good)
        #expect(monthly.hint == "Renews D20.")
        #expect(monthly.hasBilling)
        #expect(summary(AccountPlan(status: .active, interval: .year)).name == "stew Pro, yearly")
    }

    @Test func cancelAtPeriodEnd() {
        let plan = summary(AccountPlan(status: .active, currentPeriodEnd: now.addingTimeInterval(20 * 86_400), cancelAtPeriodEnd: true, interval: .year))
        #expect(plan.status == "Not renewing")
        #expect(plan.tone == .attention)
        #expect(plan.hint.hasPrefix("Ends D20."))
    }

    @Test func paymentProblem() {
        let plan = summary(AccountPlan(status: .pastDue, interval: .month))
        #expect(plan.status == "Payment problem")
        #expect(plan.tone == .attention)
        #expect(plan.hasBilling)
    }

    @Test func canceledAndExpired() {
        #expect(summary(AccountPlan(status: .canceled, currentPeriodEnd: now.addingTimeInterval(86_400), interval: .month)).status == "Canceled")
        #expect(summary(AccountPlan(status: .canceled, currentPeriodEnd: now.addingTimeInterval(-86_400), interval: .month)).status == "Expired")
        let expiredTrial = summary(AccountPlan(status: .expired))
        #expect(expiredTrial.name == "Trial")
        #expect(expiredTrial.status == "Expired")
        #expect(!expiredTrial.hasBilling)
        #expect(summary(AccountPlan(status: .expired, interval: .year)).hasBilling)
    }

    @Test func anUnknownStatusShowsItsName() {
        let plan = summary(AccountPlan(status: .other("on_hold")))
        #expect(plan.status == "On Hold")
        #expect(plan.tone == .neutral)
    }
}

@Suite struct AccountTokenStoreTests {
    @Test func memoryStore() throws {
        let store = MemoryAccountTokenStore()
        #expect(store.read() == nil)
        try store.save("tok")
        #expect(store.read() == "tok")
        store.delete()
        #expect(store.read() == nil)
    }

    @Test func fileStoreKeepsTheTokenPrivate() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stew-account-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("account-session").path
        let store = FileAccountTokenStore(path: path)
        #expect(store.read() == nil)
        try store.save("tok")
        #expect(FileAccountTokenStore(path: path).read() == "tok")
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        store.delete()
        #expect(store.read() == nil)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func keychainStoreUsesTheAccountService() {
        // Only the name: tests never touch the real keychain.
        #expect(KeychainAccountTokenStore.service == "nl.koode.stew.account")
    }
}
