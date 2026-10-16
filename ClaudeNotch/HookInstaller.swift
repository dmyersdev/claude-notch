import Foundation

/// Adds (or removes) the notch's hooks in an agent's user settings, leaving everything else alone: Claude Code's
/// `~/.claude/settings.json`, or Codex's `~/.codex/hooks.json` (same shape; Codex asks you to approve new hooks
/// with `/hooks` before it runs them).
enum HookInstaller {
    static let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                         "PostToolUseFailure", "Notification", "Stop", "SubagentStart", "SubagentStop",
                         "PermissionRequest"]
    /// Codex has no Notification or PostToolUseFailure events.
    static let codexEvents = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                              "Stop", "SubagentStart", "SubagentStop", "PermissionRequest"]
    /// Events whose matcher filters tool names; "*" catches every tool.
    static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest"]

    static func events(for kind: AgentKind) -> [String] { kind == .codex ? codexEvents : events }

    static let base = "http://127.0.0.1:\(HookServer.port)/"
    /// Posts the event JSON from stdin. Never blocks Claude for long, never prints, never fails.
    static let command = "curl -s -m 1 -o /dev/null -H 'Content-Type: application/json' "
        + "-H \"X-Claude-PID: $PPID\" --data-binary @- \(base)event || true"
    /// Waits briefly for an answer from the notch and prints it. Prints nothing (so Claude asks as usual)
    /// if the app isn't running, the user doesn't answer in time, or anything goes wrong.
    static let permissionCommand = "curl -s -m \(Int(HookServer.questionHoldSeconds) + 5) "
        + "-H 'Content-Type: application/json' -H \"X-Claude-PID: $PPID\" --data-binary @- \(base)permission || true"

    static func command(for event: String, kind: AgentKind = .claude) -> String {
        let command = event == "PermissionRequest" ? permissionCommand : command
        // Codex events are tagged so the notch knows which kind of agent sent them.
        return kind == .codex ? command.replacingOccurrences(of: "-H 'Content-Type", with: "-H 'X-Agent: codex' -H 'Content-Type") : command
    }

    static func timeout(for event: String, kind: AgentKind) -> Int {
        if event == "PermissionRequest" { return Int(HookServer.questionHoldSeconds) + 10 }
        // Codex caps SessionEnd hooks at 3 s.
        return kind == .codex && event == "SessionEnd" ? 3 : 5
    }

    static var settingsURL: URL { settingsURL(for: .claude) }

    static func settingsURL(for kind: AgentKind) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return kind == .codex ? home.appendingPathComponent(".codex/hooks.json")
                              : home.appendingPathComponent(".claude/settings.json")
    }

    /// Codex is set up on this Mac (its folder exists).
    static var codexAvailable: Bool {
        FileManager.default.fileExists(atPath: settingsURL(for: .codex).deletingLastPathComponent().path)
    }

    // MARK: Pure edits on the settings dictionary

    static func isOurs(_ group: Any) -> Bool {
        guard let hooks = (group as? [String: Any])?["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { ($0["command"] as? String)?.contains(base) == true }
    }

    /// All current hooks present. After an update adds events, the menu offers to install again.
    static func isInstalled(in settings: [String: Any], kind: AgentKind = .claude) -> Bool {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        return events(for: kind).allSatisfy { event in
            // Present, and the current command: an older one (shorter wait, say) counts as needing an update.
            (hooks[event] as? [[String: Any]])?.contains { group in
                isOurs(group)
                    && ((group["hooks"] as? [[String: Any]])?.first?["command"] as? String) == command(for: event, kind: kind)
            } == true
        }
    }

    static func hasAny(in settings: [String: Any]) -> Bool {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        return hooks.values.contains { ($0 as? [Any])?.contains(where: isOurs) == true }
    }

    /// Ours go after any hooks already there, so existing ones keep their place (Codex remembers which hooks
    /// you've approved by position).
    static func installing(into settings: [String: Any], kind: AgentKind = .claude) -> [String: Any] {
        var settings = removing(from: settings)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events(for: kind) {
            var group: [String: Any] = ["hooks": [["type": "command", "command": command(for: event, kind: kind),
                                                   "timeout": timeout(for: event, kind: kind)]]]
            if toolEvents.contains(event) { group["matcher"] = "*" }
            hooks[event] = (hooks[event] as? [Any] ?? []) + [group]
        }
        settings["hooks"] = hooks
        return settings
    }

    static func removing(from settings: [String: Any]) -> [String: Any] {
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        var settings = settings
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            let kept = groups.filter { !isOurs($0) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        return settings
    }

    // MARK: The settings file

    static func read(_ url: URL = settingsURL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        guard let settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return settings
    }

    /// Keeps a one-off copy of the user's file next to it before the first change.
    static func write(_ settings: [String: Any], to url: URL = settingsURL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = url.appendingPathExtension("claude-notch-backup")
        if manager.fileExists(atPath: url.path), !manager.fileExists(atPath: backup.path) {
            try manager.copyItem(at: url, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    static func install(at url: URL = settingsURL, kind: AgentKind = .claude) throws {
        try write(installing(into: read(url), kind: kind), to: url)
    }
    static func uninstall(at url: URL = settingsURL) throws { try write(removing(from: read(url)), to: url) }
}
