import AppKit

/// Terminal setups that stop "jump to session" from reaching the exact tab, found up front rather than discovered
/// by a jump that quietly does nothing.
struct TerminalFinding: Identifiable, Equatable {
    enum Severity { case fix, info }
    var id: String { app + problem }
    var app: String
    var problem: String
    var fix: String
    var severity: Severity
    /// A file to open to make the fix.
    var file: URL?
}

enum TerminalChecks {
    static func run(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                    installed: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [TerminalFinding] {
        var findings: [TerminalFinding] = []
        if installed("/Applications/kitty.app") {
            let conf = home.appendingPathComponent(".config/kitty/kitty.conf")
            let text = (try? String(contentsOf: conf, encoding: .utf8)) ?? ""
            let missing = kittyMissing(text)
            if !missing.isEmpty {
                findings.append(TerminalFinding(
                    app: "kitty", problem: "Remote control is off, so jumps only bring kitty forward.",
                    fix: "Add to kitty.conf, then restart kitty:\n" + missing.joined(separator: "\n"),
                    severity: .fix, file: conf))
            }
        }
        if let version = appVersion("/Applications/Ghostty.app"), !ghosttyMatchesTabs(version) {
            findings.append(TerminalFinding(
                app: "Ghostty", problem: "Ghostty \(version) can't be asked for a tab by terminal.",
                fix: "Update Ghostty past 1.3.1 to jump to the exact tab.", severity: .fix))
        }
        for (app, path) in [("Warp", "/Applications/Warp.app"), ("Alacritty", "/Applications/Alacritty.app")] where installed(path) {
            findings.append(TerminalFinding(app: app, problem: "\(app) can't be asked for a particular tab.",
                                            fix: "Jumps bring \(app) to the front; pick the tab yourself.", severity: .info))
        }
        return findings
    }

    /// The kitty.conf lines that are missing for remote control.
    static func kittyMissing(_ conf: String) -> [String] {
        let lines = conf.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.hasPrefix("#") }
        var missing: [String] = []
        let remote = lines.contains { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            return parts.first == "allow_remote_control" && parts.count > 1 && ["yes", "socket", "socket-only"].contains(String(parts[1]))
        }
        if !remote { missing.append("allow_remote_control yes") }
        if !lines.contains(where: { $0.hasPrefix("listen_on") && $0.contains("unix:") }) {
            missing.append("listen_on unix:/tmp/kitty")
        }
        return missing
    }

    /// Ghostty matches tabs by TTY in builds newer than 1.3.1.
    static func ghosttyMatchesTabs(_ version: String) -> Bool {
        let parts = version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let version = Array((parts + [0, 0, 0]).prefix(3))
        return [1, 3, 1].lexicographicallyPrecedes(version)
    }

    static func appVersion(_ path: String) -> String? {
        Bundle(path: path)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}
