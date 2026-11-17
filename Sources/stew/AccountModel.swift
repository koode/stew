import AppKit
import Foundation
import StewCore

/// The stew account in the daemon: signing in, the plan, checkout and billing, and the
/// lease that goes on to the iPhone relay. Only the relay needs a plan, so nothing else in
/// stew waits on this. Main queue only.
final class AccountModel: ObservableObject {
    static let shared = AccountModel()

    /// What happened to the last wait for a checkout.
    enum PaymentOutcome: Equatable {
        case paid, gaveUp
    }

    /// The call a button started, so that button says it is busy.
    enum Busy: Equatable {
        case billing, signOut, delete
    }

    @Published var signIn = SignInFlow()
    /// The digits typed in the code field.
    @Published var code = ""
    /// A voucher code for the checkout, as typed.
    @Published var voucher = ""
    @Published private(set) var signedIn = false
    @Published private(set) var account: Account?
    /// Why the last refresh or action failed, while signed in.
    @Published private(set) var problem: String?
    @Published private(set) var paymentWait: PaymentWait?
    @Published private(set) var paymentOutcome: PaymentOutcome?
    @Published private(set) var busy: Busy?
    /// Set when the server said the session is gone, for a notice on the sign-in form.
    @Published private(set) var signedOutNotice: String?

    /// Called with the lease after every refresh, nil when there is none.
    var onLease: ((String?) -> Void)?
    var transport: AccountTransport = URLSessionAccountTransport()
    var deviceName = Host.current().localizedName ?? "Mac"
    /// Nil until `start`, so `stew snapshot` and Settings without a daemon never read the
    /// keychain.
    private var store: AccountTokenStore?
    private var lastRefresh: Date?
    /// The session generation a refresh in flight started in, if any.
    private var refreshingIn: Int?
    private var generation = AccountSessionGeneration()
    private var polling = false
    private var pollTimer: Timer?
    private var paymentTimer: Timer?
    private var dailyTimer: Timer?

    /// Reads the session, refreshes the account, and checks every hour whether a day has
    /// passed since the last refresh: a timer of 24 hours would drift while the Mac sleeps.
    func start(store: AccountTokenStore, onLease: @escaping (String?) -> Void) {
        self.store = store
        self.onLease = onLease
        signedIn = store.read() != nil
        refresh()
        dailyTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let self, AccountRefresh.isDue(lastRefresh: self.lastRefresh, now: Date()) else { return }
            self.refresh()
        }
    }

    /// Sample state for `stew snapshot`, which never starts the model.
    func showSample(
        signIn: SignInFlow = SignInFlow(), code: String = "", account: Account? = nil, problem: String? = nil,
        paymentWait: PaymentWait? = nil, paymentOutcome: PaymentOutcome? = nil, voucher: String = ""
    ) {
        self.signIn = signIn
        self.code = code
        self.voucher = voucher
        self.account = account
        signedIn = account != nil
        self.problem = problem
        self.paymentWait = paymentWait
        self.paymentOutcome = paymentOutcome
        busy = nil
        signedOutNotice = nil
    }

    private var config: StewConfig { loadConfig().0 }

    /// The client for account.server in config.json, or nil with a problem shown when it
    /// is not a URL.
    private func client() -> AccountClient? {
        guard let server = config.account.serverURL else {
            let message = "account.server in config.json is not an http or https URL."
            if signedIn { problem = message } else { signIn.reportProblem(.server(status: 0, code: nil, message: message)) }
            return nil
        }
        return AccountClient(server: server, transport: transport, userAgent: "stew/\(AppVersion.running.version)")
    }

    var host: String { config.account.serverURL?.host ?? AccountConfig.defaultServer }

    /// Runs one call off the main queue and hands its result back on it.
    private func run<Value>(_ work: @escaping () async throws -> Value, then: @escaping (Result<Value, AccountError>) -> Void) {
        Task {
            let result: Result<Value, AccountError>
            do {
                result = .success(try await work())
            } catch let error as AccountError {
                result = .failure(error)
            } catch {
                result = .failure(.offline)
            }
            DispatchQueue.main.async { then(result) }
        }
    }

    func sendEmail() {
        guard let client = client(), let email = signIn.send() else { return }
        signedOutNotice = nil
        let deviceName = deviceName
        run({ try await client.startSignIn(email: email, deviceName: deviceName) }) { [weak self] result in
            guard let self else { return }
            self.signIn.sent(result)
            if self.signIn.shouldPoll {
                self.code = ""
                self.startPolling()
            }
        }
    }

    func useAnotherEmail() {
        signIn.useAnotherEmail()
        code = ""
        stopPolling()
    }

    func submitCode() {
        guard let client = client(), let start = signIn.checkCode(code) else { return }
        let code = code
        run({ try await client.submitCode(start, code: code) }) { [weak self] result in
            guard let self else { return }
            if let signedIn = self.signIn.codeChecked(start, result) {
                self.finishSignIn(signedIn)
            } else if !self.signIn.shouldPoll {
                self.stopPolling()
            }
        }
    }

    /// A new digit clears the note that the last code was wrong.
    func codeEdited() {
        signIn.codeChanged(to: code)
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: SignInFlow.pollInterval, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func poll() {
        signIn.tick(now: Date())
        guard let start = signIn.pending else {
            stopPolling()
            return
        }
        // One poll at a time: a slow server must not pile them up.
        guard !polling, let client = client() else { return }
        polling = true
        run({ try await client.pollSignIn(start) }) { [weak self] result in
            guard let self else { return }
            self.polling = false
            if let signedIn = self.signIn.polled(start, result) {
                self.finishSignIn(signedIn)
            } else if !self.signIn.shouldPoll {
                self.stopPolling()
            }
        }
    }

    private func finishSignIn(_ session: SignedIn) {
        generation.advance()
        stopPolling()
        code = ""
        do {
            try store?.save(session.sessionToken)
        } catch {
            Log.write("account: cannot keep the session: \(error)")
            problem = "Signed in, but stew cannot keep the session in the keychain, so you will need to sign in again after a restart."
        }
        signedIn = true
        signedOutNotice = nil
        apply(session.account)
        Log.write("account: signed in")
    }

    /// Asks for the account again. The lease in it goes on to the relay.
    func refresh() {
        let started = generation.current
        guard refreshingIn != started, let token = store?.read(), let client = client() else { return }
        refreshingIn = started
        run({ try await client.account(token: token) }) { [weak self] result in
            guard let self else { return }
            if self.refreshingIn == started { self.refreshingIn = nil }
            // Signed out, deleted or signed in again meanwhile: this answer is for a
            // session that is gone.
            guard self.generation.isCurrent(started) else { return }
            switch result {
            case .success(let account):
                self.problem = nil
                self.apply(account)
            case .failure(.signedOut):
                self.endSession(notice: AccountError.signedOut.message(host: self.host))
            case .failure(let error):
                self.problem = error.message(host: self.host)
                Log.write("account: refresh failed: \(error)")
                self.paymentStep()
            }
        }
    }

    private func apply(_ account: Account) {
        self.account = account
        signedIn = true
        lastRefresh = Date()
        onLease?(account.entitled ? account.lease : nil)
        paymentStep()
    }

    /// The offers the pane shows: those the Mac may open.
    var offers: [AccountOffer] {
        account?.openableOffers(server: config.account.serverURL) ?? []
    }

    /// Opens the checkout in the browser, with the voucher code when there is one, and
    /// waits for the payment.
    func subscribe(_ offer: AccountOffer) {
        let checkout = offer.checkoutURL(voucher: voucher)
        guard AccountOffer.mayOpen(checkout, server: config.account.serverURL) else { return }
        NSWorkspace.shared.open(checkout)
        paymentWait = PaymentWait(startedAt: Date())
        paymentOutcome = nil
        paymentTimer?.invalidate()
        paymentTimer = Timer.scheduledTimer(withTimeInterval: PaymentWait.pollInterval, repeats: true) { [weak self] _ in self?.refresh() }
    }

    /// Ends the wait for a payment, however it ended. The voucher code goes too: it
    /// belonged to that checkout, and must not ride along with the next one.
    func stopWaitingForPayment() {
        paymentTimer?.invalidate()
        paymentTimer = nil
        paymentWait = nil
        voucher = ""
    }

    private func paymentStep() {
        guard let wait = paymentWait else { return }
        switch wait.step(account: account, now: Date()) {
        case .keepWaiting:
            return
        case .paid:
            paymentOutcome = .paid
        case .gaveUp:
            paymentOutcome = .gaveUp
        }
        stopWaitingForPayment()
    }

    func manageBilling() {
        guard let token = store?.read(), busy == nil, let client = client() else { return }
        busy = .billing
        let server = client.server
        let started = generation.current
        run({ try await client.billingPortal(token: token) }) { [weak self] result in
            guard let self else { return }
            self.busy = nil
            guard self.generation.isCurrent(started) else { return }
            switch result {
            case .success(let url) where AccountOffer.mayOpen(url, server: server):
                self.problem = nil
                NSWorkspace.shared.open(url)
            case .success(let url):
                self.problem = "\(self.host) sent a billing page stew does not open: \(url.host ?? url.absoluteString)."
            case .failure(.signedOut):
                self.endSession(notice: AccountError.signedOut.message(host: self.host))
            case .failure(let error):
                self.problem = error.message(host: self.host)
            }
        }
    }

    /// Signs out here even when the server cannot be reached: the token leaves the
    /// keychain either way, so this Mac cannot use it again.
    func signOut() {
        guard busy == nil else { return }
        guard let token = store?.read(), let client = client() else {
            endSession(notice: nil)
            return
        }
        busy = .signOut
        run({ try await client.signOut(token: token) }) { [weak self] result in
            guard let self else { return }
            self.busy = nil
            if case .failure(let error) = result, error != .signedOut {
                Log.write("account: the server did not take the sign-out: \(error)")
            }
            self.endSession(notice: nil)
        }
    }

    /// Deletes the account on the server; the session ends only once that worked.
    func deleteAccount() {
        guard let token = store?.read(), busy == nil, let client = client() else { return }
        busy = .delete
        run({ try await client.deleteAccount(token: token) }) { [weak self] result in
            guard let self else { return }
            self.busy = nil
            switch result {
            case .success, .failure(.signedOut):
                Log.write("account: deleted")
                self.endSession(notice: nil)
            case .failure(let error):
                self.problem = error.message(host: self.host)
            }
        }
    }

    private func endSession(notice: String?) {
        generation.advance()
        store?.delete()
        stopWaitingForPayment()
        paymentOutcome = nil
        signedIn = false
        account = nil
        problem = nil
        lastRefresh = nil
        signIn = SignInFlow()
        code = ""
        signedOutNotice = notice
        voucher = ""
        // Pairings keep the lease their relay already has until it runs out; new
        // pairings go without one.
        onLease?(nil)
    }
}
