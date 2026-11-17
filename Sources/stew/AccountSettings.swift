import SwiftUI
import StewCore

/// Settings ▸ Account: sign in with an email address, see the plan, subscribe, manage
/// billing, sign out or delete the account.
struct AccountSettingsTab: View {
    @ObservedObject var account: AccountModel
    @State private var deleting = false

    var body: some View {
        SettingsPane(tab: .account) {
            SettingsForm {
                if account.signedIn {
                    signedIn
                } else if let start = account.signIn.pending {
                    waiting(start)
                } else {
                    signInForm
                }
            }
        }
        .confirmationDialog("Delete your stew account?", isPresented: $deleting) {
            Button("Delete account", role: .destructive) { account.deleteAccount() }
        } message: {
            Text("Any subscription is canceled now, and your account and its data are deleted. This cannot be undone.")
        }
    }

    private var problem: String? {
        account.signIn.problem?.message(host: account.host)
    }

    @ViewBuilder
    private var signInForm: some View {
        let sending = account.signIn.phase == .sending
        Section("Sign in") {
            if let notice = account.signedOutNotice {
                Notice(.error, notice)
            }
            SettingRow(hint: "stew emails you a sign-in code and link. A new account starts with a free trial, no card needed.") {
                TextField("Email", text: $account.signIn.email, prompt: Text("you@example.com"))
                    .textContentType(.emailAddress)
                    .onSubmit { account.sendEmail() }
                    .disabled(sending)
            }
            if let problem {
                Notice(.error, problem)
            }
            HStack {
                Spacer()
                Button(sending ? "Sending…" : "Send sign-in email") { account.sendEmail() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!account.signIn.canSend)
            }
        }
    }

    private func waiting(_ start: SignInStart) -> some View {
        let checking = account.signIn.isCheckingCode
        let wrongCode: Bool = {
            if case .wrongCode = account.signIn.problem { return true }
            return false
        }()
        return Section("Check your email") {
            SettingRow(hint: "Click the link in the email, or type the 6-digit code from it here.") {
                LabeledContent("Sent to") {
                    Text(account.signIn.sentTo ?? account.signIn.trimmedEmail)
                        .foregroundStyle(Ink.secondary)
                        .textSelection(.enabled)
                }
            }
            // A plain row rather than LabeledContent, which puts the label at the top of the
            // boxes; here it sits in their middle.
            HStack {
                Text("Code")
                Spacer()
                DigitsField(digits: $account.code, mismatch: wrongCode, onSubmit: account.submitCode)
                    .onChange(of: account.code) { account.codeEdited() }
                    .disabled(checking || account.signIn.codesLocked)
            }
            if let problem {
                Notice(.error, problem)
            }
            HStack(spacing: 8) {
                AccountProgress(text: checking ? "Checking the code…" : "Waiting for you to click the link…")
                Spacer()
                Button("Use another email") { account.useAnotherEmail() }
                Button("Sign in") { account.submitCode() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(account.code.count != 6 || checking || account.signIn.codesLocked)
            }
        }
    }

    @ViewBuilder
    private var signedIn: some View {
        if let details = account.account {
            let summary = AccountPlanSummary(plan: details.plan, now: Date(), dateText: SettingsDate.text)
            Section("Signed in") {
                LabeledContent("Email") {
                    Text(details.email)
                        .foregroundStyle(Ink.secondary)
                        .textSelection(.enabled)
                }
                if let problem = account.problem {
                    Notice(.error, problem, action: ("Try again", { account.refresh() }))
                }
                HStack {
                    Spacer()
                    Button(account.busy == .signOut ? "Signing out…" : "Sign out") { account.signOut() }
                        .disabled(account.busy != nil)
                    Button(account.busy == .delete ? "Deleting…" : "Delete account…", role: .destructive) { deleting = true }
                        .disabled(account.busy != nil)
                }
            }
            Section("Plan") {
                if account.paymentOutcome == .paid {
                    Notice(.success, "Payment received. Your plan is active.")
                }
                SettingRow(hint: summary.hint) {
                    LabeledContent("Current plan") {
                        HStack(spacing: 8) {
                            Text(summary.name).foregroundStyle(Ink.secondary)
                            StatusPill(text: summary.status, tone: summary.tone.color)
                        }
                    }
                }
                subscribe(summary)
                if summary.hasBilling {
                    SettingRow(hint: "Change the payment method, see invoices or cancel, on a Stripe page in your browser.") {
                        LabeledContent("Billing") {
                            Button(account.busy == .billing ? "Opening…" : "Manage billing") { account.manageBilling() }
                                .disabled(account.busy != nil)
                        }
                    }
                }
            }
        } else {
            // Signed in, and the first refresh has not come back yet.
            Section("Signed in") {
                HStack {
                    AccountProgress(text: "Loading your account…")
                    Spacer()
                }
                if let problem = account.problem {
                    Notice(.error, problem, action: ("Try again", { account.refresh() }))
                }
                HStack {
                    Spacer()
                    Button("Sign out") { account.signOut() }
                        .disabled(account.busy != nil)
                }
            }
        }
    }

    @ViewBuilder
    private func subscribe(_ summary: AccountPlanSummary) -> some View {
        if account.paymentWait != nil {
            SettingRow(hint: "Finish the checkout in your browser. This page updates by itself once the payment is through.") {
                LabeledContent("Subscribe") {
                    HStack(spacing: 8) {
                        AccountProgress(text: "Waiting for payment…")
                        Button("Stop waiting") { account.stopWaitingForPayment() }
                    }
                }
            }
        } else if !account.offers.isEmpty {
            SettingRow(hint: "Applied at checkout. Leave empty if you have none.") {
                TextField("Voucher code", text: $account.voucher, prompt: Text("Code"))
                    .autocorrectionDisabled()
            }
            SettingRow(hint: summary.subscribeHint) {
                LabeledContent("Subscribe") {
                    HStack(spacing: 8) {
                        ForEach(account.offers, id: \.url) { offer in
                            Button(offer.label) { account.subscribe(offer) }
                        }
                    }
                }
            }
            if account.paymentOutcome == .gaveUp {
                Notice(.error, "No payment came through in 10 minutes. If you paid, stew picks it up at its next check.", action: ("Check now", { account.refresh() }))
            }
        }
    }
}

/// The one form of "stew is waiting for something": a small spinner and a short line.
struct AccountProgress: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Ink.secondary)
        }
    }
}

extension AccountPlanSummary.Tone {
    var color: Color {
        switch self {
        case .good: Tone.green.color
        case .attention: Tone.orange.color
        case .neutral: Ink.secondary
        }
    }
}
