import AppKit
import Carbon
import ClipLineCore

enum LineShortcutAction { case toggle, nextLayer }

/// Only the layer shortcut is registered. Editing a note temporarily releases
/// Shift+Down so the system text view can use it for selection.
@MainActor
final class ChordMonitor {
    private var layerKey: HotKey?
    private var timer: Timer?
    private var modifiers = ModifierShortcutState()
    var onAction: (LineShortcutAction) -> Void = { _ in }
    var isEditingText: () -> Bool = { false }
    var isRunning: Bool { timer != nil }
    var layerRegistered: Bool { layerKey != nil }

    func start() -> Bool {
        guard timer == nil else { return true }
        let flags = CGEventSource.flagsState(.combinedSessionState)
        modifiers = ModifierShortcutState(shift: flags.contains(.maskShift), capsLock: flags.contains(.maskAlphaShift))
        updateLayerRegistration()
        let timer = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateLayerRegistration()
                let flags = CGEventSource.flagsState(.combinedSessionState)
                if self.modifiers.update(shift: flags.contains(.maskShift), capsLock: flags.contains(.maskAlphaShift)) {
                    self.onAction(.toggle)
                }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        return true
    }

    func updateLayerRegistration() {
        if isEditingText() { layerKey = nil }
        else if layerKey == nil {
            layerKey = HotKey(Shortcut(keyCode: kVK_DownArrow, modifiers: .shift, key: "↓")) { [weak self] in
                guard let self, !self.isEditingText() else { return }
                self.onAction(.nextLayer)
            }
        }
    }

    func stop() { timer?.invalidate(); timer = nil; layerKey = nil }
}
