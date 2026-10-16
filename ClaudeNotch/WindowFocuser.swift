import AppKit

/// Brings the window a Claude Code session runs in to the front, with keyboard focus.
/// Walks up from the Claude process to the app that owns it, then asks that app for the exact window
/// where it can: the session in Claude's desktop app, the tab in Terminal, iTerm or Ghostty, the pane in
/// WezTerm, kitty or tmux, the folder in an editor. Warp and Alacritty can only be brought forward.
enum WindowFocuser {
    enum Target: Equatable {
        case claudeDesktop
        case terminal, iTerm, ghostty, kitty, wezTerm
        /// Editors that focus the window already showing a folder when asked to open it.
        case editor
        case other
    }

    static func target(bundleID: String?) -> Target {
        switch bundleID {
        case "com.anthropic.claudefordesktop": .claudeDesktop
        case "com.apple.Terminal": .terminal
        case "com.googlecode.iterm2": .iTerm
        case "com.mitchellh.ghostty": .ghostty
        case "net.kovidgoyal.kitty": .kitty
        case "com.github.wez.wezterm": .wezTerm
        case "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mt0ff1jl",
             "com.exafunction.windsurf", "dev.zed.Zed": .editor
        default: .other
        }
    }

    @MainActor static func focus(_ agent: Agent) {
        guard let pid = agent.pid else { return }
        let tty = processInfo(pid)?.tty
        if let app = owningApp(of: pid) {
            focus(agent, in: app, tty: tty, sessionPID: pid)
            return
        }
        // No app above it: most likely tmux, whose server isn't a child of any terminal. Select the pane, then
        // raise the terminal showing that tmux session.
        guard let tty else { return }
        Task.detached {
            guard let pane = Tmux.pane(forTTY: tty), let client = Tmux.select(pane) else { return }
            await MainActor.run {
                if let app = owningApp(of: client.pid) {
                    focus(agent, in: app, tty: client.tty, sessionPID: client.pid)
                }
            }
        }
    }

    @MainActor private static func focus(_ agent: Agent, in app: NSRunningApplication, tty: String?, sessionPID pid: pid_t) {
        switch target(bundleID: app.bundleIdentifier) {
        case .claudeDesktop:
            if let local = agent.hostSessionID ?? desktopSessionID(cliSessionID: agent.id),
               let url = URL(string: "claude://code/continue?session=\(local)") {
                NSWorkspace.shared.open(url)
            } else {
                activate(app)
            }
        case .terminal:
            guard let tty else { return activate(app) }
            runAppleScript("""
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(tty)" then
                                set selected tab of w to t
                                set index of w to 1
                            end if
                        end repeat
                    end repeat
                    activate
                end tell
                """)
        case .iTerm:
            guard let tty else { return activate(app) }
            runAppleScript("""
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is "\(tty)" then
                                    select w
                                    select t
                                    select s
                                end if
                            end repeat
                        end repeat
                    end repeat
                    activate
                end tell
                """)
        case .ghostty:
            if let tty { runAppleScript(Ghostty.script(tty: tty)) } else { activate(app) }
        case .wezTerm:
            activate(app)
            if let tty { Task.detached { _ = WezTerm.focus(tty: tty) } }
        case .kitty:
            activate(app)
            // kitty matches the window by its direct child: the session's ancestor just below kitty itself.
            let chain = [pid] + ancestors(of: pid, parent: { processInfo($0)?.parent })
            if let index = chain.firstIndex(of: app.processIdentifier), index > 0 {
                let windowPID = chain[index - 1]
                Task.detached { _ = Kitty.focus(windowPID: windowPID) }
            }
        case .editor:
            guard let cwd = agent.cwd, let appURL = app.bundleURL else { return activate(app) }
            NSWorkspace.shared.open([URL(fileURLWithPath: cwd)], withApplicationAt: appURL,
                                    configuration: NSWorkspace.OpenConfiguration())
        case .other:
            activate(app)
        }
    }

    /// The nearest ancestor of `pid` that is a regular app with a Dock icon.
    @MainActor static func owningApp(of pid: pid_t) -> NSRunningApplication? {
        ancestors(of: pid, parent: { processInfo($0)?.parent }).lazy
            .compactMap { NSRunningApplication(processIdentifier: $0) }
            .first { $0.activationPolicy == .regular }
    }

    /// `pid`'s parent, grandparent and so on up to (not including) launchd.
    static func ancestors(of pid: pid_t, parent: (pid_t) -> pid_t?) -> [pid_t] {
        var chain: [pid_t] = []
        var current = pid
        while let next = parent(current), next > 1, !chain.contains(next), chain.count < 32 {
            chain.append(next)
            current = next
        }
        return chain
    }

    static func processInfo(_ pid: pid_t) -> (parent: pid_t, tty: String?)? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let device = info.kp_eproc.e_tdev
        var tty: String?
        if device != -1, let name = devname(device, S_IFCHR) {
            let text = String(cString: name)
            if text != "??" { tty = "/dev/" + text }
        }
        return (info.kp_eproc.e_ppid, tty)
    }

    /// Claude's desktop app keeps a record per session, named by its own ID, holding the CLI session ID.
    static func desktopSessionID(cliSessionID: String, in root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")) -> String? {
        let needle = Data("\"cliSessionId\":\"\(cliSessionID)\"".utf8)
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let file as URL in files where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
            // The IDs sit at the very start; the rest of the record can be megabytes.
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            let head = (try? handle.read(upToCount: 4096)) ?? nil
            try? handle.close()
            if let head, head.range(of: needle) != nil { return file.deletingPathExtension().lastPathComponent }
        }
        return nil
    }

    @MainActor private static func activate(_ app: NSRunningApplication) {
        guard let url = app.bundleURL else { app.activate(); return }
        // Opening through Launch Services hands over focus even though the notch never activates itself.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    private static func runAppleScript(_ source: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        try? process.run()
    }
}
