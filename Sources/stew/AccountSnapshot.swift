import AppKit
import SwiftUI
import StewCore

/// Renders Settings ▸ Account in each state, for `stew snapshot`. It never touches the
/// keychain or the network.
enum AccountSnapshot {
    private struct Scenario {
        let name: String
        var signIn = SignInFlow()
        var code = ""
        var account: Account?
        var paymentWait: PaymentWait?
        var voucher = ""
    }

    static func render(to directory: String, write: (AnyView, Bool, String) -> Void) {
        let now = Date()
        let day: TimeInterval = 86_400
        let email = "abby@example.com"
        let offers = [
            AccountOffer(interval: .month, amount: 500, currency: "usd", label: "$5 / month", url: URL(string: "https://buy.stripe.com/sample-monthly")!),
            AccountOffer(interval: .year, amount: 5000, currency: "usd", label: "$50 / year", url: URL(string: "https://buy.stripe.com/sample-yearly")!),
        ]
        func account(_ plan: AccountPlan, entitled: Bool, offers: [AccountOffer] = offers) -> Account {
            Account(id: "acc_sample", email: email, plan: plan, entitled: entitled, offers: offers, lease: entitled ? "sample.lease" : nil)
        }
        let start = SignInStart(signInId: "sample", pollToken: "sample", expiresAt: now.addingTimeInterval(540))
        var waiting = SignInFlow(email: email)
        _ = waiting.send()
        waiting.sent(.success(start))
        var wrongCode = waiting
        _ = wrongCode.checkCode("418207")
        _ = wrongCode.codeChecked(start, .failure(.wrongCode(attemptsLeft: 3)))
        var codesLocked = waiting
        _ = codesLocked.checkCode("418207")
        _ = codesLocked.codeChecked(start, .failure(.codesLocked))
        let trial = account(AccountPlan(status: .trial, trialEndsAt: now.addingTimeInterval(9 * day - 3600)), entitled: true)
        let scenarios = [
            Scenario(name: "signed-out"),
            Scenario(name: "waiting-for-code", signIn: waiting),
            Scenario(name: "wrong-code", signIn: wrongCode, code: "418207"),
            Scenario(name: "codes-locked", signIn: codesLocked, code: "418207"),
            Scenario(name: "trial", account: trial),
            Scenario(name: "voucher", account: trial, voucher: "LAUNCH20"),
            Scenario(name: "waiting-for-payment", account: trial, paymentWait: PaymentWait(startedAt: now)),
            Scenario(name: "active-monthly", account: account(
                AccountPlan(status: .active, currentPeriodEnd: now.addingTimeInterval(23 * day), interval: .month), entitled: true, offers: []
            )),
            Scenario(name: "cancel-at-period-end", account: account(
                AccountPlan(status: .active, currentPeriodEnd: now.addingTimeInterval(23 * day), cancelAtPeriodEnd: true, interval: .year), entitled: true
            )),
            Scenario(name: "payment-problem", account: account(
                AccountPlan(status: .pastDue, currentPeriodEnd: now.addingTimeInterval(4 * day), interval: .month), entitled: true
            )),
            Scenario(name: "gift", account: account(
                AccountPlan(status: .gift, trialEndsAt: now.addingTimeInterval(-40 * day), giftEndsAt: now.addingTimeInterval(60 * day)), entitled: true
            )),
            Scenario(name: "expired", account: account(
                AccountPlan(status: .expired, trialEndsAt: now.addingTimeInterval(-3 * day)), entitled: false
            )),
        ]
        let model = AccountModel.shared
        for scenario in scenarios {
            model.showSample(signIn: scenario.signIn, code: scenario.code, account: scenario.account, paymentWait: scenario.paymentWait, voucher: scenario.voucher)
            for dark in [false, true] {
                let settings = SettingsModel()
                settings.load()
                settings.tab = .account
                let path = "\(directory)/settings-account-\(scenario.name)-\(dark ? "dark" : "light").png"
                let view = SettingsView(model: settings, approvals: ApprovalsModel(), history: HistoryModel(), updater: Updater(log: { _ in }), account: model)
                write(AnyView(view.frame(width: Snapshot.settingsSize.width, height: Snapshot.settingsSize.height)), dark, path)
                print(path)
            }
        }
    }
}
