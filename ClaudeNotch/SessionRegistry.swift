import Foundation

/// Claude Code keeps a small file per running process in `<config folder>/sessions/<pid>.json`. Reading it finds
/// every session, including ones that started before the hooks were installed or haven't fired one since.
struct RegisteredSession: Equatable, Sendable {
    var pid: Int32
    var sessionID: String
    var cwd: String?
    /// The session's title, when it has one.
    var name: String?
    /// "busy" while working, "idle" when waiting for a prompt.
    var status: String?
    var statusSince: Date?
    var startedAt: Date?
    /// The Claude desktop app's own ID for the session, for jumping straight to it.
    var hostSessionID: String?
    /// The config folder the session runs from (`~/.claude`, or wherever `CLAUDE_CONFIG_DIR` points).
    var configFolder: URL?

    var isIdle: Bool { status == "idle" }

    init?(json: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let pid = (object["pid"] as? NSNumber)?.int32Value,
              let sessionID = object["sessionId"] as? String
        else { return nil }
        self.pid = pid
        self.sessionID = sessionID
        cwd = object["cwd"] as? String
        name = object["name"] as? String
        status = object["status"] as? String
        statusSince = (object["statusUpdatedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        startedAt = (object["startedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        hostSessionID = object["hostSessionId"] as? String
    }

    init(pid: Int32, sessionID: String, cwd: String? = nil, name: String? = nil, status: String? = nil,
         statusSince: Date? = nil, startedAt: Date? = nil, hostSessionID: String? = nil, configFolder: URL? = nil) {
        self.pid = pid
        self.sessionID = sessionID
        self.cwd = cwd
        self.name = name
        self.status = status
        self.statusSince = statusSince
        self.startedAt = startedAt
        self.hostSessionID = hostSessionID
        self.configFolder = configFolder
    }

    /// Where Claude Code writes this session's transcript: the folder path with every non-alphanumeric as "-".
    func transcriptPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        guard let cwd else { return nil }
        let folder = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let config = configFolder ?? home.appendingPathComponent(".claude")
        return config.appendingPathComponent("projects/\(folder)/\(sessionID).jsonl").path
    }
}

enum SessionRegistry {
    /// Registry folders: one per Claude config folder, plus any that Cowork keeps for itself.
    static func folders(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        configFolders: [URL]? = nil) -> [URL] {
        var folders = (configFolders ?? ClaudeConfig.folders(home: home)).map { $0.appendingPathComponent("sessions") }
        let agentMode = home.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")
        if let walker = FileManager.default.enumerator(at: agentMode, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in walker where url.lastPathComponent == "sessions" {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { folders.append(url) }
            }
        }
        return folders
    }

    /// The sessions whose process is still running.
    static func running(in folders: [URL] = folders(), isAlive: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM })
        -> [RegisteredSession] {
        folders.flatMap { folder -> [RegisteredSession] in
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            // Transcripts sit beside the registry in a config folder; Cowork's registries have none.
            let config = folder.deletingLastPathComponent()
            let hasProjects = FileManager.default.fileExists(atPath: config.appendingPathComponent("projects").path)
            return files.filter { $0.pathExtension == "json" }
                .compactMap { (try? Data(contentsOf: $0)).flatMap(RegisteredSession.init(json:)) }
                .filter { isAlive($0.pid) }
                .map { session in
                    var session = session
                    if hasProjects { session.configFolder = config }
                    return session
                }
        }
    }
}
