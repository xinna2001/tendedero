/// Observe only modifier transitions. One action per complete release.
public struct ModifierShortcutState {
    private var previousShift: Bool
    private var previousCaps: Bool
    private var latched = false
    public init(shift: Bool = false, capsLock: Bool = false) {
        previousShift = shift; previousCaps = capsLock
    }
    public mutating func update(shift: Bool, capsLock: Bool) -> Bool {
        let shiftBegan = shift && !previousShift
        let capsChanged = capsLock != previousCaps
        previousShift = shift; previousCaps = capsLock
        if !shift { latched = false }
        if shift, !latched, (shiftBegan && capsLock) || capsChanged {
            latched = true
            return true
        }
        return false
    }
}
