import Foundation

extension StewRequest {
    /// The copy History keeps: commands masked as the panel shows them, a secret input's
    /// default left out, and nothing that only routes a late answer (the origin and the
    /// time limits). Only whether the agent asks in its own prompt on a timeout stays,
    /// because History says what the agent was told.
    public var forHistory: StewRequest {
        var copy = StewRequest(session: session, prompt: prompt, wait: wait)
        if agentAsksOnTimeout { copy.origin = RequestOrigin(agentAsksOnTimeout: true) }
        switch prompt {
        case .permission(var permission):
            permission.command = permission.command.map { CommandText.masked($0) }
            permission.blocked = permission.blocked?.forHistory
            copy.prompt = .permission(permission)
        case .input(var input):
            input.question = CommandText.masked(input.question)
            input.why = input.why.map { CommandText.masked($0) }
            if input.secret { input.defaultText = nil }
            copy.prompt = .input(input)
        case .needs(var needs):
            needs.commands = needs.commands.map { NeedsCommand(label: $0.label, command: CommandText.masked($0.command)) }
            copy.prompt = .needs(needs)
        case .question, .notify:
            break
        }
        return copy
    }
}

extension HistoryEntry {
    /// The request to show for this entry: the one kept with it, or, for an entry from
    /// before stew kept it, one rebuilt from the summary and the details.
    public var previewRequest: StewRequest {
        if let request { return request }
        let session = SessionInfo(name: session, cwd: cwd)
        let prompt: Prompt
        switch kind {
        case "permission":
            prompt = .permission(PermissionRequest(action: summary, command: command, reason: detail ?? "", blocked: blocked))
        case "question":
            prompt = .question(QuestionSet(questions: Self.questions(fromDetail: detail, summary: summary)))
        case "input":
            prompt = .input(InputRequest(question: summary, why: detail, secret: secret == true))
        case "needs":
            let commands = (command ?? "").split(separator: "\n").map { NeedsCommand(command: String($0)) }
            prompt = .needs(NeedsRequest(title: summary, why: detail, commands: commands))
        default:
            prompt = .notify(NotifyRequest(title: summary, body: detail))
        }
        return StewRequest(session: session, prompt: prompt, wait: kind != "notify" && kind != "needs")
    }

    /// The questions in `detail` as `record` wrote them: each question on a line, its
    /// options under it as "  - label", a blank line between questions.
    static func questions(fromDetail detail: String?, summary: String) -> [Question] {
        let blocks = (detail ?? "").components(separatedBy: "\n\n").compactMap { block -> Question? in
            let lines = block.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let text = lines.first, !text.isEmpty else { return nil }
            let options = lines.dropFirst().compactMap { line -> QuestionOption? in
                guard line.hasPrefix("- ") else { return nil }
                return QuestionOption(label: String(line.dropFirst(2)), description: "")
            }
            return Question(question: text, header: "", options: options)
        }
        return blocks.isEmpty ? [Question(question: summary, header: "", options: [])] : blocks
    }

    /// The answers the user gave, now or late.
    public var givenAnswers: [String: String]? {
        late?.answers ?? answers
    }

    /// One line on how the request ended, in place of the panel's buttons: "Approved
    /// Nov 12, 03:31 on Studio", "Timed out Nov 12, 03:31", "Approved late Nov 13,
    /// 09:02 on Sam's iPhone".
    public func outcomeLine(timeText: (Date) -> String) -> String {
        if let late {
            return [late.outcome.label(for: agent) + " late", timeText(late.answered), late.answeredOn.map { "on \($0)" }]
                .compactMap { $0 }.joined(separator: " ")
        }
        return [outcome.label(for: agent), timeText(ended), answeredOn.map { "on \($0)" }].compactMap { $0 }.joined(separator: " ")
    }
}

extension History {
    /// Missed requests the user has not seen yet: the same ones the menu bar counts.
    public static func unseenMissedIDs(_ entries: [HistoryEntry], seenAt: Date?) -> Set<UUID> {
        let cutoff = seenAt.map(wholeSecond)
        return Set(entries.filter { entry in
            entry.answerableLater && entry.late == nil && (cutoff.map { entry.ended > $0 } ?? true)
        }.map(\.id))
    }
}
