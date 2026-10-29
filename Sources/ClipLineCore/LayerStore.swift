import Foundation

public struct LayerRecord: Codable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var paths: [String]
}

private struct LayerDocument: Codable {
    var version = 1
    var activeID: UUID
    var layers: [LayerRecord]
}

public enum LayerStoreError: LocalizedError {
    case invalidDocument, unknownLayer
    public var errorDescription: String? {
        switch self {
        case .invalidDocument: return "图层数据无法读取，原文件已保留。"
        case .unknownLayer: return "找不到这个图层。"
        }
    }
}

/// Only membership is stored here. Removing a card or switching layers never
/// changes its source file. A failed write leaves the in-memory state intact.
public final class LayerStore {
    public let url: URL
    private var document: LayerDocument
    public var layers: [LayerRecord] { document.layers }
    public var activeID: UUID { document.activeID }
    public var active: LayerRecord { document.layers.first { $0.id == activeID }! }

    public init(url: URL, legacyPaths: [String] = [], firstName: String = "日常") throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            document = try JSONDecoder().decode(LayerDocument.self, from: Data(contentsOf: url))
            try Self.validate(document)
        } else {
            let first = LayerRecord(id: UUID(), name: firstName, paths: Self.unique(legacyPaths))
            document = LayerDocument(activeID: first.id, layers: [first])
            try persist(document)
        }
    }

    @discardableResult
    public func create(name: String) throws -> LayerRecord {
        var next = document
        let layer = LayerRecord(id: UUID(), name: name, paths: [])
        next.layers.append(layer)
        next.activeID = layer.id
        try commit(next)
        return layer
    }

    public func select(_ id: UUID) throws {
        guard document.layers.contains(where: { $0.id == id }) else { throw LayerStoreError.unknownLayer }
        var next = document
        next.activeID = id
        try commit(next)
    }

    public func selectNext() throws {
        let index = document.layers.firstIndex { $0.id == activeID }!
        try select(document.layers[(index + 1) % document.layers.count].id)
    }

    public func renameActive(_ name: String) throws {
        var next = document
        let index = next.layers.firstIndex { $0.id == activeID }!
        next.layers[index].name = name
        try commit(next)
    }

    public func replaceActivePaths(_ paths: [String]) throws {
        var next = document
        let index = next.layers.firstIndex { $0.id == activeID }!
        next.layers[index].paths = Self.unique(paths)
        try commit(next)
    }

    public func layer(containing path: String) -> LayerRecord? {
        document.layers.first { $0.paths.contains(path) }
    }

    public func removeEverywhere(_ path: String) throws {
        var next = document
        for index in next.layers.indices { next.layers[index].paths.removeAll { $0 == path } }
        try commit(next)
    }

    private func commit(_ next: LayerDocument) throws {
        try Self.validate(next)
        try persist(next)
        document = next
    }

    private func persist(_ value: LayerDocument) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private static func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    private static func validate(_ value: LayerDocument) throws {
        guard value.version == 1, !value.layers.isEmpty,
              Set(value.layers.map(\.id)).count == value.layers.count,
              value.layers.contains(where: { $0.id == value.activeID }),
              value.layers.allSatisfy({ !$0.name.isEmpty && Set($0.paths).count == $0.paths.count }) else {
            throw LayerStoreError.invalidDocument
        }
    }
}
