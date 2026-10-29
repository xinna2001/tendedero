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

    func testLegacyLayerMigrationAndRestartKeepOrderAndSources() throws {
        let notes = try store()
        let note = try notes.create(text: "日常内容\n第二行")
        let other = notes.root.appendingPathComponent("external.png")
        try Data([1, 2, 3]).write(to: other)
        let original = try Data(contentsOf: notes.url(for: note.id))
        let url = notes.root.appendingPathComponent("layers.json")
        let layers = try LayerStore(url: url, legacyPaths: [other.path, notes.url(for: note.id).path, other.path])
        let firstID = layers.activeID
        checkEqual(layers.active.paths, [other.path, notes.url(for: note.id).path])
        let second = try layers.create(name: "备用")
        checkEqual(layers.activeID, second.id)
        checkEqual(layers.active.paths, [])
        try layers.replaceActivePaths(["/another/card"])
        try layers.selectNext()
        checkEqual(layers.activeID, firstID)
        try layers.replaceActivePaths([])
        let restart = try LayerStore(url: url, legacyPaths: ["must not migrate twice"])
        checkEqual(restart.activeID, firstID)
        checkEqual(restart.layers[0].paths, [])
        checkEqual(restart.layers[1].paths, ["/another/card"])
        checkEqual(try Data(contentsOf: notes.url(for: note.id)), original)
        checkEqual(try Data(contentsOf: other), Data([1, 2, 3]))
    }

    func testManyLayersCycleAndRenameWithoutLosingCards() throws {
        let notes = try store()
        let layers = try LayerStore(url: notes.root.appendingPathComponent("layers.json"))
        for number in 2...20 {
            _ = try layers.create(name: "图层 \(number)")
            try layers.replaceActivePaths((0..<30).map { "/layer/\(number)/card/\($0)" })
        }
        try layers.renameActive("临时参考")
        for layer in layers.layers {
            try layers.selectNext()
            checkEqual(layers.activeID, layer.id)
        }
        let restart = try LayerStore(url: layers.url)
        checkEqual(restart.layers, layers.layers)
        checkEqual(restart.activeID, layers.activeID)
        checkEqual(restart.layers.last?.name, "临时参考")
        checkEqual(restart.layers.last?.paths.count, 30)
    }

    func testInvalidAndFailedLayerWritesNeverReplaceExistingState() throws {
        let notes = try store()
        let url = notes.root.appendingPathComponent("layers.json")
        let layers = try LayerStore(url: url)
        let before = layers.activeID
        checkThrows(try layers.select(UUID()))
        checkEqual(layers.activeID, before)
        let damaged = Data("invalid existing document".utf8)
        try damaged.write(to: url)
        checkThrows(try LayerStore(url: url, legacyPaths: ["old card"]))
        checkEqual(try Data(contentsOf: url), damaged)
        // Replace this isolated parent with a file to force a real I/O failure.
        try FileManager.default.removeItem(at: notes.root)
        try Data().write(to: notes.root)
        checkThrows(try layers.create(name: "cannot save"))
        checkEqual(layers.activeID, before)
        checkEqual(layers.layers.count, 1)
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
        try testLegacyLayerMigrationAndRestartKeepOrderAndSources()
        print("PASS legacy layer migration, restart and unchanged source files")
        try testManyLayersCycleAndRenameWithoutLosingCards()
        print("PASS twenty layers cycle, rename and preserve thirty cards each")
        try testInvalidAndFailedLayerWritesNeverReplaceExistingState()
        print("PASS corrupt data and failed writes preserve existing state")
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
