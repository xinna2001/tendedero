import Foundation

public enum ChordAction: String { case capture, toggle }

/// Q and A must overlap and start within the same short chord window.
/// Shift selects toggle; it never also triggers capture. One action per release.
public struct ChordState {
    public static let q = 12, a = 0
    public static let window: TimeInterval = 0.22
    private var down: [Int: TimeInterval] = [:]
    private var latched = false
    public init() {}

    public mutating func press(_ key: Int, at time: TimeInterval, shift: Bool,
                               permitted: Bool = true, repeating: Bool = false) -> ChordAction? {
        guard permitted else { reset(); return nil }
        guard [Self.q, Self.a].contains(key) else { reset(); return nil }
        guard !repeating, down[key] == nil else { return nil }
        down[key] = time
        guard !latched, let q = down[Self.q], let a = down[Self.a], abs(q - a) <= Self.window else { return nil }
        latched = true
        return shift ? .toggle : .capture
    }

    public mutating func release(_ key: Int) {
        down[key] = nil
        if down.isEmpty { latched = false }
    }
    public mutating func reset() { down.removeAll(); latched = false }
}
