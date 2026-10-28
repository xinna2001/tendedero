import Foundation

public struct NoteRecord: Codable, Equatable {
    public var schemaVersion = 1
    public let id: UUID
    public var text: String
    public var revision: Int
    public let createdAt: Date
    public var updatedAt: Date

    public var title: String {
        String((text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "空白便签").prefix(64))
    }
}

public enum NoteStoreError: LocalizedError {
    case invalidRecord, conflict, tooLarge
    public var errorDescription: String? {
        switch self {
        case .invalidRecord: return "便签格式无效或版本不受支持。"
        case .conflict: return "便签已更新，请重新打开后再修改。"
        case .tooLarge: return "单张便签最多保存 1 MB 的 UTF-8 文字。"
        }
    }
}

public final class NoteStore {
    public let root: URL
    public static let maxTextBytes = 1_000_000
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public init(root: URL) { self.root = root.standardizedFileURL }

    public func url(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("clipnote")
    }

    public func read(_ id: UUID) throws -> NoteRecord {
        let note = try Self.decode(url(for: id))
        guard note.id == id else { throw NoteStoreError.invalidRecord }
        return note
    }

    public static func decode(_ url: URL) throws -> NoteRecord {
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= maxTextBytes * 6 + 8192 else { throw NoteStoreError.tooLarge }
        let note = try JSONDecoder().decode(NoteRecord.self, from: bytes)
        guard note.schemaVersion == 1, note.revision > 0,
              note.text.utf8.count <= maxTextBytes,
              UUID(uuidString: url.deletingPathExtension().lastPathComponent) == note.id else {
            throw NoteStoreError.invalidRecord
        }
        return note
    }

    /// The same request ID creates the same note. Retries never replace edits.
    @discardableResult
    public func create(text: String = "", id: UUID = UUID()) throws -> NoteRecord {
        guard text.utf8.count <= Self.maxTextBytes else { throw NoteStoreError.tooLarge }
        if FileManager.default.fileExists(atPath: url(for: id).path) { return try read(id) }
        let now = Date()
        let note = NoteRecord(id: id, text: text, revision: 1, createdAt: now, updatedAt: now)
        try save(note)
        return note
    }

    @discardableResult
    public func update(_ id: UUID, text: String, expectedRevision: Int) throws -> NoteRecord {
        guard text.utf8.count <= Self.maxTextBytes else { throw NoteStoreError.tooLarge }
        var note = try read(id)
        guard note.revision == expectedRevision else { throw NoteStoreError.conflict }
        if note.text == text { return note }
        note.text = text
        note.revision += 1
        note.updatedAt = Date()
        try save(note)
        return note
    }

    public func all() throws -> [NoteRecord] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "clipnote" }
            .map(Self.decode).sorted { $0.createdAt < $1.createdAt }
    }

    private func save(_ note: NoteRecord) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try encoder.encode(note).write(to: url(for: note.id), options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(for: note.id).path)
    }
}
