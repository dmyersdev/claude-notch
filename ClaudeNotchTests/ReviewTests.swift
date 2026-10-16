import Foundation
import Testing
@testable import ClaudeNotch

struct FileChangeTests {
    @Test func editsCountOnlyTheLinesThatDiffer() {
        let change = FileChange.from(tool: "Edit", input: [
            "file_path": "/x/Stage.swift",
            "old_string": "let a = 1\nlet b = 2\nlet c = 3",
            "new_string": "let a = 1\nlet b = 20\nlet b2 = 21\nlet c = 3",
        ])
        #expect(change?.name == "Stage.swift")
        #expect(change?.removed == 1)
        #expect(change?.added == 2)
        #expect(change?.hunks.first?.removed == ["let b = 2"])
    }

    @Test func multiEditsAndWritesAddUp() {
        let multi = FileChange.from(tool: "MultiEdit", input: [
            "file_path": "/x/a.swift",
            "edits": [["old_string": "a", "new_string": "b"], ["old_string": "c", "new_string": "d\ne"]],
        ])
        #expect(multi?.added == 3 && multi?.removed == 2 && multi?.hunks.count == 2)
        let write = FileChange.from(tool: "Write", input: ["file_path": "/x/new.md", "content": "one\ntwo\nthree"])
        #expect(write?.added == 3 && write?.removed == 0)
        #expect(FileChange.from(tool: "Read", input: ["file_path": "/x/a.swift"]) == nil)
    }

    @Test func mergingKeepsTheTotals() {
        var change = FileChange(path: "/x/a", added: 2, removed: 1)
        change.merge(FileChange(path: "/x/a", added: 3, removed: 4))
        #expect(change.added == 5 && change.removed == 5)
    }

    @Test func spotsTestRuns() {
        #expect(TestRun.isTest(command: "xcodebuild test -scheme X"))
        #expect(TestRun.isTest(command: "npm test"))
        #expect(TestRun.isTest(command: "pnpm run test -- --watch=false"))
        #expect(TestRun.isTest(command: "cd api && pytest -q"))
        #expect(TestRun.isTest(command: "go test ./..."))
        #expect(!TestRun.isTest(command: "npm run build"))
        #expect(!TestRun.isTest(command: "cat test.txt"))
    }
}

struct ReviewEventTests {
    func event(_ fields: [String: Any]) -> HookEvent? {
        HookEvent(json: try! JSONSerialization.data(withJSONObject: fields))
    }

    @Test func finishedToolsCarryTheirStep() {
        let edit = event(["session_id": "s", "hook_event_name": "PostToolUse", "tool_name": "Edit", "tool_use_id": "t1",
                          "tool_input": ["file_path": "/x/a.swift", "old_string": "a", "new_string": "b"]])
        #expect(edit?.step?.summary == "Editing a.swift")
        #expect(edit?.step?.change?.added == 1)
        #expect(edit?.toolUseID == "t1")
        let failedTest = event(["session_id": "s", "hook_event_name": "PostToolUseFailure", "tool_name": "Bash",
                                "tool_input": ["command": "npm test"]])
        #expect(failedTest?.step?.failed == true)
        #expect(failedTest?.step?.isTest == true)
    }

    @Test func stopCarriesClaudesLastMessage() {
        let stop = event(["session_id": "s", "hook_event_name": "Stop", "last_assistant_message": "  All done.\n"])
        #expect(stop?.lastMessage == "All done.")
    }
}

@MainActor struct ReviewStoreTests {
    let start = Date(timeIntervalSinceReferenceDate: 50_000)

    func step(_ tool: String, failed: Bool = false, change: FileChange? = nil, test: Bool = false) -> Step {
        Step(tool: tool, summary: tool, at: start, failed: failed, change: change, isTest: test)
    }

    @Test func aTurnCollectsItsChangesAndTestResult() {
        let store = AgentStore()
        store.apply(HookEvent(sessionID: "s", kind: .prompt), now: start)
        var started = HookEvent(sessionID: "s", kind: .toolStart(name: "Edit", summary: "Editing a"))
        started.toolUseID = "e1"
        store.apply(started, now: start)
        var edit = HookEvent(sessionID: "s", kind: .toolEnd)
        edit.toolUseID = "e1"
        edit.step = step("Edit", change: FileChange(path: "/x/a.swift", added: 3, removed: 1))
        store.apply(edit, now: start.addingTimeInterval(2))
        var again = HookEvent(sessionID: "s", kind: .toolEnd)
        again.step = step("Edit", change: FileChange(path: "/x/a.swift", added: 1, removed: 0))
        store.apply(again, now: start.addingTimeInterval(3))
        var tests = HookEvent(sessionID: "s", kind: .toolEnd)
        tests.step = step("Bash", failed: true, test: true)
        store.apply(tests, now: start.addingTimeInterval(4))
        var stop = HookEvent(sessionID: "s", kind: .stop)
        stop.lastMessage = "Done, but one test fails."
        store.apply(stop, now: start.addingTimeInterval(5))

        let agent = store.agents[0]
        #expect(agent.turnChanges.count == 1)
        #expect(agent.turnChanges[0].added == 4)
        #expect(agent.testsPassed == false)
        #expect(agent.timeline.count == 3)
        #expect(agent.timeline[0].duration == 2)
        #expect(agent.lastMessage == "Done, but one test fails.")
        #expect(agent.hasReview)
        #expect(PanelLayout.rowHeight(for: agent) == NotchMetrics.reviewRowHeight)

        store.apply(HookEvent(sessionID: "s", kind: .prompt), now: start.addingTimeInterval(60))
        #expect(store.agents[0].turnChanges.isEmpty && store.agents[0].testsPassed == nil)
        #expect(store.agents[0].timeline.count == 3)
    }

    @Test func theTimelineStaysBounded() {
        let store = AgentStore()
        for index in 0..<(Agent.timelineLimit + 25) {
            var end = HookEvent(sessionID: "s", kind: .toolEnd)
            end.step = step("Read \(index)")
            store.apply(end, now: start)
        }
        #expect(store.agents[0].timeline.count == Agent.timelineLimit)
        #expect(store.agents[0].timeline.last?.tool == "Read \(Agent.timelineLimit + 24)")
    }
}

struct GitInfoTests {
    @Test func remotesBecomeWebPages() {
        #expect(GitInfo.webURL(fromRemote: "git@github.com:dmyersdev/claude-notch.git")?.absoluteString
                == "https://github.com/dmyersdev/claude-notch")
        #expect(GitInfo.webURL(fromRemote: "https://github.com/dmyersdev/claude-notch.git")?.absoluteString
                == "https://github.com/dmyersdev/claude-notch")
        #expect(GitInfo.webURL(fromRemote: "https://token@github.com/o/r")?.absoluteString == "https://github.com/o/r")
        #expect(GitInfo.webURL(fromRemote: "/local/path") == nil)
    }

    @Test func pullRequestsAreForFeatureBranches() {
        let remote = "git@github.com:o/r.git"
        #expect(GitInfo.compareURL(remote: remote, branch: "claude/fix-tests", defaultBranch: "main")?.absoluteString
                == "https://github.com/o/r/compare/claude/fix-tests?expand=1")
        #expect(GitInfo.compareURL(remote: remote, branch: "main", defaultBranch: "main") == nil)
    }
}
