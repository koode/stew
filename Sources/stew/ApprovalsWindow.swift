import AppKit
import SwiftUI
import StewCore

/// Standing approvals: hour and category grants in stew's store, and the rules stew
/// wrote into Claude Code allow lists. Revoking a rule removes it from its settings file.
final class ApprovalsModel: ObservableObject {
    @Published private(set) var grants: [Grant] = []
    @Published private(set) var error: String?
    /// Sample grants for `stew snapshot`: reloading leaves them alone.
    private var isSample = false

    func showSample(_ grants: [Grant]) {
        isSample = true
        self.grants = grants
    }

    func reload() {
        guard !isSample else { return }
        let now = Date()
        grants = GrantFile.read()
            .filter { $0.isStanding && $0.isLive(at: now) }
            .sorted { $0.created > $1.created }
    }

    func revoke(_ grant: Grant) {
        do {
            if grant.kind == .claudeRule, let settingsPath = grant.settingsPath {
                let current = FileManager.default.contents(atPath: settingsPath)
                let updated = try ClaudeSettings.removingAllowRule(grant.value, from: current)
                try updated.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
            }
            GrantFile.update { grants in grants.removeAll { $0.id == grant.id } }
            error = nil
        } catch {
            self.error = "Could not revoke \(grant.value): \(error)"
        }
        reload()
    }
}

struct ApprovalsView: View {
    @ObservedObject var model: ApprovalsModel

    var body: some View {
        SettingsPane(tab: .approvals) {
            VStack(alignment: .leading, spacing: 10) {
                if model.grants.isEmpty {
                    SettingsCard {
                        EmptyState(
                            symbol: "lock.open",
                            title: "No standing approvals",
                            message: "Choose \"Allow more…\" on a blocked call to add one."
                        )
                        .frame(maxHeight: .infinity)
                    }
                } else {
                    SettingsCard {
                        Table(model.grants) {
                            TableColumn("Allows") { grant in
                                Text(grant.value)
                                    .font(.system(size: 12, design: grant.kind == .category ? .default : .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(grant.value)
                            }
                            .width(min: 160, ideal: 196)
                            TableColumn("Kind") { grant in
                                Text(kindLabel(grant.kind)).font(.system(size: 12))
                            }
                            .width(132)
                            TableColumn("Project") { grant in
                                Text(grant.projectRoot.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Any").font(.system(size: 12))
                                    .help(grant.projectRoot ?? "")
                            }
                            .width(86)
                            TableColumn("Until") { grant in
                                Text(grant.expires.map(SettingsDate.text) ?? "Always").font(.system(size: 12)).monospacedDigit()
                            }
                            .width(104)
                            TableColumn("") { grant in
                                Button("Revoke", role: .destructive) { model.revoke(grant) }
                                    .buttonStyle(.bordered)
                            }
                            .width(72)
                        }
                        .scrollContentBackground(.hidden)
                        .alternatingRowBackgrounds(.disabled)
                    }
                }
                Hint("Rules in a project's .claude/settings.local.json are enforced by Claude Code itself.")
                if let error = model.error {
                    Notice(.error, error)
                }
            }
            .padding(.horizontal, SettingsMetrics.inset)
            .padding(.top, 14)
            .padding(.bottom, SettingsMetrics.inset)
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in model.reload() }
    }

    private func kindLabel(_ kind: Grant.Kind) -> String {
        switch kind {
        case .pattern: "Command pattern"
        case .category: "Auto mode category"
        case .claudeRule: "Claude Code allow rule"
        case .once, .denyNote: "Single call"
        }
    }
}
