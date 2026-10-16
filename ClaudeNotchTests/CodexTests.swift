import Foundation
import Testing
@testable import ClaudeNotch

struct CodexInstallerTests {
    let existing: [String: Any] = [
        "description": "mine",
        "hooks": ["SessionStart": [["matcher": "^startup$", "hooks": [["type": "command", "command": "python3 mine.py"]]]]],
    ]

    @Test func installsCodexEventsAfterExistingHooks() {
        let settings = HookInstaller.installing(into: existing, kind: .codex)
        #expect(HookInstaller.isInstalled(in: settings, kind: .codex))
        #expect(!HookInstaller.isInstalled(in: settings, kind: .claude))
        #expect(settings["description"] as? String == "mine")
        let hooks = settings["hooks"] as? [String: Any]
        #expect(hooks?["Notification"] == nil)
        // Theirs keeps position 0, so Codex's trust record for it still matches.
        let start = hooks?["SessionStart"] as? [[String: Any]]
        #expect(((start?[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String) == "python3 mine.py")
        #expect(start?.count == 2)
        let end = (hooks?["SessionEnd"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]]
        #expect(end?.first?["timeout"] as? Int == 3)
        #expect((end?.first?["command"] as? String)?.contains("X-Agent: codex") == true)
    }

    @Test func removingLeavesTheirsAlone() {
        let removed = HookInstaller.removing(from: HookInstaller.installing(into: existing, kind: .codex))
        let hooks = removed["hooks"] as? [String: Any]
        #expect(hooks?.keys.sorted() == ["SessionStart"])
    }

    @Test func claudeCommandsAreUnchanged() {
        #expect(!HookInstaller.command(for: "Stop").contains("X-Agent"))
    }
}

struct CodexEventTests {
    @Test func taggedPostsAreCodex() {
        let raw = "POST /event HTTP/1.1\r\nX-Agent: codex\r\nContent-Length: 2\r\n\r\n{}"
        #expect(HookServer.parse(Data(raw.utf8))?.agent == .codex)
        let plain = "POST /event HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}"
        #expect(HookServer.parse(Data(plain.utf8))?.agent == .claude)
    }

    @MainActor @Test func codexSessionsAreMarked() {
        let store = AgentStore()
        var event = HookEvent(sessionID: "c1", kind: .sessionStart, cwd: "/x/linux")
        event.agent = .codex
        store.apply(event)
        #expect(store.agents[0].kind == .codex)
        #expect(Format.meta(project: "linux", usage: SessionUsage(costUSD: 3), kind: .codex) == "Codex · linux · $3.00")
    }

    @Test func codexTranscriptsGiveContextButNoPrice() {
        let line = #"{"timestamp":"2026-10-16T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":90000},"last_token_usage":{"input_tokens":47000,"output_tokens":500,"total_tokens":47500},"model_context_window":475000}}}"#
        var usage = SessionUsage(), seen = Set<String>()
        UsageReader.apply(Data((line + "\n").utf8), to: &usage, seen: &seen)
        #expect(usage.contextTokens == 47500)
        #expect(usage.contextWindow == 475_000)
        #expect(abs(usage.contextFraction - 0.1) < 0.001)
        #expect(!usage.priced)
        #expect(Format.meta(project: nil, usage: usage, kind: .codex) == "Codex")
    }
}
