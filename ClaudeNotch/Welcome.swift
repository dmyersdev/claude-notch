import AppKit
import SwiftUI

/// Shown once on first launch: what the app needs from Claude Code, and a choice to set it up.
@MainActor
final class WelcomeWindow {
    private static let shownKey = "didShowWelcome"
    private var window: NSWindow?

    /// Opens the welcome screen unless it has been seen before or the hooks are already in place.
    func showIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: Self.shownKey), !HookStatus.shared.installed else { return }
        defaults.set(true, forKey: Self.shownKey)
        show()
    }

    func show() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Welcome to Claude Notch"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WelcomeView(hooks: HookStatus.shared) { [weak self] in
            self?.window?.close()
        })
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

struct WelcomeView: View {
    var hooks: HookStatus
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Canvas { context, size in
                    Sprite.draw(.wave(frame: 0, color: Sprite.turnFlag, pennant: true), in: context,
                                foot: CGPoint(x: size.width / 2 - 12, y: size.height - 4), pixel: 4)
                }
                .frame(width: 84, height: 70)
                .background(.black, in: .rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Claude Notch").font(.title2.bold())
                    Text("A little Claude in your notch for every Claude Code session.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("To follow your sessions, Claude Notch adds hooks to your Claude Code settings:")
                Label("The hooks only talk to this app, on your Mac (127.0.0.1). If it isn't running, Claude carries on as usual.",
                      systemImage: "arrow.left.arrow.right")
                Label("Your current ~/.claude/settings.json is backed up next to it first.",
                      systemImage: "doc.on.doc")
                Label("You can remove them any time from the menu bar or Settings.",
                      systemImage: "arrow.uturn.backward")
                Label("Sessions that are already open show up too, but only new ones report everything.",
                      systemImage: "info.circle")
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            if let problem = hooks.problem {
                Text(problem).foregroundStyle(.red).font(.callout)
            }

            HStack {
                Text("The icon lives in your menu bar.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Not now", action: done)
                Button("Install hooks") {
                    hooks.set(installed: true)
                    if hooks.installed { done() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}
