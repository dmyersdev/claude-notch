import Foundation
import Testing
@testable import ClaudeNotch

struct TerminalTests {
    @Test func knowsTheNewTerminals() {
        #expect(WindowFocuser.target(bundleID: "com.mitchellh.ghostty") == .ghostty)
        #expect(WindowFocuser.target(bundleID: "net.kovidgoyal.kitty") == .kitty)
        #expect(WindowFocuser.target(bundleID: "com.github.wez.wezterm") == .wezTerm)
        // No way to target a tab: just brought forward.
        #expect(WindowFocuser.target(bundleID: "dev.warp.Warp-Stable") == .other)
        #expect(WindowFocuser.target(bundleID: "org.alacritty") == .other)
    }

    @Test func tmuxPanesAndClientsParse() {
        let panes = Tmux.parsePanes("/dev/ttys004 %1 work\n/dev/ttys009 %7 my session\n")
        #expect(panes == [Tmux.Pane(tty: "/dev/ttys004", id: "%1", session: "work"),
                          Tmux.Pane(tty: "/dev/ttys009", id: "%7", session: "my session")])
        let clients = Tmux.parseClients("/dev/ttys002 812 work\nbroken line\n")
        #expect(clients == [Tmux.Client(tty: "/dev/ttys002", pid: 812, session: "work")])
    }

    @Test func wezTermFindsThePaneByTTY() {
        let json = Data(#"[{"pane_id":3,"tty_name":"/dev/ttys001"},{"pane_id":8,"tty_name":"/dev/ttys012"}]"#.utf8)
        #expect(WezTerm.paneID(forTTY: "/dev/ttys012", in: json) == 8)
        #expect(WezTerm.paneID(forTTY: "/dev/ttys099", in: json) == nil)
    }

    @Test func kittySocketsAreFound() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kitty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["kitty-4242", "kitty", "other"] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: nil)
        }
        #expect(Set(Kitty.sockets(in: folder.path)) == ["unix:\(folder.path)/kitty-4242", "unix:\(folder.path)/kitty"])
    }

    @Test func ghosttyScriptMatchesByTTY() {
        #expect(Ghostty.script(tty: "/dev/ttys012").contains(#"if tty of term is "/dev/ttys012""#))
    }
}
