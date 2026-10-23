import AppKit
import SwiftUI

/// The notch's own menu, on a right-click: everything the menu bar icon offers, for when that icon is hidden
/// (by you, or by macOS behind the notch).
@MainActor
enum NotchMenu {
    static func show(at point: NSPoint = NSEvent.mouseLocation) {
        make().popUp(positioning: nil, at: point, in: nil)
    }

    static func make() -> NSMenu {
        let menu = NSMenu()
        let store = AgentStore.shared, prefs = Preferences.shared, visibility = NotchVisibility.shared
        let hooks = HookStatus.shared
        if !hooks.installed {
            menu.addItem(ActionItem(hooks.partlyInstalled ? "Update Claude Code hooks" : "Install Claude Code hooks") {
                hooks.set(installed: true)
            })
            menu.addItem(.separator())
        }
        menu.addItem(ActionItem("Jump to waiting session", key: "j", modifiers: [.control, .option],
                                enabled: store.anyNeedsAttention) { AppDelegate.jumpToWaiting() })
        menu.addItem(ActionItem(visibility.isHidden ? "Show the notch" : "Hide the notch for 10 minutes",
                                key: "h", modifiers: [.control, .option]) { visibility.toggle() })
        menu.addItem(ActionItem("Quiet", checked: prefs.quietMode) { prefs.quietMode.toggle() })
        if let release = Updater.shared.available {
            menu.addItem(.separator())
            menu.addItem(ActionItem("Update to \(release.version)…") { Task { await Updater.shared.install() } })
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("Demo mode", checked: store.autoDemo) { store.autoDemo.toggle() })
        menu.addItem(ActionItem("Settings…", key: ",", modifiers: [.control, .option]) { SettingsWindow.shared.show() })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Quit Claude Notch") { NSApp.terminate(nil) })
        return menu
    }
}

/// A menu item that runs a closure.
@MainActor final class ActionItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [], checked: Bool = false,
         enabled: Bool = true, action: @escaping @MainActor () -> Void) {
        handler = action
        super.init(title: title, action: enabled ? #selector(run) : nil, keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
        state = checked ? .on : .off
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

/// Settings in a window of our own, so it opens from anywhere (the notch, a shortcut, a link, reopening the app)
/// without the menu bar icon.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private let navigation = SettingsNavigation()

    func show(_ pane: SettingsPane? = nil) {
        if let pane { navigation.pane = pane }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Claude Notch Settings"
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 640, height: 460)
            window.contentView = NSHostingView(rootView: SettingsView(prefs: .shared, hooks: .shared, navigation: navigation))
            window.center()
            window.setFrameAutosaveName("Settings")
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
