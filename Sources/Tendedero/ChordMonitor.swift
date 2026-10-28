import AppKit
import ApplicationServices
import ClipLineCore

/// Ordinary Q/A typing is replayed. Completed chords consume both keys.
@MainActor
final class ChordMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var state = ChordState()
    private var buffered: [CGEvent] = []
    private var consumed: Set<Int> = []
    private var pending: DispatchWorkItem?
    private static let replayTag: Int64 = 0x434C49504C494E45
    var onAction: (ChordAction) -> Void = { _ in }
    var isRunning: Bool { tap != nil }

    func start(prompt: Bool = false) -> Bool {
        if tap != nil { return true }
        if prompt {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: { proxy, type, event, pointer in
                guard let pointer else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<ChordMonitor>.fromOpaque(pointer).takeUnretainedValue()
                return MainActor.assumeIsolated { monitor.handle(type, event, proxy: proxy) }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
    func stop() {
        flush()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil; source = nil; state.reset(); consumed.removeAll()
    }
    private func handle(_ type: CGEventType, _ event: CGEvent, proxy: CGEventTapProxy? = nil) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.eventSourceUserData) == Self.replayTag { return Unmanaged.passUnretained(event) }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            flush(proxy); state.reset(); consumed.removeAll()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        let permitted = flags.subtracting(.maskShift).isEmpty
        if type == .flagsChanged {
            if !permitted { flush(proxy); state.reset() }
            return Unmanaged.passUnretained(event)
        }
        if type == .keyUp {
            state.release(key)
            if consumed.remove(key) != nil { return nil }
            if !buffered.isEmpty, [ChordState.q, ChordState.a].contains(key) {
                if let copy = event.copy() { buffered.append(copy) }
                flush(proxy); return nil
            }
            return Unmanaged.passUnretained(event)
        }
        let repeating = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if !consumed.isEmpty, [ChordState.q, ChordState.a].contains(key) {
            consumed.insert(key)
            return nil
        }
        let action = state.press(key, at: Double(event.timestamp) / 1_000_000_000,
                                 shift: flags.contains(.maskShift), permitted: permitted, repeating: repeating)
        if let action {
            pending?.cancel(); pending = nil; buffered.removeAll()
            consumed = [ChordState.q, ChordState.a]
            DispatchQueue.main.async { [weak self] in self?.onAction(action) }
            return nil
        }
        guard permitted, !repeating, [ChordState.q, ChordState.a].contains(key) else {
            if repeating, !buffered.isEmpty { flush(proxy); state.reset() }
            else { flush(proxy) }
            return Unmanaged.passUnretained(event)
        }
        if buffered.isEmpty, let copy = event.copy() {
            buffered = [copy]
            let work = DispatchWorkItem { [weak self] in self?.flush() }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + ChordState.window, execute: work)
            return nil
        }
        flush(proxy)
        return Unmanaged.passUnretained(event)
    }
    private func flush(_ proxy: CGEventTapProxy? = nil) {
        pending?.cancel(); pending = nil
        let events = buffered; buffered.removeAll()
        for event in events {
            event.setIntegerValueField(.eventSourceUserData, value: Self.replayTag)
            if let proxy { event.tapPostEvent(proxy) }
            else { event.post(tap: .cgSessionEventTap) }
        }
    }
}
