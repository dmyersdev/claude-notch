import Carbon.HIToolbox

/// System-wide keyboard shortcuts through Carbon's hot keys, which need no Accessibility permission.
@MainActor struct GlobalShortcut {
    let id: UInt32
    let keyCode: Int
    let display: String

    /// ⌃⌥J: jump to whoever has waited longest.
    static let jump = GlobalShortcut(id: 1, keyCode: kVK_ANSI_J, display: "⌃⌥J")
    /// ⌃⌥,: Settings, for when the menu bar icon is hidden.
    static let settings = GlobalShortcut(id: 2, keyCode: kVK_ANSI_Comma, display: "⌃⌥,")
    /// ⌃⌥H: hide the notch for ten minutes, or bring it back.
    static let hide = GlobalShortcut(id: 3, keyCode: kVK_ANSI_H, display: "⌃⌥H")

    /// Kept for the menu's label.
    static var display: String { jump.display }

    private static var actions: [UInt32: () -> Void] = [:]
    private static var refs: [EventHotKeyRef?] = []
    private static var handlerInstalled = false

    static func register(_ shortcuts: [(GlobalShortcut, () -> Void)]) {
        if !handlerInstalled {
            handlerInstalled = true
            var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                // Carbon delivers hot keys on the main thread.
                MainActor.assumeIsolated { GlobalShortcut.actions[id.id]?() }
                return noErr
            }, 1, &pressed, nil, nil)
        }
        for (shortcut, action) in shortcuts {
            actions[shortcut.id] = action
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4E43_4C44), id: shortcut.id) // "NCLD"
            RegisterEventHotKey(UInt32(shortcut.keyCode), UInt32(controlKey | optionKey), id,
                                GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
        }
    }
}
