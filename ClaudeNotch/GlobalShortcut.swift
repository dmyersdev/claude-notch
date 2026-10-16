import Carbon.HIToolbox

/// A system-wide keyboard shortcut through Carbon's hot keys, which need no Accessibility permission.
@MainActor enum GlobalShortcut {
    /// ⌃⌥J
    static let display = "⌃⌥J"
    private static var action: (() -> Void)?
    private static var hotKey: EventHotKeyRef?

    static func register(_ action: @escaping () -> Void) {
        self.action = action
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            // Carbon delivers hot keys on the main thread.
            MainActor.assumeIsolated { GlobalShortcut.action?() }
            return noErr
        }, 1, &pressed, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4E43_4C44), id: 1) // "NCLD"
        RegisterEventHotKey(UInt32(kVK_ANSI_J), UInt32(controlKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &hotKey)
    }
}
