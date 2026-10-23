import AppKit
import OSLog

/// Everything useful in a bug report, in one paste: versions, the hook server, hook status, settings, terminal
/// checks, and the app's recent log. Never includes commands, prompts or file contents.
enum Diagnostics {
    @MainActor static func copy() {
        let header = summary()
        Task.detached {
            let text = header + "\n\nRecent log:\n" + recentLog()
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                AgentStore.shared.post("Diagnostics copied")
            }
        }
    }

    @MainActor static func summary() -> String {
        let prefs = Preferences.shared, hooks = HookStatus.shared, store = AgentStore.shared
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let portFile = (try? String(contentsOf: HookServer.portFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "missing"
        let screens = NSScreen.screens.map { screen in
            "\(Int(screen.frame.width))×\(Int(screen.frame.height))" + (screen.safeAreaInsets.top > 0 ? " (notch)" : "")
        }
        var lines = [
            "Claude Notch \(Updater.currentVersion) (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))",
            "macOS \(os)",
            "Hook server: \(hooks.server)",
            "Port file: \(portFile)",
            "Claude Code hooks: \(hooks.installed ? "installed" : hooks.partlyInstalled ? "outdated" : "not installed")",
            "Codex hooks: \(hooks.codexInstalled ? "installed" : "not installed")",
            "Sessions: \(store.present.count) shown, \(store.away.count) away",
            "Screens: \(screens.joined(separator: ", "))",
            "Notch: \(prefs.notchStyle.rawValue), sides \(prefs.wingSides.rawValue), fit \(prefs.fitToMenuBar), "
                + "app menus \(prefs.fitAroundAppMenus) (accessibility \(MenuBarSpace.hasAccess)), open by \(prefs.openTrigger.rawValue)",
            "Answer from notch: \(prefs.answerPermissions), rules: \(RuleStore.shared.rules.filter(\.enabled).count)",
            "Quiet: \(prefs.isQuiet), menu bar icon: \(prefs.showMenuBarIcon)",
        ]
        if let problem = hooks.problem { lines.append("Problem: \(problem)") }
        for finding in TerminalChecks.run() { lines.append("Terminal: \(finding.app): \(finding.problem)") }
        return lines.joined(separator: "\n")
    }

    /// The last hour of this process's log lines (our own subsystem only).
    static func recentLog(limit: Int = 200) -> String {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return "(unavailable)" }
        let since = store.position(date: Date().addingTimeInterval(-3600))
        let predicate = NSPredicate(format: "subsystem == %@", "com.dmyersdev.claudenotch")
        let entries = (try? store.getEntries(at: since, matching: predicate)) ?? AnySequence([])
        let formatter = ISO8601DateFormatter()
        let lines = entries.compactMap { $0 as? OSLogEntryLog }.map { "\(formatter.string(from: $0.date)) \($0.composedMessage)" }
        return lines.suffix(limit).joined(separator: "\n")
    }
}
