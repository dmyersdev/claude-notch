import Foundation

/// Which coding agent a session belongs to.
enum AgentKind: String, Equatable, Sendable, Codable {
    case claude, codex

    var displayName: String { self == .codex ? "Codex" : "Claude Code" }
}

/// Why a session is waiting on the user.
enum Need: Equatable, Sendable {
    /// Blocked until the user answers: a permission prompt or a question dialog.
    case permission
    /// Finished its turn, or idle waiting for the next prompt.
    case yourTurn
}

/// Roughly what a session is doing, so its character can carry the right prop.
enum Activity: Equatable, Sendable {
    case thinking, writing, reading, running, searching, delegating, other

    static func of(tool: String) -> Activity {
        switch tool {
        case "Edit", "Write", "MultiEdit", "NotebookEdit": .writing
        case "Read", "Grep", "Glob", "LS", "NotebookRead": .reading
        case "Bash", "BashOutput", "KillShell", "KillBash": .running
        case "WebSearch", "WebFetch": .searching
        case "Task", "Agent": .delegating
        default: .other
        }
    }
}

/// A permission prompt Claude is about to show, with what the notch needs to answer it for the user.
struct PermissionRequest: Equatable, Sendable {
    /// "Run rm -rf build"
    var summary: String
    var tool = ""
    /// The tool's input, verbatim, so an answer can send it back with the answers filled in.
    var input = Data("{}".utf8)
    /// Claude Code's suggested rules (`permission_suggestions`), sent back as-is for "Always".
    var suggestions: Data?
    /// For `AskUserQuestion`: the questions and their options.
    var questions: [Question] = []

    var isQuestion: Bool { !questions.isEmpty }
    var canAlways: Bool { suggestions != nil && !isQuestion }

    init(summary: String, tool: String = "", input: Data = Data("{}".utf8), suggestions: Data? = nil,
         questions: [Question] = []) {
        self.summary = summary
        self.tool = tool
        self.input = input
        self.suggestions = suggestions
        self.questions = questions
    }

    init(object: [String: Any]) {
        let tool = object["tool_name"] as? String ?? ""
        let input = object["tool_input"] as? [String: Any] ?? [:]
        self.tool = tool
        self.input = (try? JSONSerialization.data(withJSONObject: input, options: .sortedKeys)) ?? Data("{}".utf8)
        if let suggestions = object["permission_suggestions"] as? [Any], !suggestions.isEmpty {
            self.suggestions = try? JSONSerialization.data(withJSONObject: suggestions)
        }
        questions = tool == "AskUserQuestion" ? Question.parse(input["questions"]) : []
        summary = questions.isEmpty
            ? (tool.isEmpty ? "Use a tool" : ToolDescription.describe(tool: tool, input: input, style: .asking))
            : questions.count == 1 ? questions[0].text : "\(questions.count) questions"
    }
}

/// One of Claude's multiple-choice questions.
struct Question: Equatable, Sendable, Identifiable {
    struct Option: Equatable, Sendable, Identifiable {
        var label: String
        var detail: String?
        var id: String { label }
    }

    var text: String
    var header: String?
    var options: [Option]
    var multiSelect: Bool
    var id: String { text }

    static func parse(_ value: Any?) -> [Question] {
        (value as? [[String: Any]] ?? []).compactMap { question in
            guard let text = question["question"] as? String else { return nil }
            let options = (question["options"] as? [[String: Any]] ?? []).compactMap { option in
                (option["label"] as? String).map { Option(label: $0, detail: option["description"] as? String) }
            }
            guard !options.isEmpty else { return nil }
            return Question(text: text, header: question["header"] as? String, options: options,
                            multiSelect: question["multiSelect"] as? Bool ?? false)
        }
    }
}

/// One Claude Code hook event, as posted by the hook command. Only the fields the notch cares about.
struct HookEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case sessionStart, sessionEnd
        /// The user sent a prompt.
        case prompt
        case toolStart(name: String, summary: String)
        case toolEnd
        case needs(Need)
        /// Claude is about to ask permission (or ask the user a question); the notch may answer it.
        case permissionRequest(PermissionRequest)
        /// Finished its turn: the user's go.
        case stop
        case subagentStart(id: String)
        case subagentStop(id: String)
        case other

        /// Shorthand for tests and demos.
        static func permissionRequest(summary: String) -> Kind { .permissionRequest(PermissionRequest(summary: summary)) }
    }

    var sessionID: String
    var kind: Kind
    /// The session's working folder; the card shows its last component.
    var cwd: String?
    /// The Claude process, from the hook's parent PID, so dead terminals can be noticed.
    var pid: Int32?
    /// The session's JSONL transcript, read for token usage.
    var transcriptPath: String?
    /// Pairs a tool's start with its end, for durations.
    var toolUseID: String?
    /// For a finished tool call: what it was and what it changed.
    var step: Step?
    /// For `Stop`: Claude's last message, for the review card.
    var lastMessage: String?
    /// Which agent sent it (Codex hooks tag their posts).
    var agent: AgentKind = .claude

    init(sessionID: String, kind: Kind, cwd: String? = nil, pid: Int32? = nil, transcriptPath: String? = nil) {
        self.sessionID = sessionID
        self.kind = kind
        self.cwd = cwd
        self.pid = pid
        self.transcriptPath = transcriptPath
    }

    /// Parses the JSON Claude Code writes to a hook's stdin. Nil when it isn't one.
    init?(json: Data, pid: Int32? = nil, agent: AgentKind = .claude) {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let sessionID = object["session_id"] as? String, !sessionID.isEmpty,
              let name = object["hook_event_name"] as? String
        else { return nil }
        self.sessionID = sessionID
        self.cwd = object["cwd"] as? String
        self.pid = pid
        self.agent = agent
        self.transcriptPath = object["transcript_path"] as? String
        self.toolUseID = object["tool_use_id"] as? String
        let tool = object["tool_name"] as? String
        let input = object["tool_input"] as? [String: Any]
        switch name {
        case "SessionStart": kind = .sessionStart
        case "SessionEnd": kind = .sessionEnd
        case "UserPromptSubmit": kind = .prompt
        case "PreToolUse":
            kind = tool.map { .toolStart(name: $0, summary: ToolDescription.describe(tool: $0, input: input)) } ?? .other
        case "PostToolUse", "PostToolUseFailure":
            kind = .toolEnd
            if let tool {
                let failed = name == "PostToolUseFailure"
                let command = input?["command"] as? String ?? ""
                step = Step(tool: tool, summary: ToolDescription.describe(tool: tool, input: input), at: Date(),
                            failed: failed, change: failed ? nil : FileChange.from(tool: tool, input: input ?? [:]),
                            isTest: tool == "Bash" && TestRun.isTest(command: command))
            }
        case "PermissionRequest":
            kind = .permissionRequest(PermissionRequest(object: object))
        case "Stop":
            kind = .stop
            lastMessage = (object["last_assistant_message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        case "SubagentStart": kind = (object["agent_id"] as? String).map { .subagentStart(id: $0) } ?? .other
        case "SubagentStop": kind = (object["agent_id"] as? String).map { .subagentStop(id: $0) } ?? .other
        case "Notification":
            kind = Self.need(notificationType: object["notification_type"] as? String,
                             message: object["message"] as? String).map { .needs($0) } ?? .other
        default: kind = .other
        }
    }

    static func need(notificationType: String?, message: String?) -> Need? {
        switch notificationType {
        case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog": .permission
        case "idle_prompt", "agent_needs_input": .yourTurn
        case nil: message?.localizedCaseInsensitiveContains("permission") == true ? .permission : .yourTurn
        default: nil
        }
    }
}
