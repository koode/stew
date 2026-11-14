import AppKit
import SwiftUI
import StewCore

/// The menu bar popover for `stew snapshot`, drawn offscreen like the menu.
enum PopoverSnapshot {
    static func render(to directory: String, write: (AnyView, Bool, String) -> Void) {
        let sample = HistorySample.make()
        let seen = sample.entries.filter { !$0.answerableLater || $0.late != nil }
        let needs = [
            NeedsItem(id: "3f9a1c2e", created: Date(), session: SessionInfo(name: "release", cwd: "~/code/web-app"), needs: NeedsRequest(title: "Log in to npm so I can publish 2.4.0")),
            NeedsItem(id: "7b2d4e9f", created: Date(), session: SessionInfo(name: "mobile-app", cwd: "~/code/mobile-app"), needs: NeedsRequest(title: "Approve the build in App Store Connect")),
        ]
        let states: [(String, MenuBarState, [HistoryEntry], Bool, Set<UUID>)] = [
            ("menubar-popover", MenuBarState(), seen, false, []),
            ("menubar-popover-missed", MenuBarState(openNeeds: needs, missedCount: 2), sample.entries, false, sample.unseen),
            ("menubar-popover-missed-only", MenuBarState(openNeeds: needs, missedCount: 2), sample.entries, true, sample.unseen),
            ("menubar-popover-paused", MenuBarState(missedCount: 2, pause: .until(Date().addingTimeInterval(42 * 60))), sample.entries, false, sample.unseen),
            ("menubar-popover-pausing", MenuBarState(pause: .startsAt(Date().addingTimeInterval(45))), seen, false, []),
            ("menubar-popover-until-back", MenuBarState(pause: .untilBack), seen, false, []),
            ("menubar-popover-update", MenuBarState(update: .ready("0.2.0")), seen, false, []),
            ("menubar-popover-empty", MenuBarState(), [], false, []),
        ]
        for (name, state, entries, missedOnly, unseen) in states {
            for dark in [false, true] {
                let model = MenuBarPopoverModel()
                model.showSample(state: state, entries: entries, missedOnly: missedOnly, unseen: unseen)
                let path = "\(directory)/\(name)-\(dark ? "dark" : "light").png"
                write(AnyView(MenuBarPopoverView(model: model).background(Color(nsColor: .windowBackgroundColor))), dark, path)
                print(path)
            }
        }
    }
}

/// Sample history for `stew snapshot`: one of each kind of request and ending, built
/// the way the daemon records them.
enum HistorySample {
    struct Sample {
        let entries: [HistoryEntry]
        let mailbox: LateMailbox
        let unseen: Set<UUID>
    }

    /// Named entries, so each can be shown selected.
    enum Pick: String, CaseIterable {
        case blockedLate = "blocked-late"
        case secretLater = "secret-later"
        case question
        case secretEntered = "secret-entered"
        case approved
        case needs
        case lateApproved = "late-approved"
        case blockedMissed = "blocked-missed"
    }

    static let ids: [Pick: UUID] = Dictionary(uniqueKeysWithValues: Pick.allCases.map { ($0, UUID()) })

    private static let webApp = SessionInfo(name: "refactor auth middleware", id: "5b0e3c71-2f4d-4c1a-9e0b-7d6f1a2b3c4d", cwd: "~/code/web-app")
    private static let mobileApp = SessionInfo(name: "mobile-app", id: "9c1d2e77-8a6b-4f3e-b2d1-0c9e8f7a6b5d", cwd: "~/code/mobile-app")
    private static let release = SessionInfo(name: "release", id: "1e2d3c4b-5a69-4788-9a0b-c1d2e3f4a5b6", cwd: "~/code/web-app")

    static func make(now: Date = Date()) -> Sample {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func record(_ pick: Pick?, _ request: StewRequest, asked: Double, ended: Double, _ response: StewResponse?, on device: String? = "Studio") -> HistoryEntry {
            HistoryEntry.record(request, received: ago(asked), response: response, ended: ago(ended), id: pick.flatMap { ids[$0] } ?? UUID(), answeredOn: device)
        }
        let blockedPush = BlockedCall(
            toolName: "Bash", category: "Destructive or Unwanted Actions", reason: "[Destructive or Unwanted Actions]",
            hardDeny: false, projectRoot: "/Users/abby/code/web-app", suggestions: CommandText.ruleSuggestions(for: "git push --force origin main")
        )
        let forcePush = StewRequest(session: webApp, prompt: .permission(PermissionRequest(
            action: "Force-push the rebased main branch",
            command: "git push --force origin main",
            reason: "The rebase rewrote three commits on main, so a normal push is rejected. Force-pushing replaces the remote history with the rebased one.",
            blocked: blockedPush
        )))
        let timeoutNote = "The user did not respond in time."
        let otp = StewRequest(session: release, prompt: .input(InputRequest(
            question: "What is the npm one-time password?", why: "npm publish asks for it, and it changes every 30 seconds.",
            placeholder: "6 digits", pattern: "^[0-9]{6}$", format: "6 digits", secret: true
        )))
        let database = StewRequest(session: mobileApp, prompt: .question(QuestionSet(questions: [
            Question(question: "Which database should the sync service use?", header: "Database", options: [
                QuestionOption(label: "Postgres", description: "Relational, already runs the main API"),
                QuestionOption(label: "SQLite", description: "Embedded, one file per device"),
                QuestionOption(label: "DynamoDB", description: "Managed key-value store"),
            ]),
        ])))
        let token = StewRequest(session: release, prompt: .input(InputRequest(
            question: "Paste the App Store Connect API key ID", why: "The upload step signs its requests with it.", secret: true
        )))
        let migrate = StewRequest(session: webApp, prompt: .permission(PermissionRequest(
            action: "Run the database migrations", command: "pnpm db:migrate", reason: "The new session table needs them."
        )))
        let npmLogin = NeedsItem(
            id: "3f9a1c2e", created: ago(200), session: release,
            needs: NeedsRequest(
                title: "Log in to npm so I can publish 2.4.0", why: "The publish step failed with E401.",
                steps: ["Run the command below in a terminal", "Finish the login in the browser"],
                commands: [NeedsCommand(command: "npm login")],
                links: [NeedsLink(label: "npm access tokens", url: "https://www.npmjs.com/settings/tokens")]
            )
        )
        let cleanBuild = StewRequest(session: mobileApp, prompt: .permission(PermissionRequest(
            action: "Delete the build folder", command: "rm -rf build", reason: "A stale build breaks the preview."
        )))
        let tagRelease = StewRequest(session: release, prompt: .permission(PermissionRequest(
            action: "Push the v2.4.0 tag", command: "git push origin v2.4.0", reason: "The release workflow starts from the tag."
        )))
        let blockedDelete = BlockedCall(
            toolName: "Bash", category: "Destructive or Unwanted Actions", reason: "[Destructive or Unwanted Actions]",
            hardDeny: false, projectRoot: "/Users/abby/code/web-app", suggestions: CommandText.ruleSuggestions(for: "git push origin --delete release/2.1")
        )
        let deleteBranch = StewRequest(session: webApp, prompt: .permission(PermissionRequest(
            action: "Delete the release/2.1 branch on origin",
            command: "git push origin --delete release/2.1",
            reason: "The 2.1 line is no longer supported and the branch clutters the list.",
            blocked: blockedDelete
        )))
        let simulator = StewRequest(session: mobileApp, prompt: .notify(NotifyRequest(title: "Simulator tests passed", body: "312 tests in 41 s.", level: .success)), wait: false)

        var lateApproved = record(.lateApproved, tagRelease, asked: 52, ended: 50, StewResponse(status: .timeout, note: timeoutNote))
        lateApproved.recordLate(
            StewResponse(status: .approved), message: "The user approved your request to push the v2.4.0 tag after it timed out.",
            at: ago(31), on: "Sam's iPhone"
        )
        let entries = [
            record(.blockedLate, forcePush, asked: 14, ended: 9, StewResponse(
                status: .timeout, note: timeoutNote,
                risk: RiskAssessment(verdict: .softDeny, risk: .high, rule: nil, summary: "Replaces main on origin.", severity: .high, reversibility: "Rewrites history others have pulled; they must reset to recover.")
            )),
            record(.secretLater, otp, asked: 30, ended: 29, StewResponse(status: .later, note: StewResponse.laterNote)),
            record(.question, database, asked: 35, ended: 34, StewResponse(status: .answered, answers: ["Which database should the sync service use?": "Postgres"])),
            record(.secretEntered, token, asked: 41, ended: 40, StewResponse(status: .answered, text: "not kept"), on: "Sam's iPhone"),
            lateApproved,
            record(.approved, migrate, asked: 75, ended: 73, StewResponse(
                status: .approved,
                risk: RiskAssessment(verdict: .allow, risk: .medium, rule: nil, summary: "Changes the schema.", severity: .medium, reversibility: "Can be undone with the down migration.")
            )),
            record(nil, cleanBuild, asked: 130, ended: 129, StewResponse(
                status: .denied, note: "Use make clean instead.",
                risk: RiskAssessment(verdict: .allow, risk: .low, rule: nil, summary: "Deletes build output.", severity: .low, reversibility: "The next build recreates the folder.")
            )),
            HistoryEntry.record(npmLogin, outcome: .done, note: nil, ended: ago(180), id: ids[.needs]!, answeredOn: "Studio"),
            record(nil, simulator, asked: 320, ended: 319, StewResponse(status: .dismissed)),
            record(.blockedMissed, deleteBranch, asked: 26 * 60 + 2, ended: 26 * 60, StewResponse(status: .timeout, note: timeoutNote)),
        ]
        var mailbox = LateMailbox()
        mailbox.addWaiting(forcePush, entryID: ids[.blockedLate]!, now: ago(9))
        mailbox.addWaiting(otp, entryID: ids[.secretLater]!, now: ago(29))
        return Sample(entries: entries, mailbox: mailbox, unseen: [ids[.blockedLate]!, ids[.secretLater]!])
    }
}
