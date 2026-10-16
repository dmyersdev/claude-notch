import SwiftUI

@main
struct ClaudeNotchApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var store = AgentStore.shared
    @State private var hooks = HookStatus.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: store, hooks: hooks)
        } label: {
            Image(nsImage: MenuBarIcon.image(flag: store.anyNeedsAttention))
        }
        Settings {
            SettingsView(prefs: Preferences.shared, hooks: hooks)
        }
    }
}

private struct MenuContent: View {
    var store: AgentStore
    var hooks: HookStatus
    @Environment(\.openSettings) private var openSettings

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
        Button("Jump to waiting session  \(GlobalShortcut.display)") { AppDelegate.jumpToWaiting() }
            .disabled(!store.anyNeedsAttention)
        Divider()
        Toggle("Demo mode", isOn: Bindable(store).autoDemo)
        Menu("Debug") {
            Button("Spawn agent") { store.spawn() }
            Button("Remove agent") { store.removeLast() }
            Button("Wave a flag") { store.flagRandom() }
            Button("Clear flags") { store.clearFlags() }
        }
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct SettingsView: View {
    @Bindable var prefs: Preferences
    var hooks: HookStatus

    var body: some View {
        Form {
            Section {
                Toggle("Answer permission prompts from the notch", isOn: $prefs.answerPermissions)
                Text("Claude's prompt waits up to \(Int(HookServer.holdSeconds)) seconds (\(Int(HookServer.questionHoldSeconds)) for questions) for an answer on the card, then asks as usual. Clicking the card hands it straight back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Play a sound when a session needs you", isOn: $prefs.playSound)
                Picker("Tuck away idle sessions after", selection: $prefs.tuckAwayMinutes) {
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Text("Never").tag(0)
                }
                Text("Sessions that are idle, or finished and waiting for you, walk back into the notch and stop holding it open. Blocked sessions stay. Any new activity brings them back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Jump to the waiting session", value: GlobalShortcut.display)
            }
            Section {
                LabeledContent("Notch width") {
                    Slider(value: $prefs.wingWidth, in: 120...300, step: 10)
                        .frame(width: 180)
                }
                Toggle("Show on all displays", isOn: $prefs.allDisplays)
                Toggle("Launch at login", isOn: $prefs.launchAtLogin)
            }
            Section("Phone alerts") {
                Toggle("Ping my phone when a session waits and I'm away", isOn: $prefs.phoneAlerts)
                if prefs.phoneAlerts {
                    TextField("ntfy topic", text: $prefs.ntfyTopic, prompt: Text("something-long-and-unguessable"))
                    TextField("Server", text: $prefs.ntfyServer)
                    Picker("After", selection: $prefs.phoneAlertMinutes) {
                        Text("2 minutes").tag(2)
                        Text("5 minutes").tag(5)
                        Text("10 minutes").tag(10)
                        Text("30 minutes").tag(30)
                    }
                    Toggle("Also when a session finishes", isOn: $prefs.phoneAlertsFinished)
                    Button("Send a test") { PhoneAlerts.sendTest(settings: prefs.phoneAlertSettings) }
                }
                Text("Install the free ntfy app on your phone and subscribe to the same topic. Alerts go only when the screen is locked or you've been away for two minutes, and say which session is waiting and why, never the command. Anyone who knows the topic can read it, so make it long, or use your own server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if HookInstaller.codexAvailable {
                Section {
                    if hooks.codexInstalled {
                        LabeledContent("Codex hooks", value: "Installed")
                        Button("Remove Codex hooks") { hooks.setCodex(installed: false) }
                    } else {
                        Button("Install Codex hooks") { hooks.setCodex(installed: true) }
                    }
                    Text("Codex runs new hooks only after you approve them: type /hooks in Codex and trust them. Codex sessions show as teal Claudes; Always and question answers are Claude Code only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                if hooks.installed {
                    LabeledContent("Claude Code hooks", value: "Installed")
                    Button("Remove hooks") { hooks.set(installed: false) }
                } else {
                    Button(hooks.partlyInstalled ? "Update hooks" : "Install hooks") { hooks.set(installed: true) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize()
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

    init() { refresh() }

    func refresh() {
        let settings = (try? HookInstaller.read()) ?? [:]
        installed = HookInstaller.isInstalled(in: settings)
        partlyInstalled = !installed && HookInstaller.hasAny(in: settings)
        let codex = (try? HookInstaller.read(HookInstaller.settingsURL(for: .codex))) ?? [:]
        codexInstalled = HookInstaller.isInstalled(in: codex, kind: .codex)
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
            refresh()
        } catch {
            problem = "Couldn't update ~/.claude/settings.json"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [NotchController] = []
    private var server: HookServer?
    private var reaper: Timer?
    private var screenObserver: NSObjectProtocol?
    private let usageReader = UsageReader()
    private let welcome = WelcomeWindow()
    private let archive = SessionArchive()
    private let phoneAlerts = PhoneAlerts()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.runCommandLine(CommandLine.arguments) { return }
        PowerState.start()
        let store = AgentStore.shared
        let prefs = Preferences.shared
        archive.load()
        store.archive = archive
        store.onNeed = { prefs.playNeedSound($0) }
        store.tuckAwayAfter = prefs.tuckAwayAfter
        prefs.onTuckChange = { store.tuckAwayAfter = prefs.tuckAwayAfter }
        prefs.onLayoutChange = { [weak self] in self?.buildNotches() }
        buildNotches()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.buildNotches() }
        }
        if store.autoDemo { store.startDemo() }
        GlobalShortcut.register { Self.jumpToWaiting() }
        startServer()
        refreshRegistry()
        welcome.showIfNeeded()
        reaper = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                AgentStore.shared.removeDeadSessions()
                AgentStore.shared.refreshPresence()
                self?.archive.save(AgentStore.shared.agents)
                self?.phoneAlerts.check(AgentStore.shared.present, settings: Preferences.shared.phoneAlertSettings)
                self?.refreshRegistry()
                self?.refreshUsage()
            }
        }
    }

    /// One notch per display it should show on, rebuilt when displays or the width setting change.
    private func buildNotches() {
        controllers.forEach { $0.close() }
        let prefs = Preferences.shared
        let screens = prefs.allDisplays ? NSScreen.screens : [NotchMetrics.preferredScreen].compactMap { $0 }
        controllers = screens.map {
            NotchController(store: AgentStore.shared,
                            metrics: .forScreen($0, wingWidth: CGFloat(prefs.wingWidth)))
        }
    }

    private func startServer() {
        let busy = "Port \(HookServer.port) is busy; hooks can't reach the notch"
        do {
            server = try HookServer(
                onEvent: { event in Task { @MainActor in AgentStore.shared.apply(event) } },
                onPermission: { event, reply in
                    await MainActor.run {
                        guard Preferences.shared.answerPermissions else {
                            AgentStore.shared.apply(event)
                            reply(nil)
                            return nil
                        }
                        return AgentStore.shared.hold(event, reply: reply)
                    }
                },
                onExpire: { token in Task { @MainActor in AgentStore.shared.expire(token) } })
            server?.start { Task { @MainActor in HookStatus.shared.problem = busy } }
        } catch {
            HookStatus.shared.problem = busy
        }
    }

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

    func applicationWillTerminate(_ notification: Notification) {
        archive.save(AgentStore.shared.agents)
    }

    /// `--install-hooks` / `--uninstall-hooks`: set up Claude Code without the UI (handy over SSH or in scripts),
    /// then quit. Returns false when there's nothing to do and the app should start as usual.
    static func runCommandLine(_ arguments: [String]) -> Bool {
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

    /// The global shortcut: straight to whichever session has waited longest.
    static func jumpToWaiting() {
        let store = AgentStore.shared
        guard let agent = store.longestWaiting else { return }
        store.acknowledge(agent.id)
        WindowFocuser.focus(agent)
    }
}
