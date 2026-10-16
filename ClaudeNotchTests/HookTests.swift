import Foundation
import Testing
@testable import ClaudeNotch

struct HookEventTests {
    func event(_ fields: [String: Any]) -> HookEvent? {
        HookEvent(json: try! JSONSerialization.data(withJSONObject: fields), pid: 42)
    }

    @Test func parsesTheFieldsTheNotchUses() {
        let e = event(["session_id": "s1", "hook_event_name": "SessionStart", "cwd": "/Users/me/notch-claude"])
        #expect(e == HookEvent(sessionID: "s1", kind: .sessionStart, cwd: "/Users/me/notch-claude", pid: 42))
    }

    @Test func toolUseDescribesTheTool() {
        let e = event(["session_id": "s1", "hook_event_name": "PreToolUse", "tool_name": "Edit",
                       "tool_input": ["file_path": "/a/b/NotchView.swift", "old_string": "x"]])
        #expect(e?.kind == .toolStart(name: "Edit", summary: "Editing NotchView.swift"))
        #expect(ToolDescription.describe(tool: "Bash", input: ["command": "xcodebuild test\necho done"])
                == "Running xcodebuild test")
        #expect(ToolDescription.describe(tool: "Task", input: [:]) == "Delegating:")
        #expect(ToolDescription.describe(tool: "Agent", input: ["description": "Find the bug"]) == "Delegating: Find the bug")
        #expect(ToolDescription.describe(tool: "WebFetch", input: ["url": "https://docs.claude.com/x"]) == "Reading docs.claude.com")
        #expect(ToolDescription.describe(tool: "Grep", input: ["pattern": "hover"]) == "Searching for “hover”")
    }

    @Test func notificationTypesSayWhatKindOfWait() {
        func kind(_ type: String) -> HookEvent.Kind? {
            event(["session_id": "s", "hook_event_name": "Notification", "notification_type": type])?.kind
        }
        #expect(kind("permission_prompt") == .needs(.permission))
        #expect(kind("elicitation_dialog") == .needs(.permission))
        #expect(kind("idle_prompt") == .needs(.yourTurn))
        #expect(kind("auth_success") == .other)
        #expect(HookEvent.need(notificationType: nil, message: "Claude needs your permission to use Bash") == .permission)
    }

    @Test func stopsPermissionsAndSubagents() {
        #expect(event(["session_id": "s", "hook_event_name": "Stop"])?.kind == .stop)
        let permission = event(["session_id": "s", "hook_event_name": "PermissionRequest", "tool_name": "Bash",
                                "tool_input": ["command": "rm -rf build"]])
        guard case .permissionRequest(let request) = permission?.kind else { Issue.record("not a permission request"); return }
        #expect(request.summary == "Run rm -rf build")
        #expect(request.tool == "Bash")
        #expect(!request.isQuestion && !request.canAlways)
        #expect(event(["session_id": "s", "hook_event_name": "SubagentStart", "agent_id": "a1"])?.kind
                == .subagentStart(id: "a1"))
        #expect(event(["session_id": "s", "hook_event_name": "SubagentStop", "agent_id": "a1"])?.kind
                == .subagentStop(id: "a1"))
    }

    @Test func mcpToolsReadLikeWords() {
        #expect(ToolDescription.describe(tool: "mcp__ccd_turn__wrap_up", input: [:]) == "Claude app: wrap up")
        #expect(ToolDescription.describe(tool: "mcp__claude-in-chrome__navigate", input: [:]) == "Chrome: navigate")
        #expect(ToolDescription.describe(tool: "mcp__plugin_desktop-commander_desktop-commander__read_file", input: [:])
                == "Desktop commander: read file")
        #expect(ToolDescription.describe(tool: "mcp__1a59c906-04da-521d-bda7-7f71b9f9e01c__batch", input: [:]) == "Batch")
        #expect(ToolDescription.describe(tool: "mcp__github__createPullRequest", input: [:]) == "Github: create pull request")
        #expect(ToolDescription.describe(tool: "Bash", input: ["command": "rm -rf build"], style: .asking) == "Run rm -rf build")
    }

    @Test func toolsMapToActivities() {
        #expect(Activity.of(tool: "Edit") == .writing)
        #expect(Activity.of(tool: "Grep") == .reading)
        #expect(Activity.of(tool: "Bash") == .running)
        #expect(Activity.of(tool: "WebFetch") == .searching)
        #expect(Activity.of(tool: "mcp__x__y") == .other)
    }

    @Test func rejectsJunk() {
        #expect(HookEvent(json: Data("nope".utf8)) == nil)
        #expect(event(["hook_event_name": "Stop"]) == nil)
    }
}

@MainActor struct AgentStoreHookTests {
    @Test func sessionLifecycle() {
        let store = AgentStore()
        store.apply(HookEvent(sessionID: "s", kind: .sessionStart, cwd: "/x/freeCodeCamp", pid: 7))
        #expect(store.agents.map(\.project) == ["freeCodeCamp"])
        store.apply(HookEvent(sessionID: "s", kind: .needs(.permission)))
        #expect(store.anyNeedsAttention)
        store.apply(HookEvent(sessionID: "s", kind: .toolStart(name: "Read", summary: "Read · a.swift")))
        #expect(!store.anyNeedsAttention)
        #expect(store.agents[0].lastTool == "Read · a.swift")
        #expect(store.agents[0].activity == .reading)
        store.apply(HookEvent(sessionID: "s", kind: .stop))
        #expect(store.agents[0].need == .yourTurn)
        store.apply(HookEvent(sessionID: "s", kind: .sessionEnd))
        #expect(store.agents.isEmpty)
    }

    @Test func alreadyRunningSessionsAppearOnTheirNextEvent() {
        let store = AgentStore()
        store.apply(HookEvent(sessionID: "s", kind: .toolEnd, cwd: "/x/vscode"))
        #expect(store.agents.map(\.project) == ["vscode"])
    }

    @Test func deadProcessesAreRemoved() {
        let store = AgentStore()
        store.apply(HookEvent(sessionID: "alive", kind: .sessionStart, pid: 1))
        store.apply(HookEvent(sessionID: "dead", kind: .sessionStart, pid: 2))
        store.spawn()
        store.removeDeadSessions { $0 == 1 }
        #expect(store.agents.count == 2)
        #expect(!store.agents.contains { $0.id == "dead" })
        #expect(store.died == ["dead"])
    }

    @Test func waitingTimeStartsAtTheFirstNeed() {
        let store = AgentStore()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        store.apply(HookEvent(sessionID: "s", kind: .needs(.yourTurn)), now: start)
        store.apply(HookEvent(sessionID: "s", kind: .needs(.permission)), now: start.addingTimeInterval(30))
        #expect(store.agents[0].waitingSince == start)
        #expect(store.agents[0].need == .permission)
        store.apply(HookEvent(sessionID: "s", kind: .prompt), now: start.addingTimeInterval(40))
        #expect(store.agents[0].waitingSince == nil)
    }

    @Test func subagentsComeAndGo() {
        let store = AgentStore()
        store.apply(HookEvent(sessionID: "s", kind: .subagentStart(id: "a")))
        store.apply(HookEvent(sessionID: "s", kind: .subagentStart(id: "b")))
        store.apply(HookEvent(sessionID: "s", kind: .subagentStop(id: "a")))
        #expect(store.agents[0].subagents == ["b"])
        // A background sub-agent outlives the turn.
        store.apply(HookEvent(sessionID: "s", kind: .stop))
        #expect(store.agents[0].subagents == ["b"])
        store.apply(HookEvent(sessionID: "s", kind: .subagentStop(id: "b")))
        #expect(store.agents[0].subagents.isEmpty)
    }

    @Test func quietSessionsLookStuck() {
        let start = Date()
        let agent = Agent(id: "a", project: "p", lastEventAt: start)
        #expect(!agent.isQuiet(at: start.addingTimeInterval(60)))
        #expect(agent.isQuiet(at: start.addingTimeInterval(Agent.quietAfter + 1)))
    }

    @Test func longestWaitingPrefersPermissionPrompts() {
        let store = AgentStore()
        let start = Date()
        store.apply(HookEvent(sessionID: "old", kind: .stop), now: start)
        store.apply(HookEvent(sessionID: "blocked", kind: .needs(.permission)), now: start.addingTimeInterval(60))
        #expect(store.longestWaiting?.id == "blocked")
    }

    @Test func soundHookFiresOnceAWaitStarts() {
        let store = AgentStore()
        var heard: [Need] = []
        store.onNeed = { heard.append($0) }
        store.apply(HookEvent(sessionID: "s", kind: .needs(.permission)))
        store.apply(HookEvent(sessionID: "s", kind: .needs(.permission)))
        store.apply(HookEvent(sessionID: "s", kind: .stop))
        #expect(heard == [.permission, .yourTurn])
    }

    @Test func turningDemoOffKeepsRealSessions() {
        let store = AgentStore()
        store.apply(HookEvent(sessionID: "real", kind: .sessionStart))
        store.autoDemo = true
        store.autoDemo = false
        #expect(store.agents.map(\.id) == ["real"])
    }
}

@MainActor struct PermissionHoldTests {
    final class Replies: @unchecked Sendable { var got: [PermissionDecision?] = [] }
    let request = HookEvent(sessionID: "s", kind: .permissionRequest(summary: "Bash · ls"), cwd: "/x/p")

    @Test func answeringFromTheCard() {
        let store = AgentStore(), replies = Replies()
        store.hold(request) { replies.got.append($0) }
        #expect(store.agents[0].ask?.summary == "Bash · ls")
        #expect(store.agents[0].need == .permission)
        store.answer("s", .allow)
        #expect(replies.got == [.allow])
        #expect(store.agents[0].ask == nil)
        #expect(store.agents[0].need == nil)
    }

    @Test func clickingTheCardHandsThePromptBack() {
        let store = AgentStore(), replies = Replies()
        store.hold(request) { replies.got.append($0) }
        store.acknowledge("s")
        #expect(replies.got == [nil])
    }

    @Test func expiringKeepsTheFlagUp() {
        let store = AgentStore(), replies = Replies()
        let token = store.hold(request) { replies.got.append($0) }!
        store.expire(token)
        #expect(replies.got == [nil])
        #expect(store.agents[0].ask == nil)
        #expect(store.agents[0].need == .permission)
    }

    @Test func alwaysEarnsATrustSticker() {
        let store = AgentStore(), replies = Replies()
        let bash = HookEvent(sessionID: "s", kind: .permissionRequest(PermissionRequest(summary: "Run npm test", tool: "Bash")))
        store.hold(bash) { replies.got.append($0) }
        store.answer("s", .always)
        #expect(replies.got == [.always])
        #expect(store.agents[0].trusted == ["Bash"])
    }

    @Test func answeringAQuestionCheers() {
        let store = AgentStore(), replies = Replies()
        let question = HookEvent(sessionID: "s", kind: .permissionRequest(PermissionRequest(
            summary: "Which fruit?", tool: "AskUserQuestion",
            questions: [Question(text: "Which fruit?", options: [.init(label: "Cherry")], multiSelect: false)])))
        store.hold(question) { replies.got.append($0) }
        #expect(store.agents[0].isAsking)
        store.answer("s", .answer(["Which fruit?": ["Cherry"]]))
        #expect(replies.got == [.answer(["Which fruit?": ["Cherry"]])])
        #expect(store.agents[0].answeredAt != nil)
        #expect(!store.agents[0].isAsking)
    }

    @Test func theSessionMovingOnReleasesIt() {
        let store = AgentStore(), replies = Replies()
        store.hold(request) { replies.got.append($0) }
        store.apply(HookEvent(sessionID: "s", kind: .toolEnd))
        store.answer("s", .deny)
        #expect(replies.got == [nil])
    }
}

struct HookServerTests {
    func verdict(_ decision: PermissionDecision, _ request: PermissionRequest = PermissionRequest(summary: "x")) throws
        -> [String: Any] {
        let output = try JSONSerialization.jsonObject(with: HookServer.hookOutput(decision, for: request)) as? [String: Any]
        let specific = output?["hookSpecificOutput"] as? [String: Any]
        #expect(specific?["hookEventName"] as? String == "PermissionRequest")
        return specific?["decision"] as? [String: Any] ?? [:]
    }

    @Test func permissionOutputMatchesTheHookFormat() throws {
        #expect(try verdict(.allow)["behavior"] as? String == "allow")
        #expect(try verdict(.deny)["behavior"] as? String == "deny")
    }

    @Test func alwaysSendsBackClaudesSuggestedRule() throws {
        let object: [String: Any] = [
            "tool_name": "Bash", "tool_input": ["command": "npm test"],
            "permission_suggestions": [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "npm test"]],
                                        "behavior": "allow", "destination": "localSettings"]],
        ]
        let request = PermissionRequest(object: object)
        #expect(request.canAlways)
        let always = try verdict(.always, request)
        #expect(always["behavior"] as? String == "allow")
        let rules = always["updatedPermissions"] as? [[String: Any]]
        #expect(rules?.first?["destination"] as? String == "localSettings")
    }

    @Test func answersGoBackInTheToolsInput() throws {
        let object: [String: Any] = [
            "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [
                ["question": "Which fruit?", "header": "Fruit", "multiSelect": false,
                 "options": [["label": "Apple"], ["label": "Cherry"]]],
                ["question": "Toppings?", "multiSelect": true, "options": [["label": "Nuts"], ["label": "Cream"]]],
            ]],
        ]
        let request = PermissionRequest(object: object)
        #expect(request.isQuestion && !request.canAlways)
        #expect(request.questions.map(\.text) == ["Which fruit?", "Toppings?"])
        #expect(request.summary == "2 questions")
        let answered = try verdict(.answer(["Which fruit?": ["Cherry"], "Toppings?": ["Nuts", "Cream"]]), request)
        let input = answered["updatedInput"] as? [String: Any]
        let answers = input?["answers"] as? [String: Any]
        #expect(answers?["Which fruit?"] as? String == "Cherry")
        #expect(answers?["Toppings?"] as? [String] == ["Nuts", "Cream"])
        // The original questions go back too.
        #expect((input?["questions"] as? [Any])?.count == 2)
    }

    @Test func questionsGetLongerToAnswer() {
        let question = PermissionRequest(object: ["tool_name": "AskUserQuestion",
                                                  "tool_input": ["questions": [["question": "Q?", "options": [["label": "A"]]]]]])
        #expect(HookServer.holdSeconds(for: question) > HookServer.holdSeconds(for: PermissionRequest(summary: "x")))
    }

    @Test func waitsForTheWholeBody() {
        let head = "POST /event HTTP/1.1\r\nContent-Length: 4\r\nX-Claude-PID: 99\r\n\r\n"
        #expect(HookServer.parse(Data((head + "ab").utf8)) == nil)
        let request = HookServer.parse(Data((head + "abcd").utf8))
        #expect(request?.body == Data("abcd".utf8))
        #expect(request?.path == "/event")
        #expect(request?.pid == 99)
    }
}

struct HookInstallerTests {
    let theirs: [String: Any] = [
        "model": "opus",
        "hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]],
    ]

    @Test func installKeepsTheirSettingsAndHooks() {
        let settings = HookInstaller.installing(into: theirs)
        #expect(HookInstaller.isInstalled(in: settings))
        #expect(settings["model"] as? String == "opus")
        let stop = (settings["hooks"] as? [String: Any])?["Stop"] as? [Any]
        #expect(stop?.count == 2)
    }

    @Test func permissionRequestsGetTheWaitingCommand() {
        let hooks = HookInstaller.installing(into: [:])["hooks"] as? [String: Any]
        let group = (hooks?["PermissionRequest"] as? [[String: Any]])?.first
        let command = (group?["hooks"] as? [[String: Any]])?.first?["command"] as? String
        #expect(command?.contains("/permission") == true)
        #expect(command?.contains("-o /dev/null") == false)
        #expect(group?["matcher"] as? String == "*")
    }

    @Test func olderInstallsCountAsPartial() {
        var settings = HookInstaller.installing(into: [:])
        var hooks = settings["hooks"] as! [String: Any]
        hooks["SubagentStart"] = nil
        settings["hooks"] = hooks
        #expect(!HookInstaller.isInstalled(in: settings))
        #expect(HookInstaller.hasAny(in: settings))
    }

    @Test func installingTwiceAddsNothing() {
        let once = HookInstaller.installing(into: theirs)
        let twice = HookInstaller.installing(into: once)
        let stop = (twice["hooks"] as? [String: Any])?["Stop"] as? [Any]
        #expect(stop?.count == 2)
    }

    @Test func uninstallRestoresTheirHooks() {
        let removed = HookInstaller.removing(from: HookInstaller.installing(into: theirs))
        #expect(!HookInstaller.isInstalled(in: removed))
        let hooks = removed["hooks"] as? [String: Any]
        #expect(hooks?.keys.sorted() == ["Stop"])
    }

    @Test func roundTripsAFileWithABackup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: theirs).write(to: url)
        try HookInstaller.install(at: url)
        #expect(HookInstaller.isInstalled(in: try HookInstaller.read(url)))
        #expect(FileManager.default.fileExists(atPath: url.path + ".claude-notch-backup"))
        try HookInstaller.uninstall(at: url)
        #expect(!HookInstaller.isInstalled(in: try HookInstaller.read(url)))
    }
}

struct WindowFocuserTests {
    @Test func walksUpToLaunchd() {
        let parents: [pid_t: pid_t] = [500: 400, 400: 300, 300: 1]
        #expect(WindowFocuser.ancestors(of: 500, parent: { parents[$0] }) == [400, 300])
    }

    @Test func stopsOnALoop() {
        #expect(WindowFocuser.ancestors(of: 5, parent: { $0 == 5 ? 6 : 5 }) == [6, 5])
    }

    @Test func knowsTheAppsItCanTarget() {
        #expect(WindowFocuser.target(bundleID: "com.anthropic.claudefordesktop") == .claudeDesktop)
        #expect(WindowFocuser.target(bundleID: "com.googlecode.iterm2") == .iTerm)
        #expect(WindowFocuser.target(bundleID: "com.microsoft.VSCode") == .editor)
        #expect(WindowFocuser.target(bundleID: "com.example.unknown") == .other)
    }

    @Test func findsTheDesktopSessionForACLISession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("account/org")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"sessionId":"local_abc","cliSessionId":"cli-1","cwd":"/x"}"#.utf8)
            .write(to: folder.appendingPathComponent("local_abc.json"))
        try Data(#"{"sessionId":"local_def","cliSessionId":"cli-2"}"#.utf8)
            .write(to: folder.appendingPathComponent("local_def.json"))
        #expect(WindowFocuser.desktopSessionID(cliSessionID: "cli-2", in: root) == "local_def")
        #expect(WindowFocuser.desktopSessionID(cliSessionID: "cli-9", in: root) == nil)
    }

    @MainActor @Test func findsTheRealOwnerOfThisTestRun() {
        // The test host runs under Xcode or a shell; either way it must not crash and the answer is an app or nil.
        _ = WindowFocuser.owningApp(of: getpid())
        #expect(WindowFocuser.processInfo(getpid())?.parent == getppid())
    }
}
