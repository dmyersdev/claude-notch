import Foundation

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

/// One Claude Code hook event, as posted by the hook command. Only the fields the notch cares about.
struct HookEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case sessionStart, sessionEnd
        /// The user sent a prompt.
        case prompt
        case toolStart(name: String, summary: String)
        case toolEnd
        case needs(Need)
        /// Claude is about to ask permission; the notch may answer it. `summary` describes the tool call.
        case permissionRequest(summary: String)
        /// Finished its turn: the user's go.
        case stop
        case subagentStart(id: String)
        case subagentStop(id: String)
        case other
    }

    var sessionID: String
    var kind: Kind
    /// The session's working folder; the card shows its last component.
    var cwd: String?
    /// The Claude process, from the hook's parent PID, so dead terminals can be noticed.
    var pid: Int32?
    /// The session's JSONL transcript, read for token usage.
    var transcriptPath: String?

    init(sessionID: String, kind: Kind, cwd: String? = nil, pid: Int32? = nil, transcriptPath: String? = nil) {
        self.sessionID = sessionID
        self.kind = kind
        self.cwd = cwd
        self.pid = pid
        self.transcriptPath = transcriptPath
    }

    /// Parses the JSON Claude Code writes to a hook's stdin. Nil when it isn't one.
    init?(json: Data, pid: Int32? = nil) {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let sessionID = object["session_id"] as? String, !sessionID.isEmpty,
              let name = object["hook_event_name"] as? String
        else { return nil }
        self.sessionID = sessionID
        self.cwd = object["cwd"] as? String
        self.pid = pid
        self.transcriptPath = object["transcript_path"] as? String
        let tool = object["tool_name"] as? String
        let input = object["tool_input"] as? [String: Any]
        switch name {
        case "SessionStart": kind = .sessionStart
        case "SessionEnd": kind = .sessionEnd
        case "UserPromptSubmit": kind = .prompt
        case "PreToolUse":
            kind = tool.map { .toolStart(name: $0, summary: ToolDescription.describe(tool: $0, input: input)) } ?? .other
        case "PostToolUse", "PostToolUseFailure": kind = .toolEnd
        case "PermissionRequest":
            kind = .permissionRequest(summary: tool.map { ToolDescription.describe(tool: $0, input: input, style: .asking) }
                                      ?? "Use a tool")
        case "Stop": kind = .stop
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
