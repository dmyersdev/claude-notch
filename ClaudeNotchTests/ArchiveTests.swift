import Foundation
import Testing
@testable import ClaudeNotch

@MainActor struct ArchiveTests {
    func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID().uuidString)") }

    func busyAgent() -> Agent {
        var agent = Agent(id: "s1", project: "react", title: "Center the div")
        agent.timeline = [Step(tool: "Edit", summary: "Editing a.swift", at: Date(timeIntervalSince1970: 100),
                               change: FileChange(path: "/x/a.swift", added: 3, removed: 1))]
        agent.turnChanges = [FileChange(path: "/x/a.swift", added: 3, removed: 1)]
        agent.testsPassed = true
        agent.lastMessage = "Done."
        agent.trusted = ["Bash"]
        return agent
    }

    @Test func historySurvivesARestart() async throws {
        let place = folder()
        let first = SessionArchive(folder: place)
        first.save([busyAgent()])
        // The write happens off the main thread; give it a moment.
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: place.appendingPathComponent("s1.json").path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let second = SessionArchive(folder: place)
        second.load()
        let store = AgentStore()
        store.archive = second
        store.apply(HookEvent(sessionID: "s1", kind: .sessionStart, cwd: "/x/react"))
        let restored = store.agents[0]
        #expect(restored.timeline.count == 1)
        #expect(restored.turnChanges.first?.added == 3)
        #expect(restored.testsPassed == true)
        #expect(restored.lastMessage == "Done.")
        #expect(restored.trusted == ["Bash"])
        #expect(restored.title == "Center the div")
    }

    @Test func liveStateWinsOverTheArchive() {
        var record = SessionRecord(busyAgent())
        record.title = "Old name"
        var agent = Agent(id: "s1", project: "react", title: "New name")
        agent.lastMessage = "Fresh."
        record.restore(into: &agent)
        #expect(agent.title == "New name")
        #expect(agent.lastMessage == "Fresh.")
        #expect(agent.timeline.count == 1)
    }

    @Test func oldRecordsAreClearedOut() throws {
        let place = folder()
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        var record = SessionRecord(busyAgent(), now: Date(timeIntervalSinceNow: -30 * 24 * 3600))
        record.id = "old"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: place.appendingPathComponent("old.json"))
        let archive = SessionArchive(folder: place)
        archive.load()
        #expect(archive.record(for: "old") == nil)
        #expect(!FileManager.default.fileExists(atPath: place.appendingPathComponent("old.json").path))
    }

    @Test func demoAndEmptySessionsAreNotSaved() {
        let archive = SessionArchive(folder: folder())
        var demo = busyAgent()
        demo.isDemo = true
        archive.save([demo, Agent(id: "empty", project: "p")])
        #expect(archive.record(for: "s1") == nil)
        #expect(archive.record(for: "empty") == nil)
    }
}
