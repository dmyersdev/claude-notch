import Foundation
import Testing
@testable import ClaudeNotch

/// Several Claude config folders (`CLAUDE_CONFIG_DIR`): sessions, transcripts and hooks follow each one.
struct ConfigFolderTests {
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = FileManager.default
        for folder in [".claude-personal/sessions", ".claude-personal/projects", ".claude-work",
                       ".claude-empty", ".claude-somethingelse"] {
            try manager.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data("{}".utf8).write(to: home.appendingPathComponent(".claude-work/settings.json"))
        // Not folders, or not Claude's: left alone.
        try Data("{}".utf8).write(to: home.appendingPathComponent(".claude.json"))
        try Data("x".utf8).write(to: home.appendingPathComponent(".claude-notes"))
    }

    @Test func findsEveryConfigFolder() {
        let names = ClaudeConfig.folders(home: home, environment: [:]).map(\.lastPathComponent)
        #expect(names == [".claude", ".claude-personal", ".claude-work"])
    }

    @Test func includesTheAppsOwnConfigDirOnce() {
        let elsewhere = home.appendingPathComponent("elsewhere").path
        let folders = ClaudeConfig.folders(home: home, environment: ["CLAUDE_CONFIG_DIR": elsewhere])
        #expect(folders.map(\.path).contains(elsewhere))
        let again = ClaudeConfig.folders(home: home, environment: ["CLAUDE_CONFIG_DIR": home.appendingPathComponent(".claude-work").path])
        #expect(again.filter { $0.lastPathComponent == ".claude-work" }.count == 1)
    }

    @Test func sessionsCarryTheirConfigFolder() throws {
        let sessions = home.appendingPathComponent(".claude-personal/sessions")
        try Data(#"{"pid":7,"sessionId":"abc","cwd":"/Users/me/app"}"#.utf8).write(to: sessions.appendingPathComponent("7.json"))
        let folders = SessionRegistry.folders(home: home, configFolders: ClaudeConfig.folders(home: home, environment: [:]))
        #expect(folders.contains(sessions))
        let session = try #require(SessionRegistry.running(in: folders, isAlive: { _ in true }).first)
        #expect(session.configFolder?.lastPathComponent == ".claude-personal")
        #expect(session.transcriptPath(home: home)
                == home.appendingPathComponent(".claude-personal/projects/-Users-me-app/abc.jsonl").path)
    }

    @Test func hooksGoIntoEveryFolder() throws {
        let urls = HookInstaller.claudeSettingsURLs(folders: ClaudeConfig.folders(home: home, environment: [:]))
        #expect(HookInstaller.status(urls: urls).installed == false)
        try HookInstaller.setAll(installed: true, urls: urls)
        #expect(HookInstaller.status(urls: urls) == (installed: true, partly: false))
        // A folder that loses its hooks makes the whole thing partly installed.
        try HookInstaller.uninstall(at: urls[1])
        #expect(HookInstaller.status(urls: urls) == (installed: false, partly: true))
        try HookInstaller.setAll(installed: false, urls: urls)
        #expect(urls.allSatisfy { !HookInstaller.hasAny(in: (try? HookInstaller.read($0)) ?? [:]) })
    }
}
