import SwiftUI

@main
struct ClaudeNotchApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var store = AgentStore.shared
    @State private var hooks = HookStatus.shared
    @State private var prefs = Preferences.shared

    var body: some Scene {
        MenuBarExtra(isInserted: Bindable(prefs).showMenuBarIcon) {
            MenuContent(store: store, hooks: hooks, prefs: prefs, visibility: .shared, updater: .shared)
        } label: {
            Image(nsImage: MenuBarIcon.image(flag: store.anyNeedsAttention))
        }
    }
}

private struct MenuContent: View {
    var store: AgentStore
    var hooks: HookStatus
    @Bindable var prefs: Preferences
    var visibility: NotchVisibility
    var updater: Updater

    var body: some View {
        if let problem = hooks.problem {
            Text(problem)
        } else if hooks.installed {
            Text("Watching Claude Code sessions")
        } else {
            Button(hooks.partlyInstalled ? "Update Claude Code hooks" : "Install Claude Code hooks") {
                hooks.set(installed: true)
            }
        }
        if let release = updater.available {
            Button("Update to \(release.version)…") { Task { await updater.install() } }
        }
        Button("Jump to waiting session  \(GlobalShortcut.jump.display)") { AppDelegate.jumpToWaiting() }
            .disabled(!store.anyNeedsAttention)
        Button(visibility.isHidden ? "Show the notch  \(GlobalShortcut.hide.display)" : "Hide the notch for 10 minutes  \(GlobalShortcut.hide.display)") {
            visibility.toggle()
        }
        Toggle("Quiet", isOn: $prefs.quietMode)
        Divider()
        Toggle("Demo mode", isOn: Bindable(store).autoDemo)
        Menu("Debug") {
            Button("Spawn agent") { store.spawn() }
            Button("Remove agent") { store.removeLast() }
            Button("Wave a flag") { store.flagRandom() }
            Button("Clear flags") { store.clearFlags() }
            Button("Copy diagnostics") { Diagnostics.copy() }
        }
        Button("Settings…") { SettingsWindow.shared.show() }
            .keyboardShortcut(",")
        Divider()
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

/// Whether Claude Code is set up to report to the notch, and anything stopping it.
@MainActor @Observable
final class HookStatus {
    static let shared = HookStatus()

    private(set) var installed = false
    /// Some of our hooks are there, from an older version.
    private(set) var partlyInstalled = false
    private(set) var codexInstalled = false
    var problem: String?
    /// The hook server, in words.
    private(set) var server = "Starting"
    private(set) var serverOK = false

    /// They were installed once and now they're gone (an edit, or another tool rewriting the file).
    var missing: Bool { Preferences.shared.hooksWereInstalled && !installed && !partlyInstalled }

    init() { refresh() }

    func refresh() {
        apply(Self.read())
    }

    /// Reads the settings files off the main thread.
    func refreshInBackground() {
        Task.detached {
            let status = Self.read()
            await MainActor.run { HookStatus.shared.apply(status) }
        }
    }

    private nonisolated static func read() -> (installed: Bool, partly: Bool, codex: Bool) {
        let settings = (try? HookInstaller.read()) ?? [:]
        let installed = HookInstaller.isInstalled(in: settings)
        let codex = (try? HookInstaller.read(HookInstaller.settingsURL(for: .codex))) ?? [:]
        return (installed, !installed && HookInstaller.hasAny(in: settings), HookInstaller.isInstalled(in: codex, kind: .codex))
    }

    private func apply(_ status: (installed: Bool, partly: Bool, codex: Bool)) {
        if installed != status.installed { installed = status.installed }
        if partlyInstalled != status.partly { partlyInstalled = status.partly }
        if codexInstalled != status.codex { codexInstalled = status.codex }
        if installed && !Preferences.shared.hooksWereInstalled { Preferences.shared.hooksWereInstalled = true }
    }

    func setServer(_ state: HookServer.State) {
        switch state {
        case .starting:
            server = "Starting"
            serverOK = false
        case .listening(let port):
            server = "Listening on port \(port)"
            serverOK = true
            if problem?.hasPrefix("Port") == true || problem?.hasPrefix("Ports") == true { problem = nil }
        case .failed(let reason):
            server = "Not running: \(reason)"
            serverOK = false
            problem = "\(reason); hooks can't reach the notch"
        }
    }

    func setCodex(installed: Bool) {
        let url = HookInstaller.settingsURL(for: .codex)
        do {
            try installed ? HookInstaller.install(at: url, kind: .codex) : HookInstaller.uninstall(at: url)
            refresh()
        } catch {
            problem = "Couldn't update ~/.codex/hooks.json"
        }
    }

    func set(installed: Bool) {
        do {
            try installed ? HookInstaller.install() : HookInstaller.uninstall()
            if !installed { Preferences.shared.hooksWereInstalled = false }
            refresh()
        } catch {
            problem = "Couldn't update ~/.claude/settings.json"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static weak var current: AppDelegate?
    private var controllers: [NotchController] = []
    private var server: HookServer?
    private var reaper: Timer?
    private var ticks = 0
    private var observers: [NSObjectProtocol] = []
    private var pointerMonitor: Any?
    private var rebuildWork: DispatchWorkItem?
    private var layoutKey = ""
    private var lastPointerCheck = Date.distantPast
    private let usageReader = UsageReader()
    private let welcome = WelcomeWindow()
    private let archive = SessionArchive()
    private let phoneAlerts = PhoneAlerts()
    private var budgetWarned: Set<String> = []
    /// URLs that arrive before launching has finished.
    private var pendingURLs: [URL] = []
    private var launched = false

    /// Running as the host for unit tests: no server, no notch, no timers.
    static var isTesting: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.runCommandLine(CommandLine.arguments) { return }
        if Self.isTesting { return }
        if Self.handOffToRunningCopy(arguments: CommandLine.arguments) { return }
        Self.current = self
        PowerState.start()
        let store = AgentStore.shared
        let prefs = Preferences.shared
        archive.load()
        store.archive = archive
        store.rules = { RuleStore.shared.rules }
        store.audit = AuditLog.shared
        store.onNeed = { prefs.playNeedSound($0) }
        store.tuckAwayAfter = prefs.tuckAwayAfter
        prefs.onTuckChange = { store.tuckAwayAfter = prefs.tuckAwayAfter }
        prefs.onLayoutChange = { [weak self] in self?.scheduleRebuild(force: true) }
        upgradeHooksIfNeeded()
        NotchVisibility.shared.watchMenus()
        buildNotches(force: true)
        watchSystem()
        if store.autoDemo { store.startDemo() }
        GlobalShortcut.register([
            (.jump, { Self.jumpToWaiting() }),
            (.settings, { SettingsWindow.shared.show() }),
            (.hide, { NotchVisibility.shared.toggle() }),
        ])
        startServer()
        refreshRegistry()
        welcome.showIfNeeded()
        Updater.shared.checkIfDue()
        reaper = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        launched = true
        if CommandLine.arguments.contains("--settings") { SettingsWindow.shared.show() }
        pendingURLs.forEach(handle)
        pendingURLs = []
    }

    /// Every 3 s: the quick checks every time, the slower ones less often.
    private func tick() {
        ticks += 1
        let store = AgentStore.shared, prefs = Preferences.shared
        store.removeDeadSessions()
        store.refreshPresence()
        store.resolveChannels()
        phoneAlerts.check(store.present, settings: prefs.phoneAlertSettings)
        checkBudgets()
        refreshRegistry()
        refreshUsage()
        if ticks % 5 == 0 {
            // Every 15 s: save history, see whether the hooks are still there, and whether a Focus is on.
            archive.save(store.agents)
            HookStatus.shared.refreshInBackground()
            server?.ensurePortFile()
            if prefs.followFocus {
                Task.detached {
                    let on = FocusStatus.read() ?? false
                    await MainActor.run { if Preferences.shared.focusOn != on { Preferences.shared.focusOn = on } }
                }
            }
        }
        if ticks % 10 == 1 { refreshPlanUsage() }
        if ticks % 1200 == 0 { Updater.shared.checkIfDue() }
    }

    // MARK: One copy at a time

    /// Another copy is already running. The same copy launched again hands over (showing Settings) and quits; a
    /// different copy (a newer build, say) takes over from it. Returns true when this copy should quit.
    static func handOffToRunningCopy(arguments: [String]) -> Bool {
        let me = NSRunningApplication.current
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me.processIdentifier }
        guard !others.isEmpty else { return false }
        if others.contains(where: { $0.bundleURL?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL }) {
            if let url = URL(string: "claude-notch://settings") { NSWorkspace.shared.open(url) }
            NSApp.terminate(nil)
            return true
        }
        hookLog.info("taking over from another copy of the app")
        others.forEach { $0.terminate() }
        // Give it a moment to let go of the port.
        let deadline = Date().addingTimeInterval(3)
        while others.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    // MARK: Ways in

    /// Opening the app again (from Finder, Spotlight or the Dock): Settings, since there's no window otherwise.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.shared.show()
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else { pendingURLs += urls; return }
        urls.forEach(handle)
    }

    /// `claude-notch://settings[/pane]`, `://jump`, `://hide`, `://show`, `://quiet`.
    private func handle(_ url: URL) {
        guard url.scheme == "claude-notch" else { return }
        switch url.host {
        case "settings":
            SettingsWindow.shared.show(url.pathComponents.dropFirst().first.flatMap(SettingsPane.init(rawValue:)))
        case "jump": Self.jumpToWaiting()
        case "hide": NotchVisibility.shared.hide(for: 10 * 60)
        case "show": NotchVisibility.shared.show()
        case "quiet": Preferences.shared.quietMode.toggle()
        default: SettingsWindow.shared.show()
        }
    }

    // MARK: Displays

    private func watchSystem() {
        let center = NotificationCenter.default, workspace = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRebuild() }
            },
            workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // The network stack and the displays may both have changed while asleep.
                    self?.server?.restart()
                    self?.scheduleRebuild()
                }
            },
        ]
        // Following the pointer between displays: a cheap look, at most twice a second.
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
    }

    private func pointerMoved() {
        let prefs = Preferences.shared
        guard prefs.screenChoice == .pointer, !prefs.allDisplays, Date().timeIntervalSince(lastPointerCheck) > 0.5 else { return }
        lastPointerCheck = Date()
        if key(for: screens()) != layoutKey { scheduleRebuild(delay: 0.2) }
    }

    /// Displays settle over several notifications (lid, dock, resolution): rebuild once they've stopped.
    private func scheduleRebuild(delay: Double = 0.5, force: Bool = false) {
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.buildNotches(force: force) } }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func screens() -> [NSScreen] {
        let prefs = Preferences.shared
        return prefs.allDisplays ? NSScreen.screens : [NotchMetrics.screen(for: prefs.screenChoice)].compactMap { $0 }
    }

    private func key(for screens: [NSScreen]) -> String {
        let prefs = Preferences.shared
        return screens.map { "\(NSStringFromRect($0.frame))\($0.safeAreaInsets.top)" }.joined(separator: "|")
            + "\(prefs.wingWidth)\(prefs.notchStyle)\(prefs.wingSides)"
    }

    /// One notch per display it should show on, rebuilt when displays or the layout settings change.
    private func buildNotches(force: Bool = false) {
        let prefs = Preferences.shared
        let screens = screens()
        let key = key(for: screens)
        guard force || key != layoutKey else {
            controllers.forEach { $0.refreshWings() }
            return
        }
        layoutKey = key
        controllers.forEach { $0.close() }
        controllers = screens.map {
            NotchController(store: AgentStore.shared,
                            metrics: .forScreen($0, wingWidth: CGFloat(prefs.wingWidth), style: prefs.notchStyle),
                            screenID: $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
        }
    }

    // MARK: Hooks

    /// After an update the hook commands may have changed; if you'd installed them, they're brought up to date.
    private func upgradeHooksIfNeeded() {
        let hooks = HookStatus.shared
        // Some of our hooks are there, so you installed them once: bring them up to date.
        if hooks.partlyInstalled {
            hookLog.info("updating hooks from an older version")
            hooks.set(installed: true)
        }
        if hooks.installed { Preferences.shared.hooksWereInstalled = true }
    }

    private func startServer() {
        let server = HookServer(
            onEvent: { event in Task { @MainActor in AgentStore.shared.apply(event) } },
            onPermission: { event, reply in
                await MainActor.run {
                    let store = AgentStore.shared
                    if let decision = store.decideByRule(event) {
                        reply(decision)
                        return nil
                    }
                    guard Preferences.shared.answerPermissions else {
                        store.apply(event)
                        reply(nil)
                        return nil
                    }
                    return store.hold(event, reply: reply)
                }
            },
            onExpire: { token in Task { @MainActor in AgentStore.shared.expire(token) } },
            onState: { state in Task { @MainActor in HookStatus.shared.setServer(state) } })
        self.server = server
        server.start()
    }

    static func restartServer() { current?.server?.restart() }

    /// Picks up running sessions from Claude Code's registry, hooks or not.
    private func refreshRegistry() {
        Task.detached {
            let sessions = SessionRegistry.running()
            hookLog.debug("registry: \(sessions.map(\.sessionID), privacy: .public)")
            await MainActor.run { AgentStore.shared.syncRegistry(sessions) }
        }
    }

    /// Reads what each session's transcript has added since last time, off the main thread.
    private func refreshUsage() {
        let sessions = AgentStore.shared.agents.compactMap { agent in agent.transcriptPath.map { (agent.id, $0) } }
        let reader = usageReader
        Task.detached {
            for (id, path) in sessions {
                guard let usage = await reader.usage(transcript: path) else { continue }
                await MainActor.run { AgentStore.shared.setUsage(usage, for: id) }
            }
        }
    }

    private func refreshPlanUsage() {
        Task.detached {
            let usage = PlanUsage.read()
            await MainActor.run { if AgentStore.shared.planUsage != usage { AgentStore.shared.planUsage = usage } }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        archive.save(AgentStore.shared.agents)
    }

    /// `--install-hooks` / `--uninstall-hooks`: set up Claude Code without the UI (handy over SSH or in scripts),
    /// then quit. Returns false when there's nothing to do and the app should start as usual.
    static func runCommandLine(_ arguments: [String]) -> Bool {
        if let index = arguments.firstIndex(of: "--install-editor-helper") {
            // --install-editor-helper [Cursor|VS Code|Windsurf]: every editor on this Mac if none is named.
            let named = arguments.dropFirst(index + 1).first.map { $0.lowercased() }
            let editors = EditorHelper.installedEditors.filter { named == nil || $0.name.lowercased() == named }
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                for editor in editors {
                    let ok = await EditorHelper.install(editor)
                    print(ok ? "Terminal focus set up in \(editor.name)" : "Couldn't set up \(editor.name)")
                }
                semaphore.signal()
            }
            semaphore.wait()
            exit(editors.isEmpty ? 1 : 0)
        }
        if arguments.contains("--diagnostics") {
            print(Diagnostics.summary())
            exit(0)
        }
        let codex = arguments.contains("--install-codex-hooks") || arguments.contains("--uninstall-codex-hooks")
        let install = arguments.contains("--install-hooks") || arguments.contains("--install-codex-hooks")
        let uninstall = arguments.contains("--uninstall-hooks") || arguments.contains("--uninstall-codex-hooks")
        guard install || uninstall else { return false }
        let kind: AgentKind = codex ? .codex : .claude
        let url = HookInstaller.settingsURL(for: kind)
        do {
            try install ? HookInstaller.install(at: url, kind: kind) : HookInstaller.uninstall(at: url)
            print(install ? "Claude Notch hooks installed in \(url.path)" : "Claude Notch hooks removed from \(url.path)")
            if install && codex { print("Approve them in Codex: type /hooks and trust the new hooks.") }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Couldn't update \(url.path): \(error)\n".utf8))
            exit(1)
        }
    }

    /// Over budget: one heads-up per session (and one for the total), by sound and, if set up, phone.
    private func checkBudgets() {
        let prefs = Preferences.shared, agents = AgentStore.shared.present
        let warnings = prefs.budgets.newWarnings(agents, warned: budgetWarned)
        guard !warnings.isEmpty else { return }
        budgetWarned.formUnion(warnings)
        if !prefs.isQuiet { NSSound(named: "Basso")?.play() }
        let spent = Format.dollars(Budget.spent(agents))
        PhoneAlerts.send(title: "Over budget", message: "Your running sessions have cost \(spent) at API prices.",
                         settings: prefs.phoneAlertSettings)
    }

    /// The global shortcut: straight to whichever session has waited longest.
    static func jumpToWaiting() {
        let store = AgentStore.shared
        guard let agent = store.longestWaiting else { return }
        store.acknowledge(agent.id)
        WindowFocuser.focus(agent)
    }
}
