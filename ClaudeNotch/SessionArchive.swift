import Foundation

/// What's worth keeping about a session across restarts: its story (timeline), the turn under review, and the
/// tools it's trusted with. Live state (needs, prompts, processes) comes back from hooks and the registry.
struct SessionRecord: Codable, Equatable {
    var id: String
    var project: String
    var title: String?
    var cwd: String?
    var startedAt: Date
    var timeline: [Step]
    var turnChanges: [FileChange]
    var testsPassed: Bool?
    var lastMessage: String?
    var trusted: [String]
    var savedAt: Date

    @MainActor init(_ agent: Agent, now: Date = Date()) {
        id = agent.id
        project = agent.project
        title = agent.title
        cwd = agent.cwd
        startedAt = agent.startedAt
        timeline = agent.timeline
        turnChanges = agent.turnChanges
        testsPassed = agent.testsPassed
        lastMessage = agent.lastMessage
        trusted = agent.trusted.sorted()
        savedAt = now
    }

    /// Fills in what a freshly seen session doesn't know yet.
    func restore(into agent: inout Agent) {
        if agent.title == nil { agent.title = title }
        if agent.cwd == nil { agent.cwd = cwd }
        agent.startedAt = min(agent.startedAt, startedAt)
        if agent.timeline.isEmpty { agent.timeline = timeline }
        if agent.turnChanges.isEmpty { agent.turnChanges = turnChanges }
        if agent.testsPassed == nil { agent.testsPassed = testsPassed }
        if agent.lastMessage == nil { agent.lastMessage = lastMessage }
        agent.trusted.formUnion(trusted)
    }

    /// Same content, ignoring when it was saved.
    func sameContent(as other: SessionRecord) -> Bool {
        var a = self, b = other
        a.savedAt = .distantPast
        b.savedAt = .distantPast
        return a == b
    }
}

/// One small JSON file per session in Application Support. Written only when something changed; files for sessions
/// unseen for two weeks are cleared out.
@MainActor
final class SessionArchive {
    static let keepFor: TimeInterval = 14 * 24 * 3600
    let folder: URL
    private var records: [String: SessionRecord] = [:]

    init(folder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude Notch/sessions")) {
        self.folder = folder
    }

    /// Reads what's on disk and drops anything too old.
    func load(now: Date = Date()) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let record = try? decoder.decode(SessionRecord.self, from: data)
            else { continue }
            if now.timeIntervalSince(record.savedAt) > Self.keepFor {
                try? FileManager.default.removeItem(at: file)
            } else {
                records[record.id] = record
            }
        }
    }

    func record(for id: String) -> SessionRecord? { records[id] }

    /// Writes the sessions whose saved copy is out of date.
    func save(_ agents: [Agent], now: Date = Date()) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var changed: [(URL, Data)] = []
        for agent in agents where !agent.isDemo && (!agent.timeline.isEmpty || !agent.trusted.isEmpty || agent.lastMessage != nil) {
            let record = SessionRecord(agent, now: now)
            if let saved = records[agent.id], saved.sameContent(as: record) { continue }
            records[agent.id] = record
            guard let data = try? encoder.encode(record) else { continue }
            changed.append((file(for: agent.id), data))
        }
        guard !changed.isEmpty else { return }
        let folder = folder
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (url, data) in changed { try? data.write(to: url, options: .atomic) }
        }
    }

    private func file(for id: String) -> URL {
        let safe = id.replacingOccurrences(of: "/", with: "_")
        return folder.appendingPathComponent("\(safe).json")
    }
}
