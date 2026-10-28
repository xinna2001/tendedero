import AppKit
import Carbon
import ClipLineCore

/// Shift+Z registers with macOS; Caps Lock+Shift reads only modifier flags.
/// The monitor never reads or delays clipboard contents or typed characters.
@MainActor
final class ChordMonitor {
    private var captureKey: HotKey?
    private var timer: Timer?
    private var modifiers = ModifierShortcutState()
    var onAction: (ChordAction) -> Void = { _ in }
    var isRunning: Bool { captureKey != nil && timer != nil }
    var captureRegistered: Bool { captureKey != nil }

    func start(prompt: Bool = false) -> Bool {
        if isRunning { return true }
        if captureKey == nil {
            captureKey = HotKey(Shortcut(keyCode: kVK_ANSI_Z, modifiers: .shift, key: "z")) { [weak self] in
                self?.onAction(.capture)
            }
        }
        if timer == nil {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            modifiers = ModifierShortcutState(shift: flags.contains(.maskShift), capsLock: flags.contains(.maskAlphaShift))
            let timer = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let flags = CGEventSource.flagsState(.combinedSessionState)
                    if self.modifiers.update(shift: flags.contains(.maskShift), capsLock: flags.contains(.maskAlphaShift)) {
                        self.onAction(.toggle)
                    }
                }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        return isRunning
    }
    func stop() { timer?.invalidate(); timer = nil; captureKey = nil }
}
