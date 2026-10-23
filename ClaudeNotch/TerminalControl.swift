import AppKit

/// Typing into the terminal a session runs in: a reply as its next prompt, or Esc to stop its turn.
/// Only tmux and iTerm can take keystrokes from outside without stealing focus, so only those get Reply and Stop.
/// (Claude Code's own session socket isn't an option: messages on it count as from another session, not from you.)
enum ControlChannel: Equatable, Sendable {
    case tmux(pane: String)
    case iTerm(tty: String)

    var name: String {
        switch self {
        case .tmux: "tmux"
        case .iTerm: "iTerm"
        }
    }
}

enum TerminalControl {
    /// Where keystrokes for the session at `pid` can go, if anywhere. Runs `tmux`, so call it off the main thread.
    static func channel(pid: pid_t, iTermOwns: Bool) -> ControlChannel? {
        guard let tty = WindowFocuser.processInfo(pid)?.tty else { return nil }
        if let pane = Tmux.pane(forTTY: tty) { return .tmux(pane: pane.id) }
        return iTermOwns ? .iTerm(tty: tty) : nil
    }

    /// One line of text, as Claude Code would get it typed: newlines would submit early, so they become spaces.
    static func line(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Inside an AppleScript string literal.
    static func appleScriptQuoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func iTermScript(tty: String, write: String, newline: Bool) -> String {
        """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is \(appleScriptQuoted(tty)) then
                            tell s to write text \(write) newline \(newline ? "YES" : "NO")
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
    }

    /// Types the reply and presses Return. Returns false if it couldn't be delivered.
    @discardableResult
    static func send(_ text: String, via channel: ControlChannel) -> Bool {
        let text = line(text)
        guard !text.isEmpty else { return false }
        switch channel {
        case .tmux(let pane):
            guard let tmux = Tmux.binary,
                  Shell.run(tmux, ["send-keys", "-t", pane, "-l", "--", text]) != nil else { return false }
            return Shell.run(tmux, ["send-keys", "-t", pane, "Enter"]) != nil
        case .iTerm(let tty):
            return runAppleScript(iTermScript(tty: tty, write: appleScriptQuoted(text), newline: true))
        }
    }

    /// Esc, which interrupts Claude Code's turn. (SIGINT would quit it altogether, so never that.)
    @discardableResult
    static func interrupt(via channel: ControlChannel) -> Bool {
        switch channel {
        case .tmux(let pane):
            guard let tmux = Tmux.binary else { return false }
            return Shell.run(tmux, ["send-keys", "-t", pane, "Escape"]) != nil
        case .iTerm(let tty):
            return runAppleScript(iTermScript(tty: tty, write: "(character id 27)", newline: false))
        }
    }

    private static func runAppleScript(_ source: String) -> Bool {
        Shell.run("/usr/bin/osascript", ["-e", source]) != nil
    }
}
