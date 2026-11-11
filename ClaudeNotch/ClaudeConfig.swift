import Foundation

/// Claude Code's config folders. It's `~/.claude` unless `CLAUDE_CONFIG_DIR` points somewhere else, and people
/// who keep accounts apart run one folder per account (`~/.claude-work`, `~/.claude-personal`). The app starts
/// from Finder, so it rarely sees a variable a shell sets; it looks for the folders instead.
enum ClaudeConfig {
    /// `~/.claude` (always, so a fresh Mac still gets hooks there), the app's own `CLAUDE_CONFIG_DIR` if it has
    /// one, and every `~/.claude-*` folder Claude Code has used.
    static func folders(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        var folders = [home.appendingPathComponent(".claude")]
        if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            folders.append(URL(fileURLWithPath: (dir as NSString).expandingTildeInPath))
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        for name in names.sorted() where name.hasPrefix(".claude-") {
            let folder = home.appendingPathComponent(name)
            if isConfigFolder(folder) { folders.append(folder) }
        }
        var seen = Set<String>()
        return folders.filter { seen.insert($0.standardizedFileURL.resolvingSymlinksInPath().path).inserted }
    }

    /// A folder Claude Code has run from keeps its settings, running sessions or transcripts there.
    static func isConfigFolder(_ folder: URL) -> Bool {
        ["settings.json", "sessions", "projects"].contains {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    /// `~/.claude-personal` style, for showing to people.
    static func display(_ folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let path = folder.path
        return path.hasPrefix(home.path + "/") ? "~" + path.dropFirst(home.path.count) : path
    }
}
