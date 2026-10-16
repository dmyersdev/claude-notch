import AppKit
import SwiftUI

/// Borderless, non-activating panel that floats over the notch on every Space, even over full-screen apps.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        // Clicks pass through until the notch opens.
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Borderless windows still get pushed below the menu bar unless we opt out.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The panel never becomes key, so buttons must take the very first click.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class NotchController {
    private let panel = NotchPanel()
    private let store: AgentStore
    private let state = NotchState()
    private var metrics: NotchMetrics
    private var hoverTimer: Timer?
    private var hoverStart: Date?
    private var leaveStart: Date?

    /// One notch on one screen; the app makes a controller per display it shows on.
    init(store: AgentStore, metrics: NotchMetrics) {
        self.store = store
        self.metrics = metrics
        let host = NotchHostingView(rootView: NotchView(metrics: metrics, store: store, state: state))
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrame(metrics.panelFrame, display: true)
        panel.orderFrontRegardless()
        // The panel ignores the mouse while closed, so tracking areas can't see the pointer: poll it.
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackPointer() }
        }
    }

    func close() {
        hoverTimer?.invalidate()
        panel.orderOut(nil)
    }

    func setOpen(_ open: Bool) {
        guard state.isOpen != open else { return }
        state.isOpen = open
        panel.ignoresMouseEvents = !open
    }

    private func trackPointer() {
        let pointer = NSEvent.mouseLocation
        let now = Date()
        if state.isOpen {
            // A little slack so brushing the edge doesn't snap it shut.
            let open = screenRect(for: metrics.openSize(PanelLayout(agents: store.present, away: store.away.count))).insetBy(dx: -8, dy: -8)
            if open.contains(pointer) {
                leaveStart = nil
            } else if let leaveStart, now.timeIntervalSince(leaveStart) > 0.3 {
                setOpen(false)
                self.leaveStart = nil
            } else if leaveStart == nil {
                leaveStart = now
            }
        } else {
            let collapsed = metrics.shapeSize(expanded: !store.present.isEmpty)
            let shape = screenRect(for: collapsed)
            state.pointer = CGPoint(x: pointer.x - shape.minX, y: shape.maxY - pointer.y)
            // Reach to the very top edge too: pushing the pointer into the notch should open it.
            let hot = shape.insetBy(dx: 0, dy: -2)
            if hot.contains(pointer) {
                if let hoverStart, now.timeIntervalSince(hoverStart) > 0.12 {
                    setOpen(true)
                    self.hoverStart = nil
                } else if hoverStart == nil {
                    hoverStart = now
                }
            } else {
                hoverStart = nil
            }
        }
    }

    /// The black shape is pinned to the top centre of the panel.
    private func screenRect(for size: CGSize) -> CGRect {
        let frame = panel.frame
        return CGRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height,
                      width: size.width, height: size.height)
    }
}
