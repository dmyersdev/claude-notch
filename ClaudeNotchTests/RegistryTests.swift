import Foundation
import Testing
@testable import ClaudeNotch

struct RegistryTests {
    let sample = #"{"pid":27664,"sessionId":"fc46","cwd":"/Users/me/Projects/notch-claude","startedAt":1792102822862,"kind":"interactive","entrypoint":"claude-desktop","hostSessionId":"local_a7f5","name":"Claude collision detection","status":"busy","statusUpdatedAt":1792105815169}"#

    @Test func readsARegistryFile() throws {
        let session = try #require(RegisteredSession(json: Data(sample.utf8)))
        #expect(session.pid == 27664)
        #expect(session.sessionID == "fc46")
        #expect(session.name == "Claude collision detection")
        #expect(session.hostSessionID == "local_a7f5")
        #expect(!session.isIdle)
        #expect(session.statusSince == Date(timeIntervalSince1970: 1792105815.169))
    }

    @Test func findsTheTranscript() throws {
        let session = try #require(RegisteredSession(json: Data(sample.utf8)))
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(session.transcriptPath(home: home)
                == "/Users/me/.claude/projects/-Users-me-Projects-notch-claude/fc46.jsonl")
    }

    @Test func onlyRunningProcessesCount() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"pid":11,"sessionId":"alive"}"#.utf8).write(to: folder.appendingPathComponent("11.json"))
        try Data(#"{"pid":12,"sessionId":"gone"}"#.utf8).write(to: folder.appendingPathComponent("12.json"))
        try Data("key".utf8).write(to: folder.appendingPathComponent("11.abc.key"))
        let running = SessionRegistry.running(in: [folder], isAlive: { $0 == 11 })
        #expect(running.map(\.sessionID) == ["alive"])
    }
}

@MainActor struct RegistrySyncTests {
    @Test func silentSessionsShowUp() {
        let store = AgentStore()
        store.syncRegistry([RegisteredSession(pid: 1, sessionID: "s", cwd: "/x/react", name: "Proceed", status: "idle")])
        #expect(store.agents.map(\.project) == ["react"])
        #expect(store.agents[0].title == "Proceed")
        #expect(store.agents[0].isQuiet(at: Date()))
        #expect(store.agents[0].lastTool == "Waiting for a prompt")
    }

    @Test func registryAndHooksAreTheSameSession() {
        let store = AgentStore()
        store.apply(HookEvent(sessionID: "s", kind: .toolStart(name: "Read", summary: "Reading a.swift"), cwd: "/x/p"))
        store.syncRegistry([RegisteredSession(pid: 1, sessionID: "s", cwd: "/x/p", status: "busy", hostSessionID: "local_1")])
        #expect(store.agents.count == 1)
        #expect(store.agents[0].lastTool == "Reading a.swift")
        #expect(store.agents[0].hostSessionID == "local_1")
        #expect(!store.agents[0].isQuiet(at: Date()))
    }

    @Test func goingBusyWakesItUp() {
        let store = AgentStore()
        store.syncRegistry([RegisteredSession(pid: 1, sessionID: "s", status: "idle")])
        store.syncRegistry([RegisteredSession(pid: 1, sessionID: "s", status: "busy", statusSince: Date())])
        #expect(!store.agents[0].isQuiet(at: Date()))
        #expect(store.agents[0].lastTool == "Working")
    }
}
