import AppKit
import SwiftUI
import StewCore

/// Standing approvals: hour and category grants in stew's store, and the rules stew
/// wrote into Claude Code allow lists. Revoking a rule removes it from its settings file.
final class ApprovalsModel: ObservableObject {
    @Published private(set) var grants: [Grant] = []
    @Published private(set) var error: String?

    func reload() {
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
        VStack(alignment: .leading, spacing: 10) {
            Text("Calls that auto mode blocks but these approvals let through without asking. Rules in a project's .claude/settings.local.json are enforced by Claude Code itself.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.grants.isEmpty {
                Spacer()
                Text("No standing approvals. Choose \"Allow more…\" on a blocked call to add one.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                Table(model.grants) {
                    TableColumn("Allows") { grant in
                        Text(grant.value)
                            .font(.system(size: 12, design: grant.kind == .category ? .default : .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(grant.value)
                    }
                    .width(min: 220, ideal: 320)
                    TableColumn("Kind") { grant in
                        Text(kindLabel(grant.kind))
                    }
                    .width(min: 140, ideal: 160)
                    TableColumn("Project") { grant in
                        Text(grant.projectRoot.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Any")
                            .help(grant.projectRoot ?? "")
                    }
                    .width(min: 90, ideal: 120)
                    TableColumn("Until") { grant in
                        if let expires = grant.expires {
                            Text(expires, style: .time).monospacedDigit()
                        } else {
                            Text("Always")
                        }
                    }
                    .width(min: 70, ideal: 80)
                    TableColumn("") { grant in
                        Button("Revoke") { model.revoke(grant) }
                    }
                    .width(70)
                }
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 260)
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
