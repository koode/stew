import Foundation
import Testing
@testable import StewCore

private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let session = SessionInfo(name: "release", id: "s1", cwd: "/work/app")
private let secretValue = "hunter2-very-secret"

private func inputRequest(_ input: InputRequest, session requestSession: SessionInfo = session) -> StewRequest {
    StewRequest(session: requestSession, prompt: .input(input))
}

private let domain = InputRequest(question: "Which domain?", why: "The DNS record needs it.", placeholder: "example.com", pattern: "[a-z0-9.-]+\\.[a-z]{2,}")
private let otp = InputRequest(question: "What is the npm one-time password?", why: "npm publish asks for it.", secret: true)

@Suite struct InputValidationTests {
    @Test func acceptsAPlainQuestion() throws {
        try InputRequest(question: "Your name?").validate()
        try domain.validate()
        try otp.validate()
    }

    @Test func refusesAnEmptyQuestion() {
        #expect(throws: InputRequest.ValidationError.self) { try InputRequest(question: "  \n").validate() }
    }

    @Test func refusesARegexThatDoesNotCompile() {
        #expect(throws: InputRequest.ValidationError(description: "--pattern is not a valid regular expression: [a-z")) {
            try InputRequest(question: "Code?", pattern: "[a-z").validate()
        }
    }

    @Test func refusesAFormatWithoutAPattern() {
        #expect(throws: InputRequest.ValidationError(description: "--format needs --pattern: it says in plain words what the pattern expects")) {
            try InputRequest(question: "Code?", format: "6 digits").validate()
        }
    }

    @Test func mismatchTextPrefersTheFormat() {
        let code = InputRequest(question: "Code?", pattern: "^[0-9]{6}$", format: "6 digits")
        #expect(code.mismatchText == "Not in the expected format. Expected: 6 digits")
        #expect(!code.expectsRawPattern)
        let raw = InputRequest(question: "Code?", pattern: "[0-9]{6}")
        #expect(raw.mismatchText == "Not in the expected format. Expected: [0-9]{6}")
        #expect(raw.expectsRawPattern)
        let entry = HistoryEntry.record(inputRequest(code), received: start, response: nil, ended: start)
        #expect(entry.detail == "Format: 6 digits (^[0-9]{6}$)")
    }

    @Test func refusesADefaultOrSeveralLinesForASecret() {
        #expect(throws: InputRequest.ValidationError.self) { try InputRequest(question: "Token?", defaultText: "abc", secret: true).validate() }
        #expect(throws: InputRequest.ValidationError.self) { try InputRequest(question: "Token?", secret: true, multiline: true).validate() }
    }
}

@Suite struct InputPatternTests {
    @Test func theWholeAnswerMustMatch() {
        let code = InputRequest(question: "Code?", pattern: "[0-9]{6}")
        #expect(code.matches("123456"))
        #expect(!code.matches("1234567"))
        #expect(!code.matches("x123456"))
        #expect(!code.matches("12345\n6"))
    }

    @Test func anAlternationCannotStopAtAShorterPrefix() {
        let choice = InputRequest(question: "Size?", pattern: "a|ab")
        #expect(choice.matches("ab"))
        #expect(choice.matches("a"))
        #expect(!choice.matches("abc"))
    }

    @Test func noPatternMatchesAnything() {
        #expect(InputRequest(question: "Anything?").matches("whatever you like"))
    }

    @Test func checkTrimsAnswersButNotSecrets() {
        #expect(domain.check("  example.com \n") == .valid("example.com"))
        #expect(domain.check("example") == .mismatch)
        #expect(domain.check("   ") == .empty)
        #expect(otp.check(" pass word ") == .valid(" pass word "))
        #expect(otp.check("  ") == .empty)
    }
}

@Suite struct InputWireTests {
    @Test func requestRoundTripsWithItsKind() throws {
        let request = StewRequest(session: session, prompt: .input(InputRequest(
            question: "Notes?", why: "For the changelog", placeholder: "One per line", defaultText: "Fixes", pattern: ".+", multiline: true
        )), timeout: 90)
        let line = try Wire.encode(request)
        let object = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(object["kind"] as? String == "input")
        let input = try #require(object["input"] as? [String: Any])
        #expect(input["default"] as? String == "Fixes")
        #expect(try Wire.decode(StewRequest.self, line: line.dropLast()) == request)
    }

    @Test func missingSwitchesDecodeAsOff() throws {
        let line = Data(#"{"kind":"input","session":{"name":"x"},"wait":true,"input":{"question":"Name?"}}"#.utf8)
        let request = try Wire.decode(StewRequest.self, line: line)
        #expect(request.prompt == .input(InputRequest(question: "Name?")))
    }

    @Test func answerCarriesTheTextAndLaterHasItsOwnExitCode() throws {
        let answered = StewResponse(status: .answered, id: "abc", text: "example.com")
        let json = String(decoding: try Wire.encode(answered), as: UTF8.self)
        #expect(json == #"{"id":"abc","status":"answered","text":"example.com"}"# + "\n")
        #expect(answered.exitCode == 0)
        #expect(StewResponse(status: .later).exitCode == 5)
        #expect(StewResponse(status: .timeout).exitCode == 3)
        #expect(StewResponse(status: .dismissed).exitCode == 2)
    }

    @Test func timeLimitAndTimeoutNoteFollowQuestions() {
        let request = inputRequest(domain)
        #expect(request.timeLimit(defaultTimeout: 60) == 60)
        let questionNote = StewRequest(session: session, prompt: .question(QuestionSet(questions: []))).timeoutNote(after: 60)
        #expect(request.timeoutNote(after: 60) == questionNote)
        // A secret that timed out can be entered later too, so its note says a late
        // answer may follow, as for any input of a known session.
        #expect(inputRequest(otp).timeoutNote(after: 60) == request.timeoutNote(after: 60))
        #expect(request.timeoutNote(after: 60).contains("late answer"))
        #expect(!inputRequest(otp, session: SessionInfo(name: "shell")).timeoutNote(after: 60).contains("late answer"))
    }

    @Test func enterLaterNeedsASecretOfAKnownSession() {
        #expect(inputRequest(otp).offersEnterLater)
        #expect(!inputRequest(domain).offersEnterLater)
        #expect(!inputRequest(otp, session: SessionInfo(name: "shell")).offersEnterLater)
    }
}

@Suite struct InputHistoryTests {
    @Test func plainAnswerIsKept() {
        let entry = HistoryEntry.record(inputRequest(domain), received: start, response: StewResponse(status: .answered, text: "example.com"), ended: start)
        #expect(entry.kind == "input")
        #expect(entry.text == "example.com")
        #expect(entry.secret == nil)
        #expect(entry.detail == "The DNS record needs it.\n\nFormat: [a-z0-9.-]+\\.[a-z]{2,}")
    }

    @Test func secretIsNeverWrittenToTheHistory() throws {
        var entry = HistoryEntry.record(inputRequest(otp), received: start, response: StewResponse(status: .answered, text: secretValue), ended: start)
        #expect(entry.text == nil)
        #expect(entry.secret == true)
        #expect(entry.secretEntered)
        entry.recordLate(StewResponse(status: .answered, text: secretValue), message: "late", at: start)
        #expect(entry.late?.text == nil)
        let line = String(decoding: try History.line(entry), as: UTF8.self)
        #expect(!line.contains(secretValue))
    }

    @Test func laterIsAnswerableButNotMissed() {
        let entry = HistoryEntry.record(inputRequest(otp), received: start, response: StewResponse(status: .later, note: StewResponse.laterNote), ended: start)
        #expect(entry.outcome == .later)
        #expect(entry.outcomeLabel == "Enter later")
        #expect(entry.answerableLater)
        #expect(!entry.missed)
    }

    @Test func missedOnlyAndTheReturnNoticeIncludeSecretsToEnterLater() {
        let later = HistoryEntry.record(inputRequest(otp), received: start, response: StewResponse(status: .later), ended: start)
        var entered = later
        entered.recordLate(StewResponse(status: .answered), message: "late", at: start)
        let timedOut = HistoryEntry.record(inputRequest(domain), received: start, response: StewResponse(status: .timeout), ended: start)
        let answered = HistoryEntry.record(inputRequest(domain), received: start, response: StewResponse(status: .answered, text: "x.com"), ended: start)
        #expect(History.filtered([later, timedOut, answered], missedOnly: true).count == 2)
        #expect(History.enterLater([later, entered, timedOut], since: start).count == 1)
        let both = ReturnSummary.notice(missedCount: 1, laterCount: 2, needsCount: 1)
        #expect(both == NotifyRequest(title: "1 request timed out while you were away", body: "2 secrets to enter. 1 thing needs you.", level: .warning, action: .openHistory))
        let laterOnly = ReturnSummary.notice(missedCount: 0, laterCount: 1, needsCount: 0)
        #expect(laterOnly == NotifyRequest(title: "1 secret to enter", level: .warning, action: .openHistory))
    }
}

@Suite struct InputLateAnswerTests {
    @Test func aPlainInputThatTimedOutCanBeAnsweredLate() throws {
        let request = inputRequest(domain)
        #expect(LateMailbox.canAnswerLate(request))
        var mailbox = LateMailbox()
        let entryID = UUID()
        mailbox.addWaiting(request, entryID: entryID, now: start)
        let answered = mailbox.answer(entryID, with: StewResponse(status: .answered, text: "example.com"), now: start)
        let late = try #require(answered)
        #expect(late.message.contains(#""Which domain?"="example.com""#))
        #expect(late.secretQuestion == nil)
    }

    @Test func aSecretOfAKnownSessionCanBeAnsweredLate() {
        let request = inputRequest(otp)
        #expect(LateMailbox.canAnswerLate(request))
        var mailbox = LateMailbox()
        mailbox.addWaiting(request, entryID: UUID(), now: start)
        #expect(mailbox.waiting.count == 1, "the request waits; its secret, once entered, stays in memory")
        var shell = LateMailbox()
        shell.addWaiting(inputRequest(otp, session: SessionInfo(name: "shell")), entryID: UUID(), now: start)
        #expect(shell.waiting.isEmpty, "without a session nothing can receive it")
    }

    @Test func aLateSecretStaysOutOfTheMailboxFile() throws {
        var mailbox = LateMailbox()
        let entryID = UUID()
        mailbox.addWaiting(inputRequest(otp), entryID: entryID, now: start)
        // The daemon strips the text before it stores the answer.
        let answered = mailbox.answer(entryID, with: StewResponse(status: .answered), now: start)
        let late = try #require(answered)
        #expect(late.secretQuestion == "What is the npm one-time password?")
        #expect(late.message.contains(LateWording.secretToken))
        let file = String(decoding: try LateMailbox.encode(mailbox), as: UTF8.self)
        #expect(!file.contains(secretValue))
        #expect(late.revealing(secretValue).message.contains(secretValue))
        #expect(!late.revealing(secretValue).message.contains(LateWording.secretToken))
        let lost = late.revealing(nil).message
        #expect(lost.contains("stew restarted before it reached you"))
        #expect(!lost.contains(LateWording.secretToken))
    }
}

@Suite struct InputKeyTests {
    @Test func defaultKeysForTheSecretChoices() throws {
        let keymap = try Keymap(config: StewConfig())
        #expect(keymap[.enterSoon].description == "⌘5")
        #expect(keymap[.enterLater].description == "⌘L")
    }

    @Test func aKeyThatClashesOnTheInputPanelIsRefused() {
        var config = StewConfig()
        config.keys[HotkeyAction.enterLater.rawValue] = "o"
        #expect(throws: Shortcut.ParseError.self) { try Keymap(config: config) }
    }
}
