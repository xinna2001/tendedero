import Foundation

public struct BridgeRequest: Codable {
    public let version: Int
    public let id: UUID
    public let operation: String
    public let text: String?
    public let noteID: UUID?
    public let expectedRevision: Int?

    public init(id: UUID, operation: String, text: String? = nil, noteID: UUID? = nil, expectedRevision: Int? = nil) {
        self.version = 1
        self.id = id
        self.operation = operation
        self.text = text
        self.noteID = noteID
        self.expectedRevision = expectedRevision
    }

    public func validate() throws {
        guard version == 1 else { throw BridgeError.invalidRequest }
        switch operation {
        case "note.add": guard text != nil else { throw BridgeError.invalidRequest }
        case "note.update":
            guard text != nil, noteID != nil, let revision = expectedRevision, revision > 0 else {
                throw BridgeError.invalidRequest
            }
        case "line.show", "line.hide", "note.list": break
        default: throw BridgeError.invalidRequest
        }
        guard (text?.utf8.count ?? 0) <= NoteStore.maxTextBytes else { throw NoteStoreError.tooLarge }
    }
}

public struct BridgeReceipt: Codable {
    public let id: UUID
    public var success: Bool
    public var error: String?
    public var note: NoteRecord?
    public var notes: [NoteRecord]?
    public var shown: Bool?
    public var requestSHA256: String?

    public init(id: UUID, success: Bool, error: String? = nil, note: NoteRecord? = nil,
                notes: [NoteRecord]? = nil, shown: Bool? = nil, requestSHA256: String? = nil) {
        self.id = id; self.success = success; self.error = error; self.note = note
        self.notes = notes; self.shown = shown; self.requestSHA256 = requestSHA256
    }
}

public enum BridgeError: LocalizedError {
    case invalidRequest
    public var errorDescription: String? { "图绳联动请求无效。" }
}
