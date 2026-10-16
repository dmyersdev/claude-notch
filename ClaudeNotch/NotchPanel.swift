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

    /// Only while open, and only once clicked: hovering must never steal the keyboard from whatever you're typing in.
    var acceptsKeys = false
    var onBecameKey: (() -> Void)?

    override var canBecomeKey: Bool { acceptsKeys }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, acceptsKeys, !isKeyWindow {
            makeKey()
            onBecameKey?()
        }
        super.sendEvent(event)
    }

    /// Borderless windows still get pushed below the menu bar unless we opt out.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Buttons take the very first click, whether or not the panel is key yet.
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
    private var keyMonitor: Any?
    private var mouseMonitors: [Any] = []
    /// After Esc, stay closed until the pointer leaves, so it doesn't spring straight back open.
    private var closedByKey = false

    /// One notch on one screen; the app makes a controller per display it shows on.
    init(store: AgentStore, metrics: NotchMetrics) {
        self.store = store
        self.metrics = metrics
        let host = NotchHostingView(rootView: NotchView(metrics: metrics, store: store, state: state))
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrame(metrics.panelFrame, display: true)
        panel.orderFrontRegardless()
        panel.onBecameKey = { [weak self] in
            guard let self else { return }
            state.keyboardActive = true
            if state.selectedID == nil { state.selectedID = PanelKeyboard.order(store).first }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let key = PanelKey(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers)
            // Local monitors run on the main thread.
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.panel.isKeyWindow, let key else { return false }
                if key == .close {
                    self.closedByKey = true
                    self.setOpen(false)
                    return true
                }
                return PanelKeyboard.perform(key, state: self.state, store: self.store)
            }
            return handled ? nil : event
        }
        // The panel ignores the mouse while closed, so tracking areas can't see the pointer. Watching mouse
        // movement (no permission needed) and only polling while it's near the notch keeps idle wakeups near zero.
        let moved: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: moved) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { event in
            moved(event)
            return event
        }) {
            mouseMonitors.append(local)
        }
        pointerMoved()
    }

    /// Within this much of the notch's shape, track the pointer closely (hover-to-open, name tags, glances).
    private static let nearMargin: CGFloat = 60

    private func pointerMoved() {
        let near = panel.frame.insetBy(dx: -Self.nearMargin, dy: -Self.nearMargin).contains(NSEvent.mouseLocation)
        if near || state.isOpen {
            if hoverTimer == nil {
                hoverTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.trackPointer() }
                }
            }
        } else {
            stopTracking()
        }
    }

    private func stopTracking() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        hoverStart = nil
        state.pointer = nil
        if state.pointerNear { state.pointerNear = false }
    }

    func close() {
        hoverTimer?.invalidate()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        mouseMonitors.forEach(NSEvent.removeMonitor)
        panel.orderOut(nil)
    }

    func setOpen(_ open: Bool) {
        guard state.isOpen != open else { return }
        state.isOpen = open
        panel.ignoresMouseEvents = !open
        panel.acceptsKeys = open
        if !open {
            // Hand the keyboard straight back to whatever had it.
            if panel.isKeyWindow { panel.resignKey() }
            state.keyboardActive = false
            state.selectedID = nil
        }
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
            let near = shape.insetBy(dx: -8, dy: -40).contains(pointer)
            if state.pointerNear != near { state.pointerNear = near }
            // Moved well away and nothing pending: stop polling until it comes back.
            if !panel.frame.insetBy(dx: -Self.nearMargin, dy: -Self.nearMargin).contains(pointer), hoverStart == nil {
                stopTracking()
                return
            }
            // Reach to the very top edge too: pushing the pointer into the notch should open it.
            let hot = shape.insetBy(dx: 0, dy: -2)
            if hot.contains(pointer), closedByKey {
                hoverStart = nil
            } else if hot.contains(pointer) {
                if let hoverStart, now.timeIntervalSince(hoverStart) > 0.12 {
                    setOpen(true)
                    self.hoverStart = nil
                } else if hoverStart == nil {
                    hoverStart = now
                }
            } else {
                hoverStart = nil
                closedByKey = false
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
