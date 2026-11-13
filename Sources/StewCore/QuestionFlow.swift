import Foundation

/// State of a question set while the user answers it. Pure, so the keyboard rules are testable.
public struct QuestionFlow: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case stay
        case advanced
        case complete
        /// Submit or Confirm found this question without an answer. The flow shows it, and
        /// the panel says so with `missingMessage`, so pressing the button never does nothing.
        case missing(Int)
    }

    public let questions: [Question]
    public private(set) var index: Int = 0
    public private(set) var selections: [Set<Int>]
    public private(set) var otherText: [String?]

    public init(questions: [Question]) {
        self.questions = questions
        selections = Array(repeating: [], count: questions.count)
        otherText = Array(repeating: nil, count: questions.count)
    }

    public var current: Question { questions[index] }
    public var isLast: Bool { index == questions.count - 1 }

    public func isAnswered(_ questionIndex: Int) -> Bool {
        !selections[questionIndex].isEmpty || !(otherText[questionIndex] ?? "").isEmpty
    }

    public var isComplete: Bool { questions.indices.allSatisfy(isAnswered) }

    public var firstUnanswered: Int? { questions.indices.first { !isAnswered($0) } }

    /// The name of a question on its tab: its header, or Q1, Q2 and so on.
    public func title(of questionIndex: Int) -> String {
        let header = questions[questionIndex].header
        return header.isEmpty ? "Q\(questionIndex + 1)" : header
    }

    /// What the panel says after `.missing`: which question still needs an answer.
    public func missingMessage(_ questionIndex: Int) -> String {
        guard questions.count > 1 else {
            return questions[questionIndex].multiSelect
                ? "Choose at least one option, or type an answer under Other."
                : "Choose an option, or type an answer under Other."
        }
        return "\(title(of: questionIndex)) has no answer yet."
    }

    /// Single select: pick and move on. Multi select: toggle and stay.
    public mutating func choose(_ optionIndex: Int) -> Outcome {
        guard current.options.indices.contains(optionIndex) else { return .stay }
        if current.multiSelect {
            if selections[index].contains(optionIndex) {
                selections[index].remove(optionIndex)
            } else {
                selections[index].insert(optionIndex)
            }
            return .stay
        }
        selections[index] = [optionIndex]
        otherText[index] = nil
        return advance()
    }

    /// Submit (on the last question) or Confirm (on the others). Confirm on an answered
    /// question moves on. Otherwise, while any question is open, the flow goes to the first
    /// one and returns `.missing`.
    public mutating func submitCurrent() -> Outcome {
        if isComplete { return .complete }
        if isAnswered(index), !isLast { return advance() }
        guard let open = firstUnanswered else { return .complete }
        index = open
        return .missing(open)
    }

    /// Free text answer ("Other"). Replaces the choice for single select, adds to it for multi select.
    public mutating func answerOther(_ text: String) -> Outcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return submitCurrent() }
        otherText[index] = trimmed
        if !current.multiSelect {
            selections[index] = []
        }
        return advance()
    }

    public mutating func next() {
        index = min(index + 1, questions.count - 1)
    }

    public mutating func previous() {
        index = max(index - 1, 0)
    }

    public mutating func go(to questionIndex: Int) {
        guard questions.indices.contains(questionIndex) else { return }
        index = questionIndex
    }

    private mutating func advance() -> Outcome {
        if isComplete { return .complete }
        let order = Array(questions.indices[(index + 1)...]) + Array(questions.indices[..<index])
        if let nextOpen = order.first(where: { !isAnswered($0) }) {
            index = nextOpen
        }
        return .advanced
    }

    /// AskUserQuestion answer format: question text to label, labels joined by ", " for multi select.
    public func answers() -> [String: String] {
        var result: [String: String] = [:]
        for (questionIndex, question) in questions.enumerated() where isAnswered(questionIndex) {
            var parts = selections[questionIndex].sorted().map { question.options[$0].label }
            if let other = otherText[questionIndex], !other.isEmpty {
                parts.append(other)
            }
            result[question.question] = parts.joined(separator: ", ")
        }
        return result
    }

    /// Records the preview of the chosen option, like AskUserQuestion annotations do.
    public func annotations() -> [String: QuestionAnnotation] {
        var result: [String: QuestionAnnotation] = [:]
        for (questionIndex, question) in questions.enumerated() {
            guard selections[questionIndex].count == 1,
                  let chosen = selections[questionIndex].first,
                  let preview = question.options[chosen].preview else { continue }
            result[question.question] = QuestionAnnotation(preview: preview)
        }
        return result
    }
}
