import Foundation
import ClipLineCore

final class CoreChecks {
    var cleanup: [() -> Void] = []
    func addCleanup(_ action: @escaping () -> Void) { cleanup.append(action) }
    private func store() throws -> NoteStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addCleanup { try? FileManager.default.removeItem(at: url) }
        return NoteStore(root: url)
    }

    func testManualNotePreservesUnicodeAndWhitespaceAcrossRestart() throws {
        let store = try store()
        let text = "加恩的备注\n\n    缩进与 emoji 🧷\n$(literal) `code`\n"
        let note = try store.create(text: text)
        checkEqual(try NoteStore(root: store.root).read(note.id).text, text)
        checkEqual(try store.all().count, 1)
        let mode = try FileManager.default.attributesOfItem(atPath: store.url(for: note.id).path)[.posixPermissions] as? Int
        checkEqual(mode, 0o600)
    }

    func testRepeatedBridgeCreateDoesNotDuplicateOrOverwriteLaterEdit() throws {
        let store = try store(), id = UUID()
        let first = try store.create(text: "第一版", id: id)
        let updated = try store.update(id, text: "人工修改", expectedRevision: first.revision)
        let retry = try store.create(text: "第一版", id: id)
        checkEqual(retry, updated)
        checkEqual(try store.all().count, 1)
    }

    func testAutosaveRejectsStaleWriterAndNoOpDoesNotBumpRevision() throws {
        let store = try store(), note = try store.create()
        checkEqual(try store.update(note.id, text: "", expectedRevision: 1).revision, 1)
        checkEqual(try store.update(note.id, text: "新内容", expectedRevision: 1).revision, 2)
        checkThrows(try store.update(note.id, text: "过期", expectedRevision: 1))
        checkEqual(try store.read(note.id).text, "新内容")
    }

    func testBridgeValidationRequiresRevisionAndKeepsLiteralText() throws {
        let request = BridgeRequest(id: UUID(), operation: "note.add", text: "a\n\nb")
        let roundTrip = try JSONDecoder().decode(BridgeRequest.self, from: JSONEncoder().encode(request))
        checkEqual(roundTrip.text, "a\n\nb")
        try roundTrip.validate()
        checkThrows(try BridgeRequest(id: UUID(), operation: "note.update", text: "x", noteID: UUID()).validate())
        checkThrows(try BridgeRequest(id: UUID(), operation: "shell.execute").validate())
    }

    func testEscapedCharactersAtLargeSizesStillRoundTrip() throws {
        let store = try store()
        let text = String(repeating: "\n", count: 600_000)
        let note = try store.create(text: text)
        checkEqual(try store.read(note.id).text, text)
    }

    func testQACaptureAndShiftQAToggleAreMutuallyExclusiveAndSingleShot() {
        var state = ChordState()
        checkNil(state.press(12, at: 0, shift: false))
        checkEqual(state.press(0, at: 0.1, shift: false), .capture)
        checkNil(state.press(0, at: 0.15, shift: false, repeating: true))
        state.release(0)
        checkNil(state.press(0, at: 0.16, shift: true))
        state.release(12); state.release(0)
        checkNil(state.press(0, at: 1, shift: true))
        checkEqual(state.press(12, at: 1.1, shift: true), .toggle)
    }

    func testOrdinaryTypingAndOtherModifierShortcutsDoNotBecomeChords() {
        var state = ChordState()
        checkNil(state.press(12, at: 0, shift: false))
        state.release(12)
        checkNil(state.press(0, at: 0.1, shift: false))
        state.reset()
        checkNil(state.press(12, at: 1, shift: false))
        checkNil(state.press(0, at: 1.5, shift: false))
        state.reset()
        checkNil(state.press(12, at: 2, shift: false, permitted: false))
        checkNil(state.press(0, at: 2.1, shift: false, permitted: false))
    }
}

extension CoreChecks {
    func run() throws {
        defer { cleanup.forEach { $0() } }
        try testManualNotePreservesUnicodeAndWhitespaceAcrossRestart()
        print("PASS testManualNotePreservesUnicodeAndWhitespaceAcrossRestart")
        try testRepeatedBridgeCreateDoesNotDuplicateOrOverwriteLaterEdit()
        print("PASS testRepeatedBridgeCreateDoesNotDuplicateOrOverwriteLaterEdit")
        try testAutosaveRejectsStaleWriterAndNoOpDoesNotBumpRevision()
        print("PASS testAutosaveRejectsStaleWriterAndNoOpDoesNotBumpRevision")
        try testBridgeValidationRequiresRevisionAndKeepsLiteralText()
        print("PASS testBridgeValidationRequiresRevisionAndKeepsLiteralText")
        try testEscapedCharactersAtLargeSizesStillRoundTrip()
        print("PASS testEscapedCharactersAtLargeSizesStillRoundTrip")
        testQACaptureAndShiftQAToggleAreMutuallyExclusiveAndSingleShot()
        print("PASS testQACaptureAndShiftQAToggleAreMutuallyExclusiveAndSingleShot")
        testOrdinaryTypingAndOtherModifierShortcutsDoNotBecomeChords()
        print("PASS testOrdinaryTypingAndOtherModifierShortcutsDoNotBecomeChords")
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    precondition(actual == expected, "Expected \(expected), got \(actual)", file: file, line: line)
}
func checkNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) {
    precondition(value == nil, "Expected nil", file: file, line: line)
}
func checkThrows(_ value: @autoclosure () throws -> Any, file: StaticString = #file, line: UInt = #line) {
    do { _ = try value(); preconditionFailure("Expected an error", file: file, line: line) } catch { }
}
try CoreChecks().run()

var modifierState = ModifierShortcutState()
checkEqual(modifierState.update(shift: false, capsLock: true), false)
checkEqual(modifierState.update(shift: true, capsLock: true), true)
checkEqual(modifierState.update(shift: true, capsLock: true), false)
checkEqual(modifierState.update(shift: false, capsLock: true), false)
checkEqual(modifierState.update(shift: true, capsLock: true), true)
checkEqual(modifierState.update(shift: false, capsLock: false), false)
checkEqual(modifierState.update(shift: true, capsLock: false), false)
checkEqual(modifierState.update(shift: true, capsLock: true), true)
print("PASS CapsLockShiftSelectionAndDebounce")
