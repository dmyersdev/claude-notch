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
    private let prefs = Preferences.shared
    private let visibility = NotchVisibility.shared
    private(set) var metrics: NotchMetrics
    private var hoverTimer: Timer?
    private var hoverStart: Date?
    private var leaveStart: Date?
    private var keyMonitor: Any?
    private var mouseMonitors: [Any] = []
    private var wingTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    /// After Esc, stay closed until the pointer leaves, so it doesn't spring straight back open.
    private var closedByKey = false
    /// The screen this notch is on, for matching it up when displays change.
    let screenID: CGDirectDisplayID?

    /// One notch on one screen; the app makes a controller per display it shows on.
    init(store: AgentStore, metrics: NotchMetrics, screenID: CGDirectDisplayID? = nil) {
        self.store = store
        self.metrics = metrics
        self.screenID = screenID
        state.leftWing = metrics.wingWidth
        state.rightWing = metrics.wingWidth
        let host = NotchHostingView(rootView: NotchView(metrics: metrics, store: store, state: state))
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrame(metrics.panelFrame, display: true)
        panel.orderFrontRegardless()
        panel.onBecameKey = { [weak self] in
            guard let self else { return }
            state.keyboardActive = true
            if state.selectedID == nil { state.selectedID = PanelKeyboard.order(store, state: state).first }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let key = PanelKey(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                               command: event.modifierFlags.contains(.command))
            // Local monitors run on the main thread.
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.panel.isKeyWindow, let key else { return false }
                return self.handle(key)
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
        // Clicks on the notch itself land on the empty menu bar behind it, so they're seen from outside.
        if let clicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            let right = event.type == .rightMouseDown
            MainActor.assumeIsolated { self?.clicked(right: right) }
        }) {
            mouseMonitors.append(clicks)
        }
        if let rightClick = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown, handler: { [weak self] event in
            let window = event.windowNumber
            let ours = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.state.isOpen, window == self.panel.windowNumber else { return false }
                NotchMenu.show()
                return true
            }
            return ours ? nil : event
        }) {
            mouseMonitors.append(rightClick)
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWings() }
        }
        // Status icons come and go; a cheap look every few seconds keeps the wings off them.
        wingTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWings() }
        }
        refreshWings()
        pointerMoved()
    }

    // MARK: Keys

    private func handle(_ key: PanelKey) -> Bool {
        // Something is being typed (a search, a reply, a reason to deny): letters belong to the field.
        let typing = panel.firstResponder is NSTextView
        switch key {
        case .close:
            if state.query != nil {
                state.query = nil
            } else if typing {
                panel.makeFirstResponder(nil)
            } else {
                closedByKey = true
                setOpen(false)
            }
            return true
        case .search:
            if typing && !state.editingSearch { return false }
            if state.query == nil { state.query = "" }
            return true
        case .settings:
            SettingsWindow.shared.show()
            return true
        case .up, .down:
            if typing && !state.editingSearch { return false }
            return PanelKeyboard.perform(key, state: state, store: store)
        default:
            if typing { return false }
            return PanelKeyboard.perform(key, state: state, store: store)
        }
    }

    // MARK: Fitting the wings

    /// Sizes each wing to the free menu bar beside the notch, off the main thread (it asks the window server,
    /// and maybe the frontmost app, where things are).
    func refreshWings() {
        let metrics = metrics, prefs = prefs
        let screen = panel.screen ?? NSScreen.screens.first { $0.frame.intersects(panel.frame) }
        guard let screen else { return }
        let frame = screen.frame
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.height
        let mid = frame.midX
        let core = (mid - metrics.coreWidth / 2)...(mid + metrics.coreWidth / 2)
        let fit = prefs.fitToMenuBar && metrics.style != .below
        let menusOf = prefs.fitAroundAppMenus ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil
        let style = metrics.style, sides = prefs.wingSides
        let badge = WaitingBadge.reserve + 22
        Task.detached { [weak self] in
            let occupied = fit ? MenuBarSpace.read(screenFrame: frame, primaryHeight: primaryHeight, notchMid: mid,
                                                   appMenusOf: menusOf) : nil
            var wings = WingFit.fit(preferred: metrics.wingWidth, core: core, screen: frame.minX...frame.maxX,
                                    occupied: occupied, sides: sides, style: style)
            if style == .compact {
                // Just room for the badge, on the right if it fits there.
                let right = WingFit.fit(preferred: badge, core: core, screen: frame.minX...frame.maxX,
                                        occupied: occupied, sides: .right, style: .wings).right
                wings = right > 0 ? (0, right)
                    : (WingFit.fit(preferred: badge, core: core, screen: frame.minX...frame.maxX,
                                   occupied: occupied, sides: .left, style: .wings).left, 0)
                if wings.left == 0 && wings.right == 0 { wings = (0, badge) }
            }
            await MainActor.run {
                guard let self else { return }
                if self.state.leftWing != wings.left { self.state.leftWing = wings.left }
                if self.state.rightWing != wings.right { self.state.rightWing = wings.right }
            }
        }
    }

    // MARK: The pointer

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
        if state.wingsFaded { state.wingsFaded = false }
    }

    func close() {
        hoverTimer?.invalidate()
        wingTimer?.invalidate()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        mouseMonitors.forEach(NSEvent.removeMonitor)
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        panel.orderOut(nil)
    }

    func setOpen(_ open: Bool) {
        guard state.isOpen != open else { return }
        if open && visibility.isHidden { return }
        state.isOpen = open
        panel.ignoresMouseEvents = !open
        panel.acceptsKeys = open
        if open {
            if state.wingsFaded { state.wingsFaded = false }
        } else {
            // Hand the keyboard straight back to whatever had it.
            if panel.isKeyWindow { panel.resignKey() }
            state.keyboardActive = false
            state.selectedID = nil
            state.query = nil
        }
    }

    /// The notch itself (with its flares), in screen coordinates: the only part that opens the panel.
    private var coreRect: CGRect {
        let frame = panel.frame
        return CGRect(x: frame.midX - metrics.coreWidth / 2, y: frame.maxY - metrics.notchHeight,
                      width: metrics.coreWidth, height: metrics.notchHeight)
    }

    /// The closed shape as drawn now, wings and all.
    private var closedRect: CGRect {
        let expanded = metrics.style == .compact ? store.present.contains(where: \.needsAttention) : !store.present.isEmpty
        let left = expanded ? state.leftWing : 0, right = expanded ? state.rightWing : 0
        let size = metrics.closedSize(left: left, right: right)
        let frame = panel.frame
        return CGRect(x: frame.midX - metrics.coreWidth / 2 - left, y: frame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    private func clicked(right: Bool) {
        guard !state.isOpen, !visibility.isHidden else { return }
        let pointer = NSEvent.mouseLocation
        guard coreRect.insetBy(dx: 0, dy: -2).contains(pointer) else { return }
        if right {
            NotchMenu.show()
        } else if prefs.openTrigger == .click {
            closedByKey = false
            setOpen(true)
        }
    }

    private func trackPointer() {
        let pointer = NSEvent.mouseLocation
        let now = Date()
        if visibility.isHidden && !state.isOpen {
            stopTracking()
            return
        }
        if state.isOpen {
            // A little slack so brushing the edge doesn't snap it shut.
            let size = metrics.openSize(state.layout(store))
            let frame = panel.frame
            let open = CGRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height,
                              width: size.width, height: size.height).insetBy(dx: -8, dy: -8)
            // Typing a search or a reason: don't snatch the panel away because the pointer wandered off.
            let busy = state.query != nil && panel.isKeyWindow
            if open.contains(pointer) || busy || NSApp.modalWindow != nil || panel.attachedSheet != nil
                || NSApp.windows.contains(where: { $0.isVisible && $0 !== panel && $0.parent === panel }) {
                leaveStart = nil
            } else if let leaveStart, now.timeIntervalSince(leaveStart) > 0.3 {
                setOpen(false)
                self.leaveStart = nil
            } else if leaveStart == nil {
                leaveStart = now
            }
            return
        }
        let shape = closedRect
        state.pointer = CGPoint(x: pointer.x - shape.minX, y: shape.maxY - pointer.y)
        let near = shape.insetBy(dx: -8, dy: -40).contains(pointer)
        if state.pointerNear != near { state.pointerNear = near }
        let core = coreRect.insetBy(dx: 0, dy: -2)
        let inCore = core.contains(pointer)
        // Over a wing, not the notch: let what's under it show through.
        let overWing = shape.contains(pointer) && !inCore
        if state.wingsFaded != overWing { state.wingsFaded = overWing }
        // Moved well away and nothing pending: stop polling until it comes back.
        if !panel.frame.insetBy(dx: -Self.nearMargin, dy: -Self.nearMargin).contains(pointer), hoverStart == nil {
            stopTracking()
            return
        }
        let wantsOpen: Bool
        let dwell: TimeInterval
        switch prefs.openTrigger {
        case .hover: (wantsOpen, dwell) = (inCore, 0.12)
        // Pushed right up against the top of the screen.
        case .push: (wantsOpen, dwell) = (inCore && pointer.y >= panel.frame.maxY - 1.5, 0.05)
        case .option: (wantsOpen, dwell) = (inCore && NSEvent.modifierFlags.contains(.option), 0.05)
        case .click: (wantsOpen, dwell) = (false, 0)
        }
        if inCore, closedByKey {
            hoverStart = nil
        } else if wantsOpen {
            if let hoverStart, now.timeIntervalSince(hoverStart) > dwell {
                setOpen(true)
                self.hoverStart = nil
            } else if hoverStart == nil {
                hoverStart = now
            }
        } else {
            hoverStart = nil
            if !inCore { closedByKey = false }
        }
    }
}
