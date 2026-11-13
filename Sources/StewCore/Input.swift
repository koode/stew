import Foundation

/// One open-ended question with a typed answer: a domain, a name, a code, a password.
public struct InputRequest: Codable, Equatable, Sendable {
    public var question: String
    public var why: String?
    /// Grey text in the empty field.
    public var placeholder: String?
    /// Text the field starts with. Never set for a secret.
    public var defaultText: String?
    /// A regular expression the whole answer must match.
    public var pattern: String?
    /// A password or token: a masked field, never stored, never shown on a phone.
    public var secret: Bool
    /// Return adds a line instead of doing nothing.
    public var multiline: Bool

    /// "Give me 5 min" adds this many seconds to the clock of a secret input.
    public static let enterSoonSeconds: Double = 300

    public init(
        question: String, why: String? = nil, placeholder: String? = nil, defaultText: String? = nil,
        pattern: String? = nil, secret: Bool = false, multiline: Bool = false
    ) {
        self.question = question
        self.why = why
        self.placeholder = placeholder
        self.defaultText = defaultText
        self.pattern = pattern
        self.secret = secret
        self.multiline = multiline
    }

    private enum CodingKeys: String, CodingKey {
        case question, why, placeholder, pattern, secret, multiline
        case defaultText = "default"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        question = try container.decode(String.self, forKey: .question)
        why = try container.decodeIfPresent(String.self, forKey: .why)
        placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder)
        defaultText = try container.decodeIfPresent(String.self, forKey: .defaultText)
        pattern = try container.decodeIfPresent(String.self, forKey: .pattern)
        secret = try container.decodeIfPresent(Bool.self, forKey: .secret) ?? false
        multiline = try container.decodeIfPresent(Bool.self, forKey: .multiline) ?? false
    }

    public struct ValidationError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    public func validate() throws {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError(description: "input needs a question")
        }
        if let pattern {
            do {
                _ = try Self.wholeMatchExpression(pattern)
            } catch {
                throw ValidationError(description: "--pattern is not a valid regular expression: \(pattern)")
            }
        }
        if secret, defaultText != nil {
            throw ValidationError(description: "--default cannot be used with --secret: the default would be stored with the request")
        }
        if secret, multiline {
            throw ValidationError(description: "--multiline cannot be used with --secret: a masked field has one line")
        }
    }

    /// `\A(?:pattern)\z`, so the whole answer must match and an alternation cannot stop
    /// at a shorter prefix.
    static func wholeMatchExpression(_ pattern: String) throws -> NSRegularExpression {
        try NSRegularExpression(pattern: "\\A(?:" + pattern + ")\\z", options: [])
    }

    /// Whether the whole text matches the pattern. True without a pattern, false for a
    /// pattern that does not compile.
    public func matches(_ text: String) -> Bool {
        guard let pattern else { return true }
        guard let expression = try? Self.wholeMatchExpression(pattern) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.firstMatch(in: text, options: [], range: range) != nil
    }

    /// What a typed text would send. A secret goes as typed; other answers lose the
    /// spaces and line breaks around them.
    public func answer(from typed: String) -> String {
        secret ? typed : typed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public enum Check: Equatable, Sendable {
        case empty
        /// Typed, but not in the form the pattern asks for.
        case mismatch
        case valid(String)
    }

    /// Whether the typed text can be sent, and what would be sent.
    public func check(_ typed: String) -> Check {
        let text = answer(from: typed)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        return matches(text) ? .valid(text) : .mismatch
    }

    /// The line under the field while the text does not match.
    public static let mismatchMessage = "Not in the expected format."

    /// What both the Mac and the phone say about a secret on a phone.
    public static let enterOnMacMessage = "Enter it on your Mac."
}

extension StewRequest {
    /// "I'll enter it later" fits a secret input of a known session: the late answer
    /// needs a session to go to.
    public var offersEnterLater: Bool {
        guard case .input(let input) = prompt, input.secret, let id = session.id, !id.isEmpty else { return false }
        return true
    }
}
