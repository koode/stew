import Foundation
import Testing
@testable import StewCore

@Suite struct SeverityParsingTests {
    @Test func parsesSeverityAndReversibility() throws {
        let output = #"{"type":"result","is_error":false,"structured_output":{"verdict":"allow","risk":"medium","rule":null,"summary":"Pushes main to origin.","severity":"medium","reversibility":"Can be undone with git reflog."}}"#
        let assessment = try RiskCheck.parse(cliOutput: Data(output.utf8))
        #expect(assessment.severity == .medium)
        #expect(assessment.reversibilityLine == "Can be undone with git reflog.")
    }

    @Test func readsResultsFromBeforeSeverity() throws {
        let output = #"{"type":"result","is_error":false,"structured_output":{"verdict":"soft_deny","risk":"high","rule":null,"summary":"Deletes a branch."}}"#
        let assessment = try RiskCheck.parse(cliOutput: Data(output.utf8))
        #expect(assessment.severity == nil)
        #expect(assessment.reversibilityLine == nil)
        #expect(assessment.verdict == .softDeny)
    }

    @Test func storedResponsesAndHistoryKeepTheNewFields() throws {
        let risk = RiskAssessment(verdict: .allow, risk: .high, rule: nil, summary: "Deletes ~/Downloads.", severity: .critical, reversibility: "Deletes files permanently; no undo.")
        let response = StewResponse(status: .approved, risk: risk)
        let decoded = try JSONDecoder().decode(StewResponse.self, from: try JSONEncoder().encode(response))
        #expect(decoded.risk == risk)

        let request = StewRequest(session: SessionInfo(name: "s", id: nil, cwd: nil), prompt: .permission(PermissionRequest(action: "Clean up", command: "rm -rf ~/Downloads", reason: "space")))
        let entry = HistoryEntry.record(request, received: Date(), response: response, ended: Date())
        #expect(entry.severity == .critical)
        #expect(entry.reversibility == "Deletes files permanently; no undo.")
        let oldEntry = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","received":0,"ended":1,"session":"s","kind":"permission","summary":"x","outcome":"approved"}"#
        #expect(try JSONDecoder().decode(HistoryEntry.self, from: Data(oldEntry.utf8)).severity == nil)
    }

    @Test func emptyReversibilityShowsNothing() {
        let risk = RiskAssessment(verdict: .allow, risk: .low, rule: nil, summary: "", severity: .low, reversibility: "  ")
        #expect(risk.reversibilityLine == nil)
    }

    @Test func schemaAsksForBothFields() throws {
        let schema = try #require(try JSONSerialization.jsonObject(with: Data(RiskCheck.schema.utf8)) as? [String: Any])
        let required = try #require(schema["required"] as? [String])
        #expect(required.contains("severity"))
        #expect(required.contains("reversibility"))
        let properties = try #require(schema["properties"] as? [String: Any])
        let severity = try #require(properties["severity"] as? [String: Any])
        #expect(severity["enum"] as? [String] == Severity.allCases.map(\.rawValue))
    }

    @Test func levelsAreOrderedAndLabeled() {
        #expect(Severity.low < .medium && Severity.medium < .high && Severity.high < .critical)
        #expect(Severity.allCases.map(\.label) == ["Low risk", "Medium risk", "High risk", "Critical risk"])
    }
}

/// The rubric the prompt teaches. Severity is what the action does, not how sensitive
/// the data is: a secret read locally stays low or medium, one sent out is high or more.
@Suite struct SeverityRubricTests {
    private func fitting(_ fragment: String) throws -> ClosedRange<Severity> {
        try #require(RiskCheck.severityExamples.first { $0.action.contains(fragment) }).fitting
    }

    @Test func keychainReadIsMediumAtMost() throws {
        #expect(try fitting("keychain").upperBound <= .medium)
    }

    @Test func secretSentToAnotherHostIsHighOrCritical() throws {
        #expect(try fitting("piped to curl").lowerBound >= .high)
    }

    @Test func buildFolderInsideTheProjectIsLowOrMedium() throws {
        #expect(try fitting("build or cache folder inside the project").upperBound <= .medium)
    }

    @Test func homeOrOutsideTheProjectIsHighOrCritical() throws {
        #expect(try fitting("rm -rf ~").lowerBound >= .high)
    }

    @Test func pushIsMediumAndForcePushToMainIsHigh() throws {
        #expect(try fitting("git push to a feature branch") == .medium ... .medium)
        #expect(try fitting("git push --force to main") == .high ... .high)
    }

    @Test func promptCarriesTheRubric() {
        let prompt = RiskCheck.systemPrompt(policyJSON: "{}")
        for example in RiskCheck.severityExamples {
            #expect(prompt.contains(example.action))
        }
        #expect(prompt.contains("reading a secret on this machine is low or medium"))
        #expect(prompt.contains("\"reversibility\""))
        #expect(prompt.contains("POLICY (JSON):\n{}"))
    }
}

@Suite struct SeverityRulesTests {
    private let defaults = StewConfig.ClassifierConfig()

    @Test func defaultsMatchTheDocumentedBehaviour() {
        #expect(defaults.criticalNeedsStrongApprove)
        #expect(defaults.highExtraTime == 60)
        #expect(defaults.phoneConfirmation == SeverityRules.PhoneScope.highAndCritical)
    }

    @Test func oldConfigGetsTheDefaults() throws {
        let config = try JSONDecoder().decode(StewConfig.self, from: Data(#"{"classifier":{"model":"sonnet"}}"#.utf8))
        #expect(config.classifier.criticalNeedsStrongApprove)
        #expect(config.classifier.highExtraTime == 60)
        #expect(config.classifier.phoneConfirmation == SeverityRules.PhoneScope.highAndCritical)
    }

    @Test func onlyCriticalNeedsTheStrongShortcut() {
        #expect(SeverityRules.needsStrongApprove(.critical, config: defaults))
        for severity in [Severity.low, .medium, .high] {
            #expect(!SeverityRules.needsStrongApprove(severity, config: defaults))
        }
        #expect(!SeverityRules.needsStrongApprove(nil, config: defaults))
        var relaxed = defaults
        relaxed.criticalNeedsStrongApprove = false
        #expect(!SeverityRules.needsStrongApprove(.critical, config: relaxed))
    }

    @Test func highAndCriticalGetExtraTime() {
        #expect(SeverityRules.extraTime(.high, config: defaults) == 60)
        #expect(SeverityRules.extraTime(.critical, config: defaults) == 60)
        #expect(SeverityRules.extraTime(.medium, config: defaults) == 0)
        #expect(SeverityRules.extraTime(.low, config: defaults) == 0)
        #expect(SeverityRules.extraTime(nil, config: defaults) == 0)
        var none = defaults
        none.highExtraTime = 0
        #expect(SeverityRules.extraTime(.high, config: none) == 0)
    }

    @Test func warningLookIsForHighAndAbove() {
        #expect(SeverityRules.warns(.high) && SeverityRules.warns(.critical))
        #expect(!SeverityRules.warns(.medium) && !SeverityRules.warns(.low) && !SeverityRules.warns(nil))
    }

    @Test func phoneConfirmationFollowsTheSetting() {
        #expect(SeverityRules.phoneConfirmation(.high, config: defaults) == .confirm)
        #expect(SeverityRules.phoneConfirmation(.critical, config: defaults) == .hold)
        #expect(SeverityRules.phoneConfirmation(.medium, config: defaults) == nil)
        #expect(SeverityRules.phoneConfirmation(nil, config: defaults) == nil)
        var criticalOnly = defaults
        criticalOnly.phoneConfirmation = SeverityRules.PhoneScope.critical
        #expect(SeverityRules.phoneConfirmation(.high, config: criticalOnly) == nil)
        #expect(SeverityRules.phoneConfirmation(.critical, config: criticalOnly) == .hold)
        var off = defaults
        off.phoneConfirmation = SeverityRules.PhoneScope.off
        #expect(SeverityRules.phoneConfirmation(.critical, config: off) == nil)
    }

    @Test func macRefusesAnUnconfirmedApproval() {
        #expect(SeverityRules.acceptsPhoneApproval(confirmation: nil, confirmed: nil))
        #expect(!SeverityRules.acceptsPhoneApproval(confirmation: .confirm, confirmed: nil))
        #expect(!SeverityRules.acceptsPhoneApproval(confirmation: .hold, confirmed: false))
        #expect(SeverityRules.acceptsPhoneApproval(confirmation: .hold, confirmed: true))
    }
}
