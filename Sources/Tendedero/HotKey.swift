import AppKit
import Carbon

/// A single global shortcut through the Carbon hot key API. Unlike a global
/// key monitor, it needs no Accessibility permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private static var action: (() -> Void)?
    private static var handlerInstalled = false

    /// Nil when the combination cannot be registered, for example because
    /// another app already took it.
    init?(_ shortcut: Shortcut, action: @escaping () -> Void) {
        HotKey.action = action
        // One handler for the app, however many times the shortcut changes.
        if !HotKey.handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.action?() }
                return noErr
            }, 1, &spec, nil, nil)
            HotKey.handlerInstalled = true
        }
        let id = EventHotKeyID(signature: OSType(0x5445_4E44), id: 1) // "TEND"
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), UInt32(shortcut.carbonModifiers), id,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, ref != nil else { return nil }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }
}

struct Shortcut {
    var keyCode: Int
    var modifiers: NSEvent.ModifierFlags
    var key: String

    init(keyCode: Int, modifiers: NSEvent.ModifierFlags, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    var carbonModifiers: Int {
        var carbon = 0
        if modifiers.contains(.command) { carbon |= cmdKey }
        if modifiers.contains(.control) { carbon |= controlKey }
        if modifiers.contains(.option) { carbon |= optionKey }
        if modifiers.contains(.shift) { carbon |= shiftKey }
        return carbon
    }

}
