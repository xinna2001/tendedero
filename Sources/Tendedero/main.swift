import AppKit
import Darwin

try FileManager.default.createDirectory(at: ClipPaths.base, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
let instanceLock = open(ClipPaths.base.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
guard instanceLock >= 0, flock(instanceLock, LOCK_EX | LOCK_NB) == 0 else { exit(0) }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
close(instanceLock)
