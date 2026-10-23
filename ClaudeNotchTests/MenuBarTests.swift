import Foundation
import Testing
@testable import ClaudeNotch

/// Keeping the wings off the menu bar's contents.
struct WingFitTests {
    // A 1512-wide screen with a 200-wide notch shape in the middle.
    let screen: ClosedRange<CGFloat> = 0...1512
    let core: ClosedRange<CGFloat> = 656...856

    @Test func withoutLookingBothWingsGetThePreferredWidth() {
        let wings = WingFit.fit(preferred: 180, core: core, screen: screen, occupied: nil, sides: .both, style: .wings)
        #expect(wings.left == 180 && wings.right == 180)
    }

    @Test func wingsShrinkToTheFreeSpaceAndKeepAGap() {
        // App menus end at 560, status icons start at 950.
        let occupied = MenuBarOccupancy(leftEdge: 560, rightEdge: 950)
        let wings = WingFit.fit(preferred: 180, core: core, screen: screen, occupied: occupied, sides: .both, style: .wings)
        #expect(wings.left == 88)
        #expect(wings.right == 86)
    }

    @Test func aSideWithNoRoomIsLeftOut() {
        let occupied = MenuBarOccupancy(leftEdge: 640, rightEdge: 1100)
        let wings = WingFit.fit(preferred: 180, core: core, screen: screen, occupied: occupied, sides: .both, style: .wings)
        #expect(wings.left == 0)
        #expect(wings.right == 180)
    }

    @Test func oneSidedWingsStretch() {
        let wings = WingFit.fit(preferred: 180, core: core, screen: screen, occupied: nil, sides: .right, style: .wings)
        #expect(wings.left == 0)
        #expect(wings.right == 270)
    }

    @Test func compactHasNoWingsAndBelowIgnoresTheMenuBar() {
        let occupied = MenuBarOccupancy(leftEdge: 650, rightEdge: 860)
        let compact = WingFit.fit(preferred: 180, core: core, screen: screen, occupied: occupied, sides: .both, style: .compact)
        #expect(compact.left == 0 && compact.right == 0)
        let below = WingFit.fit(preferred: 180, core: core, screen: screen, occupied: occupied, sides: .both, style: .below)
        #expect(below.left == 180 && below.right == 180)
    }

    @Test func onlyThisScreensMenuBarCounts() {
        let frames = [
            CGRect(x: 900, y: 0, width: 30, height: 24),   // a status icon, right of the notch
            CGRect(x: 1000, y: 0, width: 30, height: 24),
            CGRect(x: 100, y: 0, width: 400, height: 24),  // app menus, left of it
            CGRect(x: 950, y: 300, width: 30, height: 24), // a window somewhere else
            CGRect(x: 2000, y: 0, width: 30, height: 24),  // another screen's menu bar
        ]
        let occupancy = MenuBarSpace.occupancy(of: frames, top: 0, screenX: 0...1512, notchMid: 756)
        #expect(occupancy == MenuBarOccupancy(leftEdge: 500, rightEdge: 900))
    }

    @Test func closedShapeKeepsTheNotchCentred() {
        var metrics = NotchMetrics(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), notchWidth: 186,
                                   notchHeight: 32, hasNotch: true)
        #expect(metrics.closedSize(left: 100, right: 40).width == 338)
        #expect(NotchMetrics.closedOffset(left: 100, right: 40) == -30)
        metrics.style = .below
        #expect(metrics.closedSize(left: 100, right: 100).height == 32 + metrics.stripHeight)
        #expect(metrics.closedSize(left: 0, right: 0).height == 32)
        // The window leaves room for the widest wing on either side.
        #expect(metrics.panelFrame.width >= metrics.coreWidth + 2 * metrics.maxWing)
    }
}

struct PolicyTests {
    func bash(_ command: String) -> PermissionRequest {
        PermissionRequest(summary: "Run \(command)", tool: "Bash",
                          input: try! JSONSerialization.data(withJSONObject: ["command": command]))
    }

    @Test func globsMatchTheWholeTarget() {
        #expect(PolicyEngine.glob("git status*", matches: "git status --short"))
        #expect(PolicyEngine.glob("*rm -rf*", matches: "cd x && rm -rf build"))
        #expect(PolicyEngine.glob("*.env*", matches: "/app/.env.local"))
        #expect(PolicyEngine.glob("npm ?est", matches: "npm test"))
        #expect(!PolicyEngine.glob("git status*", matches: "sudo git status"))
        #expect(!PolicyEngine.glob("npm test", matches: "npm test --watch"))
    }

    @Test func askBeatsDenyBeatsAllow() {
        let rules = [Rule(tool: "Bash", pattern: "git *", action: .allow),
                     Rule(tool: "Bash", pattern: "git push*", action: .deny),
                     Rule(tool: "*", pattern: "*--force*", action: .ask)]
        #expect(PolicyEngine.decide(bash("git status"), rules: rules)?.action == .allow)
        #expect(PolicyEngine.decide(bash("git push origin"), rules: rules)?.action == .deny)
        #expect(PolicyEngine.decide(bash("git push --force"), rules: rules)?.action == .ask)
        #expect(PolicyEngine.decide(bash("npm test"), rules: rules) == nil)
    }

    @Test func disabledRulesAndQuestionsAreIgnored() {
        var rule = Rule(tool: "*", pattern: "*", action: .allow)
        rule.enabled = false
        #expect(PolicyEngine.decide(bash("ls"), rules: [rule]) == nil)
        let question = PermissionRequest(summary: "?", tool: "AskUserQuestion",
                                         questions: [Question(text: "Which?", options: [.init(label: "A")], multiSelect: false)])
        #expect(PolicyEngine.decide(question, rules: [Rule(tool: "*", pattern: "*", action: .allow)]) == nil)
    }

    @Test func targetsComeFromTheToolsInput() {
        let edit = PermissionRequest(summary: "", tool: "Edit",
                                     input: try! JSONSerialization.data(withJSONObject: ["file_path": "/x/.env"]))
        #expect(PolicyEngine.target(of: edit) == "/x/.env")
        #expect(PolicyEngine.target(of: bash("ls -la")) == "ls -la")
    }

    @MainActor @Test func rulesAnswerWithoutHolding() {
        let store = AgentStore()
        store.rules = { [Rule(tool: "Bash", pattern: "npm test*", action: .allow),
                         Rule(tool: "Bash", pattern: "rm *", action: .deny)] }
        let allow = HookEvent(sessionID: "s", kind: .permissionRequest(bash("npm test")))
        #expect(store.decideByRule(allow) == .allow)
        #expect(store.agents.first?.need == nil)
        #expect(store.agents.first?.ask == nil)
        let deny = HookEvent(sessionID: "s", kind: .permissionRequest(bash("rm x")))
        if case .denyBecause = store.decideByRule(deny) {} else { Issue.record("expected a deny") }
        #expect(store.decideByRule(HookEvent(sessionID: "s", kind: .permissionRequest(bash("make")))) == nil)
    }
}

@MainActor struct SnoozeTests {
    let start = Date(timeIntervalSinceReferenceDate: 10_000)

    @Test func snoozedSessionsComeBackWithANudge() {
        let store = AgentStore()
        var nudges: [Need] = []
        store.apply(HookEvent(sessionID: "s", kind: .needs(.permission)), now: start)
        store.onNeed = { nudges.append($0) }
        store.snooze("s", for: 600, now: start)
        #expect(store.present.isEmpty)
        store.refreshPresence(now: start.addingTimeInterval(300))
        #expect(store.present.isEmpty)
        store.refreshPresence(now: start.addingTimeInterval(601))
        #expect(store.present.map(\.id) == ["s"])
        #expect(nudges == [.permission])
    }

    @Test func newWorkEndsTheSnooze() {
        let store = AgentStore()
        store.apply(HookEvent(sessionID: "s", kind: .stop), now: start)
        store.snooze("s", for: 600, now: start)
        store.apply(HookEvent(sessionID: "s", kind: .prompt), now: start.addingTimeInterval(60))
        #expect(store.present.map(\.id) == ["s"])
    }
}

struct SearchTests {
    @Test func matchesEveryWordAnywhere() {
        var a = Agent(id: "a", project: "notch-claude")
        a.title = "Fix the hover"
        var b = Agent(id: "b", project: "api")
        b.cwd = "/Users/me/work/api"
        b.lastTool = "Run npm test"
        #expect(PanelSearch.filter([a, b], query: "hover").map(\.id) == ["a"])
        #expect(PanelSearch.filter([a, b], query: "work npm").map(\.id) == ["b"])
        #expect(PanelSearch.filter([a, b], query: "NOTCH fix").map(\.id) == ["a"])
        #expect(PanelSearch.filter([a, b], query: "  ").count == 2)
    }

    @Test func replyFieldsMakeRoom() {
        var agent = Agent(id: "a", project: "p")
        agent.need = .yourTurn
        #expect(PanelLayout.rowHeight(for: agent, canReply: true)
                == PanelLayout.rowHeight(for: agent) + NotchMetrics.replyHeight)
        let metrics = NotchMetrics(screenFrame: .zero, notchWidth: 186, notchHeight: 32, hasNotch: true)
        #expect(metrics.openSize(PanelLayout(tiles: 1, banner: true)).height
                == metrics.openSize(PanelLayout(tiles: 1)).height + NotchMetrics.bannerHeight + NotchMetrics.openGap)
    }
}

struct HousekeepingTests {
    @Test func versionsCompareByNumber() {
        #expect(Updater.isNewer("2.10", than: "2.9"))
        #expect(Updater.isNewer("v3.2.1", than: "3.2"))
        #expect(!Updater.isNewer("3.2", than: "3.2.0"))
        #expect(!Updater.isNewer("3.1", than: "3.2"))
    }

    @Test func readsTheLatestRelease() {
        let json = #"{"tag_name":"v3.3","html_url":"https://github.com/x/y/releases/tag/v3.3","assets":[{"name":"notes.txt","browser_download_url":"https://a/notes.txt"},{"name":"Claude-Notch-3.3.zip","browser_download_url":"https://a/Claude-Notch-3.3.zip"}]}"#
        let release = Updater.parse(Data(json.utf8))
        #expect(release?.version == "3.3")
        #expect(release?.download?.lastPathComponent == "Claude-Notch-3.3.zip")
    }

    @Test func planUsageTakesTheNewestSample() {
        let json = #"{"version":2,"samples":[{"t":1000,"u":{"fh":50,"sd":10}},{"t":3000,"u":{"fh":7,"sd":40}},{"t":2000,"u":{"fh":1,"sd":1}}]}"#
        let usage = PlanUsage.parse(Data(json.utf8))
        #expect(usage?.fiveHour == 7 && usage?.weekly == 40)
        #expect(usage?.at == Date(timeIntervalSince1970: 3))
        #expect(PlanUsage(fiveHour: 81, weekly: 0, at: .now).isHigh)
    }

    @Test func focusIsOnWhenAnAssertionIsHeld() {
        #expect(FocusStatus.parse(Data(#"{"data":[{"storeAssertionRecords":[{"x":1}]}]}"#.utf8)) == true)
        #expect(FocusStatus.parse(Data(#"{"data":[{}]}"#.utf8)) == false)
        #expect(FocusStatus.parse(Data("nope".utf8)) == nil)
    }

    @Test func serverPortsAndBackoff() {
        #expect(HookServer.next(after: 47474) == 47475)
        #expect(HookServer.next(after: HookServer.ports.upperBound) == nil)
        #expect(HookServer.backoff(0) == 1)
        #expect(HookServer.backoff(3) == 8)
        #expect(HookServer.backoff(20) == 60)
    }

    @Test func kittyNeedsRemoteControlAndASocket() {
        #expect(TerminalChecks.kittyMissing("") == ["allow_remote_control yes", "listen_on unix:/tmp/kitty"])
        #expect(TerminalChecks.kittyMissing("allow_remote_control socket-only\nlisten_on unix:/tmp/kitty").isEmpty)
        #expect(TerminalChecks.kittyMissing("# allow_remote_control yes\nlisten_on unix:/tmp/k") == ["allow_remote_control yes"])
        #expect(TerminalChecks.ghosttyMatchesTabs("1.3.2"))
        #expect(TerminalChecks.ghosttyMatchesTabs("1.4"))
        #expect(!TerminalChecks.ghosttyMatchesTabs("1.3.1"))
        #expect(!TerminalChecks.ghosttyMatchesTabs("1.2.9"))
    }

    @Test func repliesAreOneSafeLine() {
        #expect(TerminalControl.line("  fix it\nthen test  ") == "fix it then test")
        #expect(TerminalControl.appleScriptQuoted(#"say "hi" \ bye"#) == #""say \"hi\" \\ bye""#)
    }
}

struct HookCommandTests {
    @Test func commandsReadThePortFile() {
        let command = HookInstaller.command(for: "Stop")
        #expect(command.contains("claude-notch-port"))
        #expect(command.contains("|| echo 47474"))
        #expect(command.hasSuffix("/event\" || true"))
        #expect(HookInstaller.command(for: "PermissionRequest").contains("/permission\""))
    }

    @Test func oldHooksAreRecognisedAndReplaced() {
        let old = "curl -s -m 1 -o /dev/null --data-binary @- http://127.0.0.1:47474/event || true"
        let settings: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": old]]]]]]
        #expect(HookInstaller.hasAny(in: settings))
        #expect(!HookInstaller.isInstalled(in: settings))
        let updated = HookInstaller.installing(into: settings)
        let stop = (updated["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        #expect(stop?.count == 1)
        #expect(HookInstaller.isInstalled(in: updated))
    }

    @Test func updatesStartOverIfTheFileChangesMidway() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID()).json")
        try Data(#"{"model":"opus"}"#.utf8).write(to: url)
        var passes = 0
        try HookInstaller.update(at: url) { settings in
            passes += 1
            // Someone else writes while the first pass is working.
            if passes == 1 { try? Data(#"{"model":"sonnet"}"#.utf8).write(to: url) }
            var settings = settings
            settings["touched"] = true
            return settings
        }
        let result = try HookInstaller.read(url)
        #expect(passes == 2)
        #expect(result["model"] as? String == "sonnet")
        #expect(result["touched"] as? Bool == true)
    }
}
