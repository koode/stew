import Foundation

/// A command the user runs themselves, such as a login. The panel masks secrets in it,
/// and the copy button copies it as given.
public struct NeedsCommand: Codable, Equatable, Sendable {
    public var label: String?
    public var command: String

    public init(label: String? = nil, command: String) {
        self.label = label
        self.command = command
    }
}

public struct NeedsLink: Codable, Equatable, Sendable {
    public var label: String?
    public var url: String

    public init(label: String? = nil, url: String) {
        self.label = label
        self.url = url
    }

    /// The label, else the URL without its scheme, so a long link still reads as a place.
    public var displayText: String {
        if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty { return label }
        for scheme in ["https://", "http://"] where url.lowercased().hasPrefix(scheme) {
            return String(url.dropFirst(scheme.count))
        }
        return url
    }
}

/// Something only the user can do before Claude can go on: log in, buy, approve in a
/// web page, plug something in.
public struct NeedsRequest: Codable, Equatable, Sendable {
    public var title: String
    public var why: String?
    public var steps: [String]
    public var commands: [NeedsCommand]
    public var links: [NeedsLink]
    /// Made by the Stop hook from a `needs input:` line, not by Claude calling stew. The
    /// next message to that session clears it, and each session has at most one.
    public var automatic: Bool
    /// The title of the Done button: the state the user reaches, such as "Signed in".
    /// Nil shows "Done".
    public var doneLabel: String?
    /// Other ways the item can end besides Done, such as "Can't sign in". Each one ends
    /// the item and tells Claude which one the user picked.
    public var answers: [String]

    public init(
        title: String, why: String? = nil, steps: [String] = [], commands: [NeedsCommand] = [], links: [NeedsLink] = [],
        automatic: Bool = false, doneLabel: String? = nil, answers: [String] = []
    ) {
        self.title = title
        self.why = why
        self.steps = steps
        self.commands = commands
        self.links = links
        self.automatic = automatic
        self.doneLabel = doneLabel
        self.answers = answers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        why = try container.decodeIfPresent(String.self, forKey: .why)
        steps = try container.decodeIfPresent([String].self, forKey: .steps) ?? []
        commands = try container.decodeIfPresent([NeedsCommand].self, forKey: .commands) ?? []
        links = try container.decodeIfPresent([NeedsLink].self, forKey: .links) ?? []
        automatic = try container.decodeIfPresent(Bool.self, forKey: .automatic) ?? false
        doneLabel = try container.decodeIfPresent(String.self, forKey: .doneLabel)
        answers = try container.decodeIfPresent([String].self, forKey: .answers) ?? []
    }

    public static let defaultDoneLabel = "Done"

    /// What the Done button says.
    public var doneTitle: String {
        let trimmed = doneLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? Self.defaultDoneLabel : trimmed
    }

    /// Whether Claude chose the answers. Then the reply names the one the user picked,
    /// also for Done; without them the reply stays as it always was.
    public var hasCustomAnswers: Bool {
        doneLabel != nil || !answers.isEmpty
    }

    /// The label Claude gets for a picked answer: the extra answer at `index`, or the
    /// Done title for nil. Nil when the item has no custom answers or `index` is out of range.
    public func answerLabel(at index: Int?) -> String? {
        guard hasCustomAnswers else { return nil }
        guard let index else { return doneTitle }
        return answers.indices.contains(index) ? answers[index] : nil
    }

    public static let maxTitle = 200
    public static let maxWhy = 4000
    public static let maxSteps = 20
    public static let maxCommands = 10
    public static let maxLinks = 10
    /// Short enough for a button next to Decline, Note and Not now.
    public static let maxDoneLabel = 24
    public static let maxAnswer = 40
    /// One per ⌘1 to ⌘3 key.
    public static let maxAnswers = 3
    /// The panel's fixed buttons. An answer with one of these titles would read as that button.
    public static let reservedLabels = ["Decline", "Note", "Not now"]

    public struct ValidationError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// Links open in the browser on a click, so only web addresses are allowed: a
    /// `file:` or app URL could start a program.
    public static func isWebURL(_ text: String) -> Bool {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = url.host, !host.isEmpty else { return false }
        return true
    }

    public func validate() throws {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { throw ValidationError(description: "the title is empty") }
        guard !trimmedTitle.contains(where: \.isNewline) else { throw ValidationError(description: "the title must be one line; put details in --why or --step") }
        guard trimmedTitle.count <= Self.maxTitle else { throw ValidationError(description: "the title is longer than \(Self.maxTitle) characters") }
        if let why, why.count > Self.maxWhy { throw ValidationError(description: "--why is longer than \(Self.maxWhy) characters") }
        guard steps.count <= Self.maxSteps else { throw ValidationError(description: "at most \(Self.maxSteps) steps, got \(steps.count)") }
        guard commands.count <= Self.maxCommands else { throw ValidationError(description: "at most \(Self.maxCommands) commands, got \(commands.count)") }
        guard links.count <= Self.maxLinks else { throw ValidationError(description: "at most \(Self.maxLinks) links, got \(links.count)") }
        if steps.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw ValidationError(description: "a step is empty")
        }
        if commands.contains(where: { $0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw ValidationError(description: "a command is empty")
        }
        if let link = links.first(where: { !Self.isWebURL($0.url) }) {
            throw ValidationError(description: "\"\(link.url)\" is not an http or https URL")
        }
        try validateAnswers()
    }

    private func validateAnswers() throws {
        if let doneLabel {
            let trimmed = doneLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ValidationError(description: "--done is empty") }
            guard !trimmed.contains(where: \.isNewline) else { throw ValidationError(description: "--done must be one line") }
            guard trimmed.count <= Self.maxDoneLabel else { throw ValidationError(description: "--done is longer than \(Self.maxDoneLabel) characters") }
            guard !Self.reservedLabels.contains(where: { $0.lowercased() == trimmed.lowercased() }) else {
                throw ValidationError(description: "--done \"\(trimmed)\" is already a button; pick the state the user reaches, such as \"Signed in\"")
            }
        }
        guard answers.count <= Self.maxAnswers else { throw ValidationError(description: "at most \(Self.maxAnswers) answers, got \(answers.count)") }
        var seen = Set(([doneTitle] + Self.reservedLabels).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        for answer in answers {
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ValidationError(description: "an answer is empty") }
            guard !trimmed.contains(where: \.isNewline) else { throw ValidationError(description: "an answer must be one line") }
            guard trimmed.count <= Self.maxAnswer else { throw ValidationError(description: "the answer \"\(trimmed)\" is longer than \(Self.maxAnswer) characters") }
            guard seen.insert(trimmed.lowercased()).inserted else {
                throw ValidationError(description: "the answer \"\(trimmed)\" is already a button; every answer needs its own label")
            }
        }
    }
}

/// One open item, as kept in needs.json until it is done, declined or resolved.
public struct NeedsItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var created: Date
    public var session: SessionInfo
    public var needs: NeedsRequest
    /// "Not now": still open, but out of the panel until the user opens it from the menu bar.
    public var parked: Bool
    /// A parked item comes back once when the user returns to the Mac; after that only
    /// the menu bar and the return summary remind them.
    public var reminded: Bool

    public init(id: String, created: Date, session: SessionInfo, needs: NeedsRequest, parked: Bool = false, reminded: Bool = false) {
        self.id = id
        self.created = created
        self.session = session
        self.needs = needs
        self.parked = parked
        self.reminded = reminded
    }

    /// "session · title", for the menu bar and `stew needs list`.
    public var menuTitle: String { "\(session.name) · \(needs.title)" }
}

/// The rules for the set of open items, kept pure so they are testable.
public enum NeedsBook {
    /// Short enough to type in `stew needs resolve ID`, unique among the open items.
    public static func newID(existing: [NeedsItem], random: () -> UUID = UUID.init) -> String {
        let taken = Set(existing.map(\.id))
        while true {
            let candidate = String(random().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8))
            if !taken.contains(candidate) { return candidate }
        }
    }

    /// Adds `item`. An automatic item replaces the session's earlier automatic one, so a
    /// session that stops several times without an answer shows only its latest need.
    /// Returns the items it replaced.
    @discardableResult
    public static func add(_ item: NeedsItem, to items: inout [NeedsItem]) -> [NeedsItem] {
        var replaced: [NeedsItem] = []
        if item.needs.automatic, let sessionID = item.session.id, !sessionID.isEmpty {
            replaced = items.filter { $0.needs.automatic && $0.session.id == sessionID }
            items.removeAll { $0.needs.automatic && $0.session.id == sessionID }
        }
        items.append(item)
        return replaced
    }

    /// The automatic items a new message to the session answers.
    public static func answeredBy(sessionID: String, in items: [NeedsItem]) -> [NeedsItem] {
        guard !sessionID.isEmpty else { return [] }
        return items.filter { $0.needs.automatic && $0.session.id == sessionID }
    }

    /// Whether the session already has an open item Claude made with `stew needs`. Then
    /// the Stop hook adds no automatic item for the same need: Claude follows the skill,
    /// which asks for both the command and the `needs input:` line.
    public static func hasOpenCLIItem(sessionID: String?, in items: [NeedsItem]) -> Bool {
        guard let sessionID, !sessionID.isEmpty else { return false }
        return items.contains { !$0.needs.automatic && $0.session.id == sessionID }
    }

    /// The return summary line for open items.
    public static func countText(_ count: Int) -> String {
        count == 1 ? "1 thing needs you" : "\(count) things need you"
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func encode(_ items: [NeedsItem]) throws -> Data {
        try encoder.encode(items) + Data("\n".utf8)
    }

    /// An unreadable file counts as empty rather than stopping the daemon.
    public static func decode(_ data: Data) -> [NeedsItem] {
        guard !data.isEmpty else { return [] }
        return (try? decoder.decode([NeedsItem].self, from: data)) ?? []
    }
}

/// Order of the panel queue. Permission requests, questions and notifications go ahead
/// of needs items, so a needs item shows only when nothing else is waiting. The front
/// item stays where it is while the user types a note on it, or once they started
/// answering it, so their text and choices never end up under a different request.
public enum PanelQueue {
    public static func ordered<Element>(_ elements: [Element], frontPinned: Bool, isNeeds: (Element) -> Bool) -> [Element] {
        guard let first = elements.first else { return elements }
        let rest = frontPinned ? Array(elements.dropFirst()) : elements
        let arranged = rest.filter { !isNeeds($0) } + rest.filter(isNeeds)
        return frontPinned ? [first] + arranged : arranged
    }
}

/// The notice shown when the user comes back to the Mac: requests that timed out while
/// they were away, and things that still need them. Nil when there is neither.
public enum ReturnSummary {
    /// `laterCount` counts secrets the user chose to enter later: like missed requests,
    /// they wait in the history, so the notice opens it.
    public static func notice(missedCount: Int, laterCount: Int = 0, needsCount: Int) -> NotifyRequest? {
        var lines: [String] = []
        let title: String
        if missedCount > 0 {
            title = History.returnSummary(missedCount: missedCount)
            if laterCount > 0 { lines.append(History.enterLaterSummary(laterCount) + ".") }
        } else if laterCount > 0 {
            title = History.enterLaterSummary(laterCount)
        } else if needsCount > 0 {
            return NotifyRequest(title: NeedsBook.countText(needsCount), level: .info)
        } else {
            return nil
        }
        if needsCount > 0 { lines.append(NeedsBook.countText(needsCount) + ".") }
        return NotifyRequest(
            title: title,
            body: lines.isEmpty ? nil : lines.joined(separator: " "),
            level: .warning,
            action: .openHistory
        )
    }
}

/// Reads the `needs input:` convention from Claude's last message: the line names what
/// Claude needs, a numbered list after it gives the steps, fenced code blocks give the
/// commands to copy, and web addresses outside code blocks give the links.
public enum NeedsParser {
    /// Few enough that the links stay a short list under the steps.
    public static let maxLinks = 4

    public static func parse(_ message: String, agent: CodingAgent = .claudeCode) -> NeedsRequest? {
        let lines = message.components(separatedBy: .newlines)
        var inFence = false
        var markerIndex: Int?
        var title = ""
        for (index, line) in lines.enumerated() {
            if isFence(line) {
                inFence.toggle()
                continue
            }
            if !inFence, let rest = markerRest(line) {
                markerIndex = index
                title = rest
                break
            }
        }
        guard let markerIndex else { return nil }
        let following = Array(lines[(markerIndex + 1)...])
        if title.isEmpty {
            title = following.lazy
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !isFence($0) && numberedItem($0) == nil } ?? ""
        }
        if title.isEmpty { title = "\(agent.name) needs your input" }
        if title.count > NeedsRequest.maxTitle { title = String(title.prefix(NeedsRequest.maxTitle - 1)) + "…" }
        return NeedsRequest(
            title: title,
            steps: Array(steps(in: following).prefix(NeedsRequest.maxSteps)),
            commands: Array(codeBlocks(in: lines).prefix(NeedsRequest.maxCommands)).map { NeedsCommand(command: $0) },
            links: Array(links(in: lines).prefix(maxLinks)).map { NeedsLink(url: $0) },
            automatic: true
        )
    }

    private static let marker = try! NSRegularExpression(pattern: #"^[\s>#*_]*needs input[*_]*\s*:[*_]*\s*(.*)$"#, options: [.caseInsensitive])
    private static let numbered = try! NSRegularExpression(pattern: #"^\s*\d{1,2}[.)]\s+(.+)$"#)
    private static let webAddress = try! NSRegularExpression(pattern: #"https?://[^\s<>()\[\]{}"'`]+"#, options: [.caseInsensitive])

    /// http and https addresses outside code blocks, in order, each once. Punctuation that
    /// ends the sentence is not part of the address. A URL in a code block belongs to a
    /// command, not to the links.
    static func links(in lines: [String]) -> [String] {
        var found: [String] = []
        var inFence = false
        for line in lines {
            if isFence(line) {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            let range = NSRange(line.startIndex..., in: line)
            for match in webAddress.matches(in: line, range: range) {
                guard let matched = Range(match.range, in: line) else { continue }
                var address = String(line[matched])
                while let last = address.last, ".,;:!?*_".contains(last) { address.removeLast() }
                if NeedsRequest.isWebURL(address), !found.contains(address) { found.append(address) }
            }
        }
        return found
    }

    static func markerRest(_ line: String) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = marker.firstMatch(in: line, range: range), let rest = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[rest]).trimmingCharacters(in: .whitespaces)
    }

    static func numberedItem(_ line: String) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = numbered.firstMatch(in: line, range: range), let text = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[text]).trimmingCharacters(in: .whitespaces)
    }

    static func isFence(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    /// The first numbered list after the marker. Code blocks and indented lines inside it
    /// belong to the current step; the first plain line after it ends the list.
    static func steps(in lines: [String]) -> [String] {
        var steps: [String] = []
        var inFence = false
        for line in lines {
            if isFence(line) {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if let item = numberedItem(line) {
                steps.append(item)
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !steps.isEmpty, !trimmed.isEmpty else { continue }
            if line.first == " " || line.first == "\t" {
                steps[steps.count - 1] += " " + trimmed
            } else {
                break
            }
        }
        return steps
    }

    /// The contents of every fenced code block, without the indentation of the fence.
    static func codeBlocks(in lines: [String]) -> [String] {
        var blocks: [String] = []
        var current: [String]?
        var indent = 0
        for line in lines {
            if isFence(line) {
                if let finished = current {
                    let text = finished.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { blocks.append(text) }
                    current = nil
                } else {
                    current = []
                    indent = line.prefix { $0 == " " || $0 == "\t" }.count
                }
                continue
            }
            if current != nil {
                let leading = line.prefix { $0 == " " || $0 == "\t" }.count
                current?.append(String(line.dropFirst(min(indent, leading))))
            }
        }
        return blocks
    }
}

/// The fields stew reads from a Stop or UserPromptSubmit hook. Neither event has a tool
/// call, so `HookCall` does not fit.
public struct TurnHookInput: Equatable, Sendable {
    public var sessionID: String?
    public var cwd: String?
    public var transcriptPath: String?
    /// Stop only: the text of Claude's final response. The transcript can lag behind it.
    public var lastAssistantMessage: String?
    /// The subagent or teammate the hook fired in; nil for the main agent.
    public var agentID: String?

    public init(sessionID: String? = nil, cwd: String? = nil, transcriptPath: String? = nil, lastAssistantMessage: String? = nil, agentID: String? = nil) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.lastAssistantMessage = lastAssistantMessage
        self.agentID = agentID
    }

    public static func parse(_ data: Data) -> TurnHookInput? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let message = (object["last_assistant_message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return TurnHookInput(
            sessionID: object["session_id"] as? String,
            cwd: object["cwd"] as? String,
            transcriptPath: object["transcript_path"] as? String,
            lastAssistantMessage: message,
            agentID: (object["agent_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

/// Whether the Stop hook turns a `needs input:` line into a needs item. Same modes and
/// meaning as question routing: "unattended" means background and remote sessions.
public enum AutoNeeds {
    public static func shouldCreate(mode: String, attended: String?) -> Bool {
        QuestionRouting.shouldRoute(mode: mode, attended: attended)
    }
}
