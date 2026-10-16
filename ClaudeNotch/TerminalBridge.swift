import AppKit

/// Runs a command-line tool and returns its output, or nil when it isn't there or fails.
enum Shell {
    static func run(_ path: String, _ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The first of `candidates` that exists: apps don't inherit the user's shell PATH.
    static func find(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// tmux: a session inside tmux has the tmux server above it, not the terminal. Find its pane by TTY, select it,
/// then raise whichever terminal is showing that tmux session.
enum Tmux {
    struct Pane: Equatable { var tty: String; var id: String; var session: String }
    struct Client: Equatable { var tty: String; var pid: pid_t; var session: String }

    static var binary: String? { Shell.find(["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]) }

    static func parsePanes(_ text: String) -> [Pane] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            return parts.count == 3 ? Pane(tty: parts[0], id: parts[1], session: parts[2]) : nil
        }
    }

    static func parseClients(_ text: String) -> [Client] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count == 3, let pid = pid_t(parts[1]) else { return nil }
            return Client(tty: parts[0], pid: pid, session: parts[2])
        }
    }

    static func pane(forTTY tty: String) -> Pane? {
        guard let tmux = binary,
              let text = Shell.run(tmux, ["list-panes", "-a", "-F", "#{pane_tty} #{pane_id} #{session_name}"])
        else { return nil }
        return parsePanes(text).first { $0.tty == tty }
    }

    /// Switches tmux to the pane and returns the client (outer terminal) showing its session, if any.
    static func select(_ pane: Pane) -> Client? {
        guard let tmux = binary else { return nil }
        _ = Shell.run(tmux, ["select-window", "-t", pane.id])
        _ = Shell.run(tmux, ["select-pane", "-t", pane.id])
        let clients = Shell.run(tmux, ["list-clients", "-F", "#{client_tty} #{client_pid} #{client_session}"])
            .map(parseClients) ?? []
        return clients.first { $0.session == pane.session } ?? clients.first
    }
}

/// WezTerm: `wezterm cli list` reports each pane's TTY; `activate-pane` selects it.
enum WezTerm {
    static let binary = "/Applications/WezTerm.app/Contents/MacOS/wezterm"

    static func paneID(forTTY tty: String, in json: Data) -> Int? {
        let panes = (try? JSONSerialization.jsonObject(with: json)) as? [[String: Any]] ?? []
        return panes.first { $0["tty_name"] as? String == tty }?["pane_id"] as? Int
    }

    static func focus(tty: String) -> Bool {
        guard let list = Shell.run(binary, ["cli", "list", "--format", "json"]),
              let pane = paneID(forTTY: tty, in: Data(list.utf8)) else { return false }
        return Shell.run(binary, ["cli", "activate-pane", "--pane-id", String(pane)]) != nil
    }
}

/// kitty: remote control (needs `allow_remote_control` and `listen_on` in kitty.conf) can focus the window whose
/// shell is the session's ancestor directly under kitty.
enum Kitty {
    static let binary = "/Applications/kitty.app/Contents/MacOS/kitty"

    /// Sockets kitty listens on: `listen_on unix:/tmp/kitty` becomes `/tmp/kitty-<pid>`.
    static func sockets(in folder: String = "/tmp") -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.filter { $0 == "kitty" || $0.hasPrefix("kitty-") }.map { "unix:\(folder)/\($0)" }
    }

    static func focus(windowPID: pid_t) -> Bool {
        sockets().contains { socket in
            Shell.run(binary, ["@", "--to", socket, "focus-window", "--match", "pid:\(windowPID)"]) != nil
        }
    }
}

/// Ghostty (1.3+): AppleScript can focus a terminal; matching by TTY needs a build newer than 1.3.1.
enum Ghostty {
    static func script(tty: String) -> String {
        """
        tell application "Ghostty"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with term in terminals of t
                        if tty of term is "\(tty)" then
                            focus term
                        end if
                    end repeat
                end repeat
            end repeat
            activate
        end tell
        """
    }
}
