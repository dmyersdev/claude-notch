import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, notch, alerts, rules, terminals, agents, about

    var id: Self { self }
    var title: String {
        switch self {
        case .general: "General"
        case .notch: "Notch & Menu Bar"
        case .alerts: "Alerts & Budget"
        case .rules: "Rules"
        case .terminals: "Terminals & Editors"
        case .agents: "Claude Code & Codex"
        case .about: "About"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .notch: "menubar.rectangle"
        case .alerts: "bell.badge"
        case .rules: "checklist"
        case .terminals: "terminal"
        case .agents: "link"
        case .about: "info.circle"
        }
    }
    var tint: Color {
        switch self {
        case .general: .gray
        case .notch: .indigo
        case .alerts: .red
        case .rules: .green
        case .terminals: .black
        case .agents: .orange
        case .about: .blue
        }
    }
}

@MainActor @Observable final class SettingsNavigation {
    var pane: SettingsPane = .general
}

struct SettingsView: View {
    @Bindable var prefs: Preferences
    var hooks: HookStatus
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: Binding(get: { navigation.pane }, set: { if let pane = $0 { navigation.pane = pane } })) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    Image(systemName: pane.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(pane.tint.gradient, in: .rect(cornerRadius: 5))
                }
                .badge(badge(for: pane))
                .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
        } detail: {
            Group {
                switch navigation.pane {
                case .general: GeneralPane(prefs: prefs, hooks: hooks)
                case .notch: NotchPane(prefs: prefs)
                case .alerts: AlertsPane(prefs: prefs)
                case .rules: RulesPane(rules: .shared, prefs: prefs)
                case .terminals: TerminalsPane()
                case .agents: AgentsPane(hooks: hooks)
                case .about: AboutPane(prefs: prefs, updater: .shared)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(navigation.pane.title)
        }
        .frame(minWidth: 640, minHeight: 460)
    }

    private func badge(for pane: SettingsPane) -> Text? {
        switch pane {
        case .agents where !hooks.installed: Text("!")
        case .about where Updater.shared.available != nil: Text("1")
        default: nil
        }
    }
}

/// A grey explanatory line under a setting.
private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: General

private struct GeneralPane: View {
    @Bindable var prefs: Preferences
    var hooks: HookStatus

    var body: some View {
        Form {
            if !hooks.installed {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hooks.partlyInstalled ? "The hooks need an update" : "Claude Code isn't reporting to the notch")
                                .font(.headline)
                            Text("Sessions show up, but prompts, questions and reviews need the hooks.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(hooks.partlyInstalled ? "Update" : "Install") { hooks.set(installed: true) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            Section("Answering") {
                Toggle("Answer permission prompts from the notch", isOn: $prefs.answerPermissions)
                Note("Claude's prompt waits up to \(Int(HookServer.holdSeconds)) seconds (\(Int(HookServer.questionHoldSeconds)) for questions) for an answer on the card, then asks as usual. Clicking the card hands it straight back.")
                Picker("Tuck away idle sessions after", selection: $prefs.tuckAwayMinutes) {
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Text("Never").tag(0)
                }
                Note("Idle or finished sessions walk back into the notch and stop holding it open. Blocked sessions stay. Any new activity brings them back.")
            }
            Section("Shortcuts") {
                LabeledContent("Jump to the waiting session", value: GlobalShortcut.jump.display)
                LabeledContent("Open Settings", value: GlobalShortcut.settings.display)
                LabeledContent("Hide or show the notch", value: GlobalShortcut.hide.display)
                LabeledContent("In the open panel", value: "Click it, then ↑↓ A D L ↩ Z / esc")
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: $prefs.launchAtLogin)
            }
        }
    }
}

// MARK: Notch & menu bar

private struct NotchPane: View {
    @Bindable var prefs: Preferences
    @State private var accessibility = MenuBarSpace.hasAccess
    @State private var tightSpacing = StatusItemSpacing.isTight

    var body: some View {
        Form {
            Section {
                Picker("Claudes walk", selection: $prefs.notchStyle) {
                    ForEach(NotchStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Note(styleNote)
                if prefs.notchStyle != .compact {
                    Picker("Wings", selection: $prefs.wingSides) {
                        ForEach(WingSides.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Wing width") {
                        Slider(value: $prefs.wingWidth, in: 80...300, step: 10).frame(width: 200)
                    }
                }
            } header: {
                Text("Where the Claudes live")
            }
            Section("Keeping the menu bar usable") {
                Toggle("Fit the wings to the free menu bar", isOn: $prefs.fitToMenuBar)
                    .disabled(prefs.notchStyle == .below)
                Note("Each wing shrinks to the gap beside the notch, so it never covers a menu bar icon. A side with no room is left out.")
                Toggle("Also keep clear of app menus", isOn: Binding(
                    get: { prefs.fitAroundAppMenus && accessibility },
                    set: { on in
                        prefs.fitAroundAppMenus = on
                        if on && !accessibility { MenuBarSpace.requestAccess() }
                    }))
                    .disabled(!prefs.fitToMenuBar || prefs.notchStyle == .below)
                if prefs.fitAroundAppMenus && !accessibility {
                    HStack {
                        Note("Needs Accessibility, to see where File, Edit and the rest end. Turn on Claude Notch in System Settings → Privacy & Security → Accessibility.")
                        Button("Check again") { accessibility = MenuBarSpace.hasAccess; prefs.onLayoutChange?() }
                    }
                }
                Toggle("See through the wings when pointing at them", isOn: $prefs.fadeWings)
                Note("Point at a wing (or open any menu) and it fades away, so whatever's under it shows. Clicks always go through to what's underneath.")
            }
            Section("Opening the panel") {
                Picker("Open with", selection: $prefs.openTrigger) {
                    ForEach(OpenTrigger.allCases) { Text($0.title).tag($0) }
                }
                Note("Only the notch itself opens the panel, never the wings. Right-click the notch any time for the menu.")
            }
            Section("Displays") {
                Picker("Show on", selection: $prefs.screenChoice) {
                    ForEach(ScreenChoice.allCases) { Text($0.title).tag($0) }
                }
                .disabled(prefs.allDisplays)
                Toggle("Show on every display", isOn: $prefs.allDisplays)
            }
            Section("Menu bar") {
                Toggle("Show the menu bar icon", isOn: $prefs.showMenuBarIcon)
                Note("Without it, open Settings from the gear in the panel, by right-clicking the notch, with \(GlobalShortcut.settings.display), or by opening Claude Notch again from Applications or Spotlight.")
                Toggle("Fit more icons in the menu bar", isOn: Binding(
                    get: { tightSpacing },
                    set: { StatusItemSpacing.set(tight: $0); tightSpacing = StatusItemSpacing.isTight }))
                Note("Tightens the gap between menu bar icons so fewer hide behind the notch. This is a system-wide setting: icons from other apps tighten up as they restart, or all at once after you log out and back in. Turn it off to put things back.")
            }
        }
        .onAppear { accessibility = MenuBarSpace.hasAccess }
    }

    private var styleNote: String {
        switch prefs.notchStyle {
        case .wings: "On wings beside the notch, in the menu bar. The default, and the most fun."
        case .compact: "Nothing beside the notch except a small badge when someone needs you. Hover the notch to see everyone."
        case .below: "On a strip hanging under the menu bar, which stays completely clear. The strip lets clicks through."
        }
    }
}

// MARK: Alerts

private struct AlertsPane: View {
    @Bindable var prefs: Preferences

    var body: some View {
        Form {
            Section("Sound") {
                Toggle("Play a sound when a session needs you", isOn: $prefs.playSound)
            }
            Section("Quiet") {
                Toggle("Quiet", isOn: $prefs.quietMode)
                Toggle("Quiet whenever a Focus is on", isOn: $prefs.followFocus)
                if prefs.followFocus && FocusStatus.read() == nil {
                    Note("macOS only lets apps with Full Disk Access see whether a Focus is on. Give Claude Notch Full Disk Access in System Settings → Privacy & Security, or use the Quiet switch.")
                }
                Note("Quiet mutes sounds and phone alerts. Flags still go up, so nothing is missed.")
            }
            Section("Budget") {
                Picker("Warn when a session costs more than", selection: $prefs.sessionBudget) {
                    Text("Off").tag(0)
                    ForEach([5, 10, 25, 50, 100], id: \.self) { Text("$\($0)").tag($0) }
                }
                Picker("Warn when running sessions together cost more than", selection: $prefs.totalBudget) {
                    Text("Off").tag(0)
                    ForEach([25, 50, 100, 250, 500], id: \.self) { Text("$\($0)").tag($0) }
                }
                Note("At API list prices (Claude Code only). Over-budget sessions get a $ on their card, and you hear about it once (and on your phone, if phone alerts are on). Nothing is stopped.")
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
                Note("Install the free ntfy app on your phone and subscribe to the same topic. Alerts go only when the screen is locked or you've been away for two minutes, and say which session is waiting and why, never the command. Anyone who knows the topic can read it, so make it long, or use your own server.")
            }
        }
    }
}

// MARK: Rules

private struct RulesPane: View {
    @Bindable var rules: RuleStore
    @Bindable var prefs: Preferences
    @State private var tool = "Bash"
    @State private var pattern = ""
    @State private var action: Rule.Action = .allow
    @State private var showingLog = false

    var body: some View {
        Form {
            Section {
                Note("Rules answer permission prompts before they reach you. A matching Always ask beats Deny, and Deny beats Allow. Patterns match the command, file path or URL: * is anything, ? is one character. Every answer, yours or a rule's, goes in the audit log.")
            }
            Section("Your rules") {
                if rules.rules.isEmpty {
                    Text("No rules yet. Add one below or start from a preset.").foregroundStyle(.secondary)
                }
                ForEach($rules.rules) { $rule in
                    HStack {
                        Toggle("", isOn: $rule.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        RuleActionTag(action: rule.action)
                        Text(rule.tool == "*" ? "Any tool" : rule.tool).font(.body.weight(.medium))
                        Text(rule.pattern).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) {
                            rules.rules.removeAll { $0.id == rule.id }
                        } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("Add a rule") {
                HStack {
                    Picker("", selection: $action) {
                        ForEach(Rule.Action.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    TextField("Tool", text: $tool).frame(width: 100)
                    TextField("Pattern, like npm test* or *.env", text: $pattern)
                        .font(.system(.body, design: .monospaced))
                    Button("Add") {
                        rules.add([Rule(tool: tool.isEmpty ? "*" : tool, pattern: pattern.isEmpty ? "*" : pattern, action: action)])
                        pattern = ""
                    }
                    .disabled(tool.isEmpty && pattern.isEmpty)
                }
                Note("Tool is a name like Bash, Edit, Write, WebFetch or an MCP tool, or * for any tool.")
            }
            Section("Presets") {
                ForEach(PolicyEngine.presets, id: \.title) { preset in
                    HStack {
                        Text(preset.title)
                        Spacer()
                        Button("Add") { rules.add(preset.rules) }
                    }
                }
            }
            Section("Audit log") {
                HStack {
                    Button("Show recent answers") { showingLog = true }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AuditLog.shared.url]) }
                }
            }
            if !prefs.answerPermissions {
                Section {
                    Note("Answering from the notch is off. Rules still apply; prompts no rule decides go straight to Claude's window.")
                }
            }
        }
        .sheet(isPresented: $showingLog) { AuditView { showingLog = false } }
    }
}

private struct RuleActionTag: View {
    let action: Rule.Action
    var body: some View {
        let color: Color = switch action {
        case .allow: .green
        case .deny: .red
        case .ask: .orange
        }
        Text(action.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: .capsule)
    }
}

private struct AuditView: View {
    let done: () -> Void
    @State private var entries: [AuditLog.Entry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent answers").font(.headline)
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
            .padding()
            Table(entries) {
                TableColumn("When") { Text($0.at, style: .time) }.width(70)
                TableColumn("Session") { Text($0.session) }
                TableColumn("Tool") { Text($0.tool) }.width(80)
                TableColumn("Target") { Text($0.target).font(.system(.body, design: .monospaced)).lineLimit(1) }
                TableColumn("Answer") { Text($0.decision) }.width(80)
                TableColumn("By") { Text($0.by) }
            }
        }
        .frame(width: 760, height: 420)
        .task { entries = await Task.detached { AuditLog.shared.recent() }.value }
    }
}

extension AuditLog.Entry: Identifiable {
    var id: String { "\(at.timeIntervalSince1970)-\(session)-\(target)-\(decision)" }
}

// MARK: Terminals

private struct TerminalsPane: View {
    @State private var findings: [TerminalFinding] = []

    var body: some View {
        Form {
            Section("Terminals") {
                if findings.isEmpty {
                    Label("Every terminal here can jump straight to a session's tab.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                ForEach(findings) { finding in
                    VStack(alignment: .leading, spacing: 4) {
                        Label {
                            Text(finding.app).font(.headline)
                        } icon: {
                            Image(systemName: finding.severity == .fix ? "exclamationmark.triangle.fill" : "info.circle.fill")
                                .foregroundStyle(finding.severity == .fix ? .orange : .secondary)
                        }
                        Text(finding.problem)
                        Text(finding.fix).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if let file = finding.file {
                            Button("Open \(file.lastPathComponent)") {
                                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                                if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
                                NSWorkspace.shared.open(file)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                Button("Check again") { findings = TerminalChecks.run() }
            }
            Section("Reply and Stop") {
                Note("Sessions running in tmux or iTerm can take a reply typed from their card, and Stop (Esc) from the notch. Others jump to their window instead.")
            }
            if !EditorHelper.installedEditors.isEmpty {
                Section("Editor terminals") {
                    ForEach(EditorHelper.installedEditors) { EditorHelperRow(editor: $0) }
                    Note("Sessions in an editor's built-in terminal jump to that exact terminal once a tiny helper extension is installed (it only answers Claude Notch's jump links). The first jump may ask you to allow the link.")
                }
            }
        }
        .onAppear { findings = TerminalChecks.run() }
    }
}

/// One editor's terminal-focus helper: installed, or a button to install it.
private struct EditorHelperRow: View {
    let editor: EditorHelper.Editor
    @State private var installed = false
    @State private var working = false
    @State private var failed = false

    var body: some View {
        LabeledContent(editor.name) {
            if installed {
                Label("Terminal focus on", systemImage: "checkmark").foregroundStyle(.secondary)
            } else if working {
                ProgressView().controlSize(.small)
            } else {
                Button(failed ? "Try again" : "Set up terminal focus") {
                    working = true
                    Task {
                        failed = !(await EditorHelper.install(editor))
                        installed = EditorHelper.hasHelper(editor)
                        working = false
                    }
                }
            }
        }
        .onAppear { installed = EditorHelper.hasHelper(editor) }
    }
}

// MARK: Agents

private struct AgentsPane: View {
    var hooks: HookStatus

    var body: some View {
        Form {
            Section("Claude Code") {
                LabeledContent("Hooks") {
                    StatusText(ok: hooks.installed, text: hooks.installed ? "Installed" : hooks.partlyInstalled ? "Outdated" : "Not installed")
                }
                if hooks.installed {
                    Button("Remove hooks") { hooks.set(installed: false) }
                } else {
                    Button(hooks.partlyInstalled ? "Update hooks" : "Install hooks") { hooks.set(installed: true) }
                        .buttonStyle(.borderedProminent)
                }
                Note("The hooks only talk to this app, on your Mac. If it isn't running, Claude carries on as usual. Your ~/.claude/settings.json was backed up next to it before the first change.")
            }
            Section("Hook server") {
                LabeledContent("Status") { StatusText(ok: hooks.serverOK, text: hooks.server) }
                if let problem = hooks.problem { Text(problem).foregroundStyle(.red) }
                Button("Restart server") { AppDelegate.restartServer() }
            }
            if HookInstaller.codexAvailable {
                Section("Codex") {
                    LabeledContent("Hooks") { StatusText(ok: hooks.codexInstalled, text: hooks.codexInstalled ? "Installed" : "Not installed") }
                    if hooks.codexInstalled {
                        Button("Remove Codex hooks") { hooks.setCodex(installed: false) }
                    } else {
                        Button("Install Codex hooks") { hooks.setCodex(installed: true) }
                    }
                    Note("Codex runs new hooks only after you approve them: type /hooks in Codex and trust them. Codex sessions show as teal Claudes; Always and question answers are Claude Code only.")
                }
            }
        }
    }
}

private struct StatusText: View {
    let ok: Bool
    let text: String
    var body: some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .foregroundStyle(ok ? .green : .orange)
    }
}

// MARK: About

private struct AboutPane: View {
    @Bindable var prefs: Preferences
    var updater: Updater

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Canvas { context, size in
                        Sprite.draw(.wave(frame: 0, color: Sprite.turnFlag, pennant: true), in: context,
                                    foot: CGPoint(x: size.width / 2 - 10, y: size.height - 4), pixel: 3)
                    }
                    .frame(width: 64, height: 54)
                    .background(.black, in: .rect(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Claude Notch").font(.title3.bold())
                        Text("Version \(Updater.currentVersion)").foregroundStyle(.secondary)
                    }
                }
            }
            Section("Updates") {
                Toggle("Check for updates every day", isOn: $prefs.checkForUpdates)
                HStack {
                    if let release = updater.available {
                        Label("Version \(release.version) is available", systemImage: "arrow.down.circle.fill")
                            .foregroundStyle(.blue)
                        Spacer()
                        Button(Updater.canInstall ? "Install and relaunch" : "Download") {
                            Task { await updater.install() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(updater.status == .downloading || updater.status == .installing)
                    } else {
                        Text(statusText).foregroundStyle(.secondary)
                        Spacer()
                        Button("Check now") { Task { await updater.check() } }
                            .disabled(updater.status == .checking)
                    }
                }
                Note("Asks GitHub for the latest release, and nothing else. Updates are checked before they're installed, and the old copy goes to the Trash.")
            }
            Section("Troubleshooting") {
                HStack {
                    Button("Copy diagnostics") { Diagnostics.copy() }
                    Button("Show data folder") { NSWorkspace.shared.open(AppFolder.url) }
                }
                Note("Diagnostics are versions, settings, the hook server's state and the app's recent log: no commands, prompts or file contents.")
            }
        }
    }

    private var statusText: String {
        switch updater.status {
        case .checking: "Checking…"
        case .upToDate: "You're up to date"
        case .downloading: "Downloading…"
        case .installing: "Installing…"
        case .failed(let reason): reason
        case .idle: ""
        }
    }
}
