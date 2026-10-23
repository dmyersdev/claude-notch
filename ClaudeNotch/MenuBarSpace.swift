import AppKit
import ApplicationServices

/// What's already in the menu bar either side of the notch, in screen x coordinates.
struct MenuBarOccupancy: Equatable, Sendable {
    /// The right edge of the last thing left of the notch (the frontmost app's menus).
    var leftEdge: CGFloat?
    /// The left edge of the first thing right of the notch (status icons, or app menus pushed past the notch).
    var rightEdge: CGFloat?
}

/// How wide each wing of the closed notch can be. Pure, so it's tested.
enum WingFit {
    /// Kept clear between a wing and the nearest menu bar item.
    static let gap: CGFloat = 8
    /// A wing narrower than this has no room for a Claude, so it goes.
    static let minimum: CGFloat = 44
    /// A single wing may be this much wider than the preferred width, to fit everyone on one side.
    static let singleSideStretch: CGFloat = 1.5

    /// `core` is the notch shape without wings, `screen` the screen's x range; `occupied` is nil when we don't
    /// look at the menu bar (wings get the preferred width).
    static func fit(preferred: CGFloat, core: ClosedRange<CGFloat>, screen: ClosedRange<CGFloat>,
                    occupied: MenuBarOccupancy?, sides: WingSides, style: NotchStyle) -> (left: CGFloat, right: CGFloat) {
        if style == .compact { return (0, 0) }
        // Under the menu bar there's nothing to cover, so there's no fitting to do.
        let occupied = style == .below ? nil : occupied
        let leftFree = core.lowerBound - max(screen.lowerBound, occupied?.leftEdge.map { $0 + gap } ?? screen.lowerBound)
        let rightFree = min(screen.upperBound, occupied?.rightEdge.map { $0 - gap } ?? screen.upperBound) - core.upperBound
        func wing(_ free: CGFloat, _ want: CGFloat) -> CGFloat {
            let width = min(want, max(0, free))
            return width >= minimum ? width.rounded(.down) : 0
        }
        switch sides {
        case .both: return (wing(leftFree, preferred), wing(rightFree, preferred))
        case .left: return (wing(leftFree, preferred * singleSideStretch), 0)
        case .right: return (0, wing(rightFree, preferred * singleSideStretch))
        }
    }
}

/// Reads where the menu bar's contents are. Status icons come from the window list, which needs no permission;
/// the frontmost app's menus need Accessibility, so they're read only when that's allowed and asked for.
enum MenuBarSpace {
    /// The status item window level (`kCGStatusWindowLevel`).
    static let statusLayer = 25

    /// `screenFrame` in AppKit coordinates; `primaryHeight` is the height of the screen with the menu bar's origin,
    /// for turning AppKit's bottom-left origin into the window server's top-left one.
    static func read(screenFrame: CGRect, primaryHeight: CGFloat, notchMid: CGFloat, appMenusOf pid: pid_t?,
                     ownPID: pid_t = ProcessInfo.processInfo.processIdentifier) -> MenuBarOccupancy {
        let top = primaryHeight - screenFrame.maxY
        var frames: [CGRect] = []
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for window in list {
            guard window[kCGWindowLayer as String] as? Int == statusLayer,
                  (window[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { continue }
            frames.append(rect)
        }
        if let pid { frames += appMenuFrames(pid: pid) }
        return occupancy(of: frames, top: top, screenX: screenFrame.minX...screenFrame.maxX, notchMid: notchMid)
    }

    /// Only frames in this screen's menu bar strip count.
    static func occupancy(of frames: [CGRect], top: CGFloat, screenX: ClosedRange<CGFloat>, notchMid: CGFloat)
        -> MenuBarOccupancy {
        let inBar = frames.filter { abs($0.minY - top) < 6 && $0.width > 0 && screenX.contains($0.midX) }
        return MenuBarOccupancy(leftEdge: inBar.filter { $0.midX < notchMid }.map(\.maxX).max(),
                                rightEdge: inBar.filter { $0.midX >= notchMid }.map(\.minX).min())
    }

    /// The frames of an app's menu bar titles, through Accessibility. Empty without permission.
    static func appMenuFrames(pid: pid_t) -> [CGRect] {
        guard AXIsProcessTrusted() else { return [] }
        let app = AXUIElementCreateApplication(pid)
        // An app that's hung shouldn't hang us.
        AXUIElementSetMessagingTimeout(app, 0.25)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success,
              let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return [] }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
              let items = children as? [AXUIElement] else { return [] }
        return items.compactMap(frame)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    /// Asks for Accessibility (System Settings opens with the app listed).
    static func requestAccess() {
        // The value of kAXTrustedCheckOptionPrompt, spelled out (the global isn't concurrency-safe to read).
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static var hasAccess: Bool { AXIsProcessTrusted() }
}

/// Makes room for more menu bar icons by tightening the spacing between them, so fewer hide behind the notch.
/// These are the system's own (undocumented but long-standing) preferences; apps pick them up when they relaunch,
/// so the change shows fully after logging out and back in.
enum StatusItemSpacing {
    static let spacingName = "NSStatusItemSpacing"
    static let paddingName = "NSStatusItemSelectionPadding"
    static var spacingKey: CFString { spacingName as CFString }
    static var paddingKey: CFString { paddingName as CFString }
    static let tightSpacing = 6
    static let tightPadding = 4

    static var isTight: Bool {
        CFPreferencesCopyValue(spacingKey, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                               kCFPreferencesCurrentHost) != nil
    }

    static func set(tight: Bool) {
        let spacing: CFPropertyList? = tight ? tightSpacing as CFNumber : nil
        let padding: CFPropertyList? = tight ? tightPadding as CFNumber : nil
        CFPreferencesSetValue(spacingKey, spacing, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                              kCFPreferencesCurrentHost)
        CFPreferencesSetValue(paddingKey, padding, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                              kCFPreferencesCurrentHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        // The menu bar's own items redraw once their owners restart; ControlCenter and SystemUIServer come straight back.
        for name in ["ControlCenter", "SystemUIServer"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            process.arguments = [name]
            try? process.run()
        }
    }
}
