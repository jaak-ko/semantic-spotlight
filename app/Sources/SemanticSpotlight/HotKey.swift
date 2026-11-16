import AppKit
import Carbon

/// Global hotkey via Carbon RegisterEventHotKey (no Accessibility permission needed).
enum HotKey {
    static var onPress: (() -> Void)?
    private static var ref: EventHotKeyRef?
    private static var installed = false

    @discardableResult
    static func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                HotKey.onPress?()
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        if let r = ref {
            UnregisterEventHotKey(r)
            ref = nil
        }
        let id = EventHotKeyID(signature: OSType(0x53534c31), id: 1)   // 'SSL1'
        return RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr
    }

    static func carbonModifiers(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    /// Label such as "⌥Space", built from the recorded event.
    static func label(for e: NSEvent) -> String {
        var s = ""
        if e.modifierFlags.contains(.control) { s += "⌃" }
        if e.modifierFlags.contains(.option) { s += "⌥" }
        if e.modifierFlags.contains(.shift) { s += "⇧" }
        if e.modifierFlags.contains(.command) { s += "⌘" }
        let names: [UInt16: String] = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete"]
        return s + (names[e.keyCode] ?? (e.charactersIgnoringModifiers?.uppercased() ?? "?"))
    }
}

/// User preferences (UserDefaults). Defaults: Option+Space, launch at login off.
enum Prefs {
    private static var d: PrefStore { AppPrefs.store }   // the app's defaults; a memory store in test runs

    static var keyCode: UInt32 { UInt32(d.object(forKey: "hotkeyKeyCode") as? Int ?? 49) }
    static var modifiers: UInt32 { UInt32(d.object(forKey: "hotkeyModifiers") as? Int ?? Int(optionKey)) }
    static var label: String { d.string(forKey: "hotkeyLabel") ?? "⌥Space" }

    static func saveHotKey(code: UInt32, modifiers: UInt32, label: String) {
        d.set(Int(code), forKey: "hotkeyKeyCode")
        d.set(Int(modifiers), forKey: "hotkeyModifiers")
        d.set(label, forKey: "hotkeyLabel")
    }
}
