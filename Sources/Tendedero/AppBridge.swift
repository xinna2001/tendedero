import AppKit
import CryptoKit
import ClipLineCore

enum ClipPaths {
    static let base: URL = {
        if let path = ProcessInfo.processInfo.environment["CLIPLINE_DATA_ROOT"] { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipLine", isDirectory: true)
    }()
    static let notes = NoteStore(root: base.appendingPathComponent("Notes", isDirectory: true))
}

enum ClipSettings {
    static let defaults: UserDefaults = {
        guard let root = ProcessInfo.processInfo.environment["CLIPLINE_DATA_ROOT"] else { return .standard }
        let suffix = SHA256.hash(data: Data(root.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        return UserDefaults(suiteName: "com.xinna2001.ClipLine.isolated.\(suffix)")!
    }()
}

/// Atomic local requests with durable receipts; text never becomes shell code.
@MainActor
final class AppBridge {
    private let root: URL
    private var timer: Timer?
    private var lastStatus = Date.distantPast
    var onCommand: (BridgeRequest) throws -> BridgeReceipt = { _ in throw BridgeError.invalidRequest }
    var onStatus: () -> [String: Any] = { [:] }
    init(root: URL = ClipPaths.base) { self.root = root }
    private var requests: URL { root.appendingPathComponent("Requests") }
    private var receipts: URL { root.appendingPathComponent("Receipts") }

    func start() throws {
        for folder in [root, requests, receipts] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.process() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        process()
    }
    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func process() {
        let files = (try? FileManager.default.contentsOfDirectory(at: requests,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])) ?? []
        for file in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(10) {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let attr = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  attr.isRegularFile == true, attr.isSymbolicLink != true else { continue }
            let destination = receipts.appendingPathComponent(file.lastPathComponent)
            do {
                let data = try Data(contentsOf: file)
                guard data.count <= NoteStore.maxTextBytes * 6 + 8192 else { throw NoteStoreError.tooLarge }
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                if FileManager.default.fileExists(atPath: destination.path) {
                    let old = try JSONDecoder().decode(BridgeReceipt.self, from: Data(contentsOf: destination))
                    guard old.requestSHA256 == hash else {
                        log.error("A bridge request ID was reused with different content")
                        try FileManager.default.removeItem(at: file)
                        continue
                    }
                } else {
                    var result: BridgeReceipt
                    do {
                        let request = try JSONDecoder().decode(BridgeRequest.self, from: data)
                        guard request.id == id else { throw BridgeError.invalidRequest }
                        try request.validate()
                        result = try onCommand(request)
                    } catch { result = BridgeReceipt(id: id, success: false, error: error.localizedDescription) }
                    result.requestSHA256 = hash
                    try write(JSONEncoder().encode(result), to: destination)
                }
                try FileManager.default.removeItem(at: file)
            } catch { log.error("Bridge request failed: \(error.localizedDescription, privacy: .public)") }
        }
        if Date().timeIntervalSince(lastStatus) >= 1 {
            var status = onStatus()
            status["pid"] = ProcessInfo.processInfo.processIdentifier
            status["version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
            status["updatedAt"] = Date().timeIntervalSince1970
            status["protocolVersion"] = 1
            status["app"] = "ClipLine"
            if let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]) {
                try? write(data, to: root.appendingPathComponent("status.json"))
            }
            lastStatus = Date()
        }
    }
}
