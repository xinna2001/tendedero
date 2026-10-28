import AppKit

@MainActor
final class RegionCapture {
    private var process: Process?
    var isCapturing: Bool { process?.isRunning == true }
    var onCaptured: (URL) -> Void = { _ in }
    var onError: (String) -> Void = { _ in }
    func capture() {
        guard process == nil else { return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            onError(L("Screen capture needs Screen Recording permission in System Settings."))
            return
        }
        do {
            try FileManager.default.createDirectory(at: Inbox.folder, withIntermediateDirectories: true)
            let url = Inbox.folder.appendingPathComponent("Capture-\(UUID().uuidString).png")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-s", "-x", url.path]
            let errors = Pipe(); process.standardError = errors
            process.terminationHandler = { [weak self] process in
                let error = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.process = nil
                    if let bytes = try? Data(contentsOf: url), !bytes.isEmpty { self.onCaptured(url) }
                    else if process.terminationStatus != 0, !error.isEmpty {
                        self.onError(L("Screen capture needs Screen Recording permission in System Settings."))
                    }
                }
            }
            self.process = process
            try process.run()
        } catch { process = nil; onError(error.localizedDescription) }
    }
}
