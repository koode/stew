import Foundation
import Testing
@testable import StewCore

@Suite struct NeedsAnswersTests {
    private let signIn = NeedsRequest(
        title: "Sign in to App Store Connect in the open browser window",
        doneLabel: "Signed in",
        answers: ["Can't sign in", "Use another account"]
    )

    @Test func oldJSONDecodesWithDoneAndNoOtherAnswers() throws {
        let decoded = try JSONDecoder().decode(NeedsRequest.self, from: Data(#"{"title":"Buy more credits","steps":["Open billing"]}"#.utf8))
        #expect(decoded.doneLabel == nil)
        #expect(decoded.answers.isEmpty)
        #expect(decoded.doneTitle == "Done")
        #expect(!decoded.hasCustomAnswers)
    }

    @Test func oldNeedsFileStillLoads() throws {
        let file = #"[{"id":"3f9a1c2e","created":"2027-01-15T08:00:00Z","session":{"name":"job"},"needs":{"title":"Log in","steps":[],"commands":[],"links":[],"automatic":false},"parked":false,"reminded":false}]"#
        let items = NeedsBook.decode(Data(file.utf8))
        #expect(items.count == 1)
        #expect(items.first?.needs.doneTitle == "Done")
    }

    @Test func newJSONKeepsTheLabelsOverTheWire() throws {
        let request = StewRequest(session: SessionInfo(name: "job"), prompt: .needs(signIn), wait: false)
        let line = try Wire.encode(request)
        let text = String(decoding: line, as: UTF8.self)
        #expect(text.contains(#""doneLabel":"Signed in""#))
        #expect(text.contains(#""answers":["Can't sign in","Use another account"]"#))
        #expect(try Wire.decode(StewRequest.self, line: line.dropLast()) == request)
    }

    @Test func acceptsLabelsAtTheLimits() throws {
        try signIn.validate()
        try NeedsRequest(
            title: "x",
            doneLabel: String(repeating: "d", count: 24),
            answers: [String(repeating: "a", count: 40), String(repeating: "b", count: 40), String(repeating: "c", count: 40)]
        ).validate()
    }

    @Test func refusesBadLabels() {
        let refused: [(NeedsRequest, String)] = [
            (NeedsRequest(title: "x", doneLabel: " "), "--done is empty"),
            (NeedsRequest(title: "x", doneLabel: "two\nlines"), "--done must be one line"),
            (NeedsRequest(title: "x", doneLabel: String(repeating: "d", count: 25)), "--done is longer than 24"),
            (NeedsRequest(title: "x", doneLabel: "Not now"), "is already a button"),
            (NeedsRequest(title: "x", answers: ["a", "b", "c", "d"]), "at most 3 answers"),
            (NeedsRequest(title: "x", answers: ["ok", "  "]), "an answer is empty"),
            (NeedsRequest(title: "x", answers: ["one\ntwo"]), "an answer must be one line"),
            (NeedsRequest(title: "x", answers: [String(repeating: "a", count: 41)]), "longer than 40"),
            (NeedsRequest(title: "x", answers: ["Later", "later"]), "already a button"),
            (NeedsRequest(title: "x", doneLabel: "Signed in", answers: ["signed in"]), "already a button"),
            (NeedsRequest(title: "x", answers: ["Done"]), "already a button"),
            (NeedsRequest(title: "x", answers: ["Decline"]), "already a button"),
        ]
        for (needs, message) in refused {
            do {
                try needs.validate()
                Issue.record("accepted \(needs)")
            } catch {
                #expect("\(error)".contains(message), "\(error) should mention \(message)")
            }
        }
    }

    @Test func answerLabels() {
        #expect(signIn.answerLabel(at: nil) == "Signed in")
        #expect(signIn.answerLabel(at: 1) == "Use another account")
        #expect(signIn.answerLabel(at: 2) == nil)
        // Answers without --done: the button stays "Done", and Claude still learns which one.
        let onlyAnswers = NeedsRequest(title: "x", answers: ["Later"])
        #expect(onlyAnswers.answerLabel(at: nil) == "Done")
        // Without labels of its own the reply stays as it always was.
        #expect(NeedsRequest(title: "x").answerLabel(at: nil) == nil)
    }

    @Test func repliesKeepThePlainDoneUnchanged() throws {
        let plain = String(decoding: try Wire.encode(StewResponse(status: .done, id: "3f9a1c2e")), as: UTF8.self)
        #expect(plain == #"{"id":"3f9a1c2e","status":"done"}"# + "\n")
        let labelled = String(decoding: try Wire.encode(StewResponse(status: .done, id: "3f9a1c2e", answer: "Signed in")), as: UTF8.self)
        #expect(labelled == #"{"answer":"Signed in","id":"3f9a1c2e","status":"done"}"# + "\n")
        let other = StewResponse(status: .answered, note: "2FA goes to the old phone", id: "3f9a1c2e", answer: "Can't sign in")
        #expect(String(decoding: try Wire.encode(other), as: UTF8.self) == #"{"answer":"Can't sign in","id":"3f9a1c2e","note":"2FA goes to the old phone","status":"answered"}"# + "\n")
        #expect(other.exitCode == 0)
    }

    @Test func historyKeepsThePickedAnswer() throws {
        let record = NeedsItem(id: "3f9a1c2e", created: Date(timeIntervalSince1970: 1_800_000_000), session: SessionInfo(name: "job"), needs: signIn)
        let entry = HistoryEntry.record(record, outcome: .answered, note: "later", answer: "Can't sign in", ended: Date(timeIntervalSince1970: 1_800_000_060))
        #expect(entry.answer == "Can't sign in")
        #expect(entry.outcome.label == "Answered")
        #expect(History.parse(try History.line(entry)) == [entry])
        // A line written before the field existed still reads.
        let old = #"{"id":"00000000-0000-0000-0000-000000000001","received":"2027-01-15T08:00:00Z","ended":"2027-01-15T08:01:00Z","session":"job","kind":"needs","summary":"Log in","outcome":"done"}"#
        let parsed = History.parse(Data(old.utf8))
        #expect(parsed.count == 1)
        #expect(parsed.first?.answer == nil)
    }
}
