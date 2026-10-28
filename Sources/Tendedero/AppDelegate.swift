import AppKit
import Carbon
import Combine
import Quartz
import ServiceManagement
import SwiftUI
import ClipLineCore
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let line = Line()
    private var panel: LinePanel!
    private var statusItem: NSStatusItem!
    private var watcher: ScreenshotWatcher!
    /// In inbox mode, a second watcher on the Desktop. If a macOS version
    /// ignores the screenshot settings (macOS 27 renamed one), captures keep
    /// landing on the Desktop, and they still hang on the line.
    private var safetyWatcher: ScreenshotWatcher?
    /// Folders chosen in "Also watch folders", like the one another
    /// screenshot app saves to.
    private var folderWatchers: [ScreenshotWatcher] = []
    private var clipboardWatcher: ClipboardWatcher!
    private var signalSources: [DispatchSourceSignal] = []
    private var cancellables = Set<AnyCancellable>()
    private var mouseTimer: Timer?
    private let noteEditor = NoteEditor()
    private let chordMonitor = ChordMonitor()
    private let regionCapture = RegionCapture()
    private let bridge = AppBridge()
    private var captureShortcutCount = 0
    private var toggleShortcutCount = 0
    private static let systemChordsEnabled = ProcessInfo.processInfo.environment["CLIPLINE_DATA_ROOT"] == nil

    /// Whether the panel is ordered in. It can be in and still tucked away
    /// above the top edge, like an auto-hiding Dock.
    private var isPresent = false
    /// Whether the line has slid down into view.
    private var isRevealed = false
    /// Opened on purpose with the shortcut or the menu: it stays down until
    /// the cursor has visited it and left, or the shortcut is pressed again.
    private var pinned = false
    /// A new screenshot shows itself for a moment, then tucks away.
    private var peekUntil = Date.distantPast
    private var hotZoneSince: Date?
    /// After a click in the menu bar the line stays up there hidden until the
    /// pointer leaves the menu bar, so it does not come back over a menu.
    private var menuBarSuppressed = false
    private var clickMonitors: [Any] = []
    private var awaySince: Date?
    /// Whether the line should be up, if nothing prevents it. A full screen
    /// app on that screen does: the line waits until you leave full screen.
    private var wanted = false
    /// Set when you open the line on purpose, so it stays up while empty.
    private var keepOpen = false
    /// Opened on purpose with the shortcut or the menu, which counts over a
    /// full screen app too, until the line tucks away.
    private var openedOnPurpose = false

    // What brings the line down, from the menu bar's "Bring the line down".
    // Out of the box, the first two are on and the third off.

    /// Resting the pointer in the menu bar. Off, only the shortcut and the
    /// menu open it.
    static var opensFromMenuBar: Bool {
        get { !ClipSettings.defaults.bool(forKey: "menuBarRevealOff") }
        set { ClipSettings.defaults.set(!newValue, forKey: "menuBarRevealOff") }
    }

    /// Something new hanging shows itself for a moment. Off, it hangs
    /// quietly and waits for you to bring the line down.
    static var peeksAtNew: Bool {
        get { !ClipSettings.defaults.bool(forKey: "quietHang") }
        set { ClipSettings.defaults.set(!newValue, forKey: "quietHang") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = NSHostingView(rootView: LineView(line: line))
        host.sizingOptions = []
        panel = LinePanel(content: host)
        panel.placeOnScreen()
        updateCapacity()

        line.onNewNote = { [weak self] in self?.newNote() }
        line.onEditNote = { [weak self] id in self?.editNote(id) }
        line.onDeleteNote = { [weak self] id in self?.deleteNote(id) }
        noteEditor.onSaved = { [weak self] url in self?.line.reloadThumbnail(for: url) }
        noteEditor.onClosed = { [weak self] in self?.awaySince = nil }
        chordMonitor.onAction = { [weak self] action in
            if action == .toggle {
                self?.toggleShortcutCount += 1
                self?.toggle()
            } else {
                self?.captureShortcutCount += 1
                self?.captureRegion()
            }
        }
        if Self.systemChordsEnabled { _ = chordMonitor.start() }
        regionCapture.onCaptured = { [weak self] url in self?.hangCapture(url) }
        regionCapture.onError = { [weak self] message in self?.showError(message) }
        bridge.onCommand = { [weak self] request in
            guard let self else { throw BridgeError.invalidRequest }
            return try self.bridgeCommand(request)
        }
        bridge.onStatus = { [weak self] in
            ["shown": self?.isRevealed ?? false,
             "notes": (try? ClipPaths.notes.all().count) ?? 0,
             "globalChordsActive": self?.chordMonitor.isRunning ?? false,
             "accessibilityTrusted": AXIsProcessTrusted(),
             "screenCaptureAllowed": CGPreflightScreenCaptureAccess(),
             "captureShortcut": "Shift+Z", "toggleShortcut": "Caps Lock+Shift",
             "captureShortcutRegistered": self?.chordMonitor.captureRegistered ?? false,
             "captureShortcutCount": self?.captureShortcutCount ?? 0,
             "toggleShortcutCount": self?.toggleShortcutCount ?? 0]
        }
        do { try bridge.start() } catch { showError(error.localizedDescription) }

        if Inbox.isEnabled { Inbox.apply() }
        restoreSettingsOnTermination()
        startWatcher()
        clipboardWatcher = ClipboardWatcher { [weak self] url in self?.hangCapture(url) }
        if ClipboardWatcher.isEnabled { clipboardWatcher.start() }

        setUpStatusItem()
        ApplicationMenu.install(show: { [weak self] in self?.showLine() },
                                capture: { [weak self] in self?.captureRegion() },
                                note: { [weak self] in self?.newNote() })
        watchMenuBarClicks()

        Markup.shared.onSaved = { [weak self] url in self?.line.reloadThumbnail(for: url) }
        Trim.shared.onSaved = { [weak self] url in self?.line.reloadThumbnail(for: url) }
        panel.onScroll = { [weak self] event in
            // Sideways on a trackpad, or the wheel of a mouse.
            let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
                ? event.scrollingDeltaX : event.scrollingDeltaY
            self?.line.scroll(by: event.hasPreciseScrollingDeltas ? delta : delta * 12)
        }
        line.onFall = { [weak self] item in self?.fall(item) }

        line.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.itemsChanged() }
            .store(in: &cancellables)
        // Photos kept from last time show themselves for a moment.
        if line.liveCount > 0 { comeDown(on: nil) }

        // Entering or leaving full screen switches Space. Check again once the
        // switch animation has settled.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Opened on purpose counts for the Space it was opened on.
                    if name == NSWorkspace.activeSpaceDidChangeNotification { self?.openedOnPurpose = false }
                    self?.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        self?.refresh()
                        self?.keepOnActiveSpace()
                    }
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel.placeOnScreen()
                self?.updateCapacity()
            }
        }

        // Q+A saves its capture directly; system screenshot settings stay
        // unchanged unless the user enables inbox mode from the menu.
        Inbox.wasOffered = true

        if !ClipSettings.defaults.bool(forKey: "welcomed") {
            ClipSettings.defaults.set(true, forKey: "welcomed")
            keepOpen = true
            wanted = true
            refresh()
            reveal(pinned: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.line.liveCount == 0 else { return }
                self.keepOpen = false
                self.wanted = false
                self.refresh()
            }
        }
        #if DEBUG
        if CommandLine.arguments.contains("--ui-checks"), ProcessInfo.processInfo.environment["CLIPLINE_DATA_ROOT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.runUIChecks() }
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = noteEditor.save()
        chordMonitor.stop()
        if Inbox.isEnabled { Inbox.restore() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        noteEditor.save() ? .terminateNow : .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showLine()
        return true
    }

    // MARK: Manual notes and local Botmux bridge

    private func showLine() {
        keepOpen = true; wanted = true; openedOnPurpose = true
        panel.placeOnScreen(); updateCapacity(); refresh(); reveal(pinned: true)
    }

    private func newNote() {
        do {
            let note = try ClipPaths.notes.create()
            guard let id = line.hang(ClipPaths.notes.url(for: note.id)) else { throw NoteStoreError.invalidRecord }
            showLine()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.editNote(id) }
        } catch { showError(error.localizedDescription) }
    }

    private func editNote(_ id: UUID) {
        do {
            let note = try ClipPaths.notes.read(id)
            showLine()
            let rect = line.hitRects[id] ?? line.hitRects[Line.emptyClipID]
            let anchor = NSPoint(x: panel.frame.minX + (rect?.midX ?? panel.frame.width / 2),
                                 y: panel.frame.maxY - (rect?.minY ?? 30))
            noteEditor.open(note, store: ClipPaths.notes, anchor: anchor)
        } catch { showError(error.localizedDescription) }
    }

    private func captureRegion() {
        guard !regionCapture.isCapturing, noteEditor.close() else { return }
        setRevealed(false)
        panel.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.regionCapture.capture() }
    }

    private func deleteNote(_ id: UUID) {
        guard noteEditor.close() else { return }
        _ = line.trash(id)
    }

    private func bridgeCommand(_ request: BridgeRequest) throws -> BridgeReceipt {
        var note: NoteRecord?
        switch request.operation {
        case "note.add": note = try ClipPaths.notes.create(text: request.text!, id: request.id)
        case "note.update":
            try noteEditor.prepareExternalUpdate(request.noteID!)
            note = try ClipPaths.notes.update(request.noteID!, text: request.text!, expectedRevision: request.expectedRevision!)
            if let note { noteEditor.refresh(note) }
        case "line.show": showLine()
        case "line.hide":
            guard noteEditor.close() else { throw NoteStoreError.conflict }
            setRevealed(false)
        case "note.list": return BridgeReceipt(id: request.id, success: true, notes: try ClipPaths.notes.all(), shown: isRevealed)
        default: throw BridgeError.invalidRequest
        }
        if let note {
            let url = ClipPaths.notes.url(for: note.id)
            _ = line.hang(url)
            line.reloadThumbnail(for: url)
            showLine()
        }
        return BridgeReceipt(id: request.id, success: true, note: note, shown: isRevealed)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "ClipLine · 图绳"
        alert.informativeText = message
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }

    #if DEBUG
    private func runUIChecks() {
        for number in 1...3 {
            if let note = try? ClipPaths.notes.create(text: "参考便签 \(number)") {
                _ = line.hang(ClipPaths.notes.url(for: note.id))
            }
        }
        showLine()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            let originalCount = self.line.liveCount
            let beforeClipX = self.line.hitRects[Line.emptyClipID]?.midX ?? 0
            if let rect = self.line.hitRects[Line.emptyClipID] {
                let point = NSPoint(x: rect.midX, y: self.panel.frame.height - rect.midY)
                self.panel.ignoresMouseEvents = false
                for (type, offset) in [(NSEvent.EventType.leftMouseDown, 0.0), (.leftMouseUp, 0.05)] {
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime + offset,
                        windowNumber: self.panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) {
                        self.panel.sendEvent(event)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let clicked = self.line.liveCount == originalCount + 1
                let afterClipX = self.line.hitRects[Line.emptyClipID]?.midX ?? 0
                let lastCardX = self.line.items.last.flatMap { self.line.hitRects[$0.id]?.midX } ?? 0
                let dynamicClip = afterClipX > beforeClipX && afterClipX > lastCardX
                let sample = "图绳便签\n\n点空夹子创建纸张\nCommand+V 粘贴，自动保存\n右上角垃圾桶可直接删除\n\nShift+Z：框选截图\nCaps Lock+Shift：展示 / 收起"
                let editorWorked = self.noteEditor.insertForUIChecks("先手动输入的一段文字")
                guard let note = try? ClipPaths.notes.all().last else {
                    try? Data("{\"success\":false,\"emptyClipClicked\":\(clicked)}".utf8)
                        .write(to: ClipPaths.base.appendingPathComponent("ui-checks.json"))
                    NSApp.terminate(nil); return
                }
                let clipboard = NSPasteboard.general
                let before = (clipboard.pasteboardItems ?? []).map { item in
                    item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
                }
                clipboard.clearContents()
                clipboard.setString(sample, forType: .string)
                let pasteWorked = self.noteEditor.pasteForUIChecks(sample)
                self.line.copy(note.id)
                let copied = clipboard.string(forType: .string) == sample
                let count = clipboard.changeCount
                if clipboard.changeCount == count {
                    clipboard.clearContents()
                    let restored = before.map { entry -> NSPasteboardItem in
                        let item = NSPasteboardItem()
                        for (type, data) in entry { item.setData(data, forType: type) }
                        return item
                    }
                    clipboard.writeObjects(restored)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    if let view = self.panel.contentView {
                        let region = self.line.hitRects.values.reduce(CGRect.null) { $0.union($1) }
                            .insetBy(dx: -45, dy: -30).intersection(view.bounds)
                        if !region.isNull, let bitmap = view.bitmapImageRepForCachingDisplay(in: region) {
                            view.cacheDisplay(in: region, to: bitmap)
                            try? bitmap.representation(using: .png, properties: [:])?
                                .write(to: ClipPaths.base.appendingPathComponent("line-preview.png"))
                        }
                    }
                    let persisted = (try? ClipPaths.notes.read(note.id).text) == sample
                    var clickedTrash = false
                    if let rect = self.line.hitRects[note.id] {
                        _ = self.noteEditor.close()
                        let point = NSPoint(x: rect.maxX - 13, y: self.panel.frame.height - rect.minY - 13)
                        self.panel.ignoresMouseEvents = false
                        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: self.panel.windowNumber,
                                context: nil, eventNumber: 2, clickCount: 1, pressure: 1) {
                                self.panel.sendEvent(event)
                            }
                        }
                        clickedTrash = !FileManager.default.fileExists(atPath: ClipPaths.notes.url(for: note.id).path)
                    }
                    let report: [String: Any] = ["success": clicked && editorWorked && copied && persisted && dynamicClip && pasteWorked && clickedTrash,
                        "emptyClipClicked": clicked, "editorWorked": editorWorked,
                        "dynamicEmptyClip": dynamicClip,
                        "commandVPaste": pasteWorked, "dockVisible": NSApp.activationPolicy() == .regular,
                        "trashButtonDeletes": clickedTrash,
                        "clipboardTextExact": copied, "persistedTextExact": persisted, "noteID": note.id.uuidString]
                    try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted])
                        .write(to: ClipPaths.base.appendingPathComponent("ui-checks.json"))
                    NSApp.terminate(nil)
                }
            }
        }
    }
    #endif

    // MARK: Inbox mode

    private func startWatcher() {
        watcher?.stop()
        safetyWatcher?.stop()
        safetyWatcher = nil
        watcher = ScreenshotWatcher(
            onNew: { [weak self] url in self?.hangCapture(url) },
            onChange: { [weak self] in self?.line.prune() })
        watcher.start()
        if Inbox.isEnabled, watcher.folder.standardizedFileURL != ScreenshotWatcher.desktop.standardizedFileURL {
            let safety = ScreenshotWatcher(
                folder: ScreenshotWatcher.desktop,
                onNew: { [weak self] url in
                    log.notice("Screenshot landed on the Desktop despite inbox mode: \(url.lastPathComponent, privacy: .public)")
                    self?.hangCapture(url)
                },
                onChange: { [weak self] in self?.line.prune() })
            safety.start()
            safetyWatcher = safety
        }
        folderWatchers.forEach { $0.stop() }
        folderWatchers = []
        // A folder may also be watched for screenshots, like the Desktop; an
        // image both report hangs once.
        for folder in Self.extraFolders {
            let extra = ScreenshotWatcher(
                folder: folder, anyImage: true,
                onNew: { [weak self] url in self?.hangCapture(url) },
                onChange: { [weak self] in self?.line.prune() })
            extra.start()
            folderWatchers.append(extra)
        }
    }

    /// Up to three folders: enough for another screenshot app or an export
    /// folder, few enough that screenshots still have room on the line.
    static let maxExtraFolders = 3

    /// The folders from "Also watch folders" that still exist. New images in
    /// them hang like screenshots; taking one down leaves the file there.
    static var extraFolders: [URL] {
        get {
            let paths = ClipSettings.defaults.stringArray(forKey: "extraFolders") ?? []
            return paths.compactMap { path in
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        set { ClipSettings.defaults.set(newValue.map(\.path), forKey: "extraFolders") }
    }

    private func chooseExtraFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Watch")
        panel.message = L("New images saved to this folder will hang on the line.")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, Self.extraFolders.count < Self.maxExtraFolders,
              !Self.extraFolders.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else { return }
        Self.extraFolders.append(url)
        startWatcher()
    }

    private func setInbox(_ on: Bool) {
        Inbox.isEnabled = on
        if on { Inbox.apply() } else { Inbox.restore() }
        startWatcher()
    }

    /// Asked once. Changing system settings is the user's call, never ours.
    private func offerInbox() {
        Inbox.wasOffered = true
        let alert = NSAlert()
        alert.messageText = L("Let Tendedero handle your screenshots?")
        alert.informativeText = L(
            "Screenshots will hang on the line the instant you take them, without the floating thumbnail, and will not pile up on your Desktop. Drag one to a folder to keep it, or discard it with the cross. You can turn this off from the menu bar, and your settings come back when Tendedero quits.")
        alert.addButton(withTitle: L("Turn on"))
        alert.addButton(withTitle: L("Not now"))
        if let icon = NSApp.applicationIconImage { alert.icon = icon }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { setInbox(true) }
    }

    /// Watching the clipboard is opt in, from the menu bar only.
    private func setClipboard(_ on: Bool) {
        ClipboardWatcher.isEnabled = on
        if on { clipboardWatcher.start() } else { clipboardWatcher.stop() }
        updateStatusIcon()
    }

    /// Quitting from the menu or logging out runs applicationWillTerminate.
    /// A plain kill does not, so settings are also restored on those signals.
    private func restoreSettingsOnTermination() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                guard self?.noteEditor.save() != false else { return }
                if Inbox.isEnabled { Inbox.restore() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Showing and hiding

    /// An empty line goes away, unless it was opened on purpose.
    private func itemsChanged() {
        updateStatusIcon()
        guard line.liveCount == 0, !keepOpen else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.line.liveCount == 0, !self.keepOpen else { return }
            self.wanted = false
            self.refresh()
        }
    }

    /// The line comes down on that screen for a moment, then tucks away.
    /// Without a screen, it uses the one under the pointer.
    private func comeDown(on screen: NSScreen?) {
        panel.placeOnScreen(screen)
        updateCapacity()
        wanted = true
        refresh()
        if Self.peeksAtNew { reveal(peekFor: 2.5) }
    }

    // MARK: The capture flying to the line

    /// A new screenshot lifts off from where it was taken and flies to its
    /// place on the line. Without a known capture area it simply drops in.
    private func hangCapture(_ url: URL) {
        let from = captureRect(of: url)
        let screen = from.flatMap { from in
            NSScreen.screens.first { NSMouseInRect(CGPoint(x: from.midX, y: from.midY), $0.frame, false) }
        }
        // Every capture brings the line down before it hangs, on the screen it
        // was taken on. On a full line the oldest photo then falls in view as
        // the new one flies in.
        comeDown(on: screen)
        guard let id = line.hang(url, flying: from != nil) else {
            // Nothing hung after all, so an empty line goes away again.
            itemsChanged()
            return
        }
        guard let from else { return }
        // Let the line come down and lay out before measuring the landing spot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.fly(id, from: from)
        }
    }

    private func fly(_ id: UUID, from: CGRect) {
        guard isPresent, isRevealed, CaptureFlight.flightsInProgress < 2, let screen = panel.screen,
              let to = cardFrame(for: id),
              let item = line.items.first(where: { $0.id == id }) else {
            line.land(id)
            return
        }
        // Sharp enough while it starts out at the captured size, which a
        // full Retina screen would otherwise take at full resolution.
        let pixels = Int(max(from.width, from.height) * screen.backingScaleFactor)
        guard let image = makeThumbnail(item.url, maxPixels: min(1500, max(400, pixels)))?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            line.land(id)
            return
        }
        CaptureFlight.fly(image: image, from: from, to: to, tilt: CGFloat(item.tilt), on: screen) { [weak self] in
            self?.line.land(id)
        }
    }

    /// A discarded card falls over the whole screen, from where it hangs.
    private func fall(_ item: Pegged) {
        guard isPresent, isRevealed, !item.flying, let screen = panel.screen,
              let card = cardFrame(for: item.id),
              let image = item.thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        CaptureFlight.fall(image: image, card: card, tilt: CGFloat(item.tilt), on: screen)
    }

    /// Where a card will hang, in screen coordinates, using the same layout
    /// as the line view.
    private func cardFrame(for id: UUID) -> CGRect? {
        guard let index = line.items.firstIndex(where: { $0.id == id }) else { return nil }
        let width = panel.frame.width
        let x = Layout.x(index: index, count: line.items.count, width: width,
                         visible: line.visibleCount, scroll: line.scroll)
        let viewTop = Layout.ropeY(x: x, width: width) - Layout.pinAbove
        let cardTop = viewTop + PeggedView.cardOffsetBelowTop
        let size = PeggedView.cardSize(for: line.items[index].thumb.size)
        return CGRect(x: panel.frame.minX + x - size.width / 2,
                      y: panel.frame.maxY - cardTop - size.height,
                      width: size.width, height: size.height)
    }

    /// Decides whether the panel is ordered in at all: something to show,
    /// and no full screen app on that screen unless you asked for the line.
    private func refresh() {
        let blocked = !openedOnPurpose && (panel.screen.map(FullScreen.blocksLine(on:))
            ?? LinePanel.screenUnderPointer().map(FullScreen.blocksLine(on:)) ?? false)
        if wanted && !blocked {
            present()
        } else {
            dismiss()
        }
        // The cursor is watched while there is a line, even tucked away,
        // to notice it pushing against the top edge.
        if wanted || Self.opensFromMenuBar { startMouseTracking() } else { stopMouseTracking() }
    }

    private func present() {
        guard !isPresent else { return }
        isPresent = true
        panel.alphaValue = 1
        // The window itself only comes in while the line is down; see setRevealed.
        if isRevealed { panel.orderFrontRegardless() }
    }

    private func dismiss() {
        guard isPresent else { return }
        isPresent = false
        setRevealed(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.isPresent else { return }
            self.panel.orderOut(nil)
        }
    }

    /// The line is one window on every Space. After a long time running,
    /// macOS can leave it bound to a single Space, where ordering it in does
    /// nothing on the others while captures keep arriving (#80). Quitting and
    /// opening the app again fixes it because the window is new, so do the
    /// same here: a fresh window with the same contents, in the same place.
    private func keepOnActiveSpace() {
        guard isPresent, isRevealed, panel.isVisible, !panel.isOnActiveSpace else { return }
        log.notice("The line was not on the active Space; making its window again")
        let old = panel!
        let content = old.contentView
        old.contentView = NSView()
        old.orderOut(nil)
        let fresh = LinePanel(content: content ?? NSView())
        fresh.onScroll = old.onScroll
        fresh.setFrame(old.frame, display: false)
        fresh.ignoresMouseEvents = old.ignoresMouseEvents
        fresh.alphaValue = old.alphaValue
        panel = fresh
        fresh.orderFrontRegardless()
    }

    private func reveal(pinned: Bool = false, peekFor seconds: TimeInterval = 0) {
        guard isPresent else { return }
        if pinned { self.pinned = true }
        if seconds > 0 { peekUntil = Date().addingTimeInterval(seconds) }
        awaySince = nil
        setRevealed(true)
    }

    private func setRevealed(_ on: Bool) {
        guard on != isRevealed else { return }
        isRevealed = on
        line.revealed = on
        // It always comes down showing the newest.
        if on { line.scroll = 0 }
        // Tucked away, the line leaves no window behind: an invisible strip
        // over the top of the screen would still sit above other apps for
        // anything that checks what is on top, like screen automation.
        if on {
            if isPresent {
                panel.orderFrontRegardless()
                DispatchQueue.main.async { [weak self] in self?.keepOnActiveSpace() }
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.isRevealed else { return }
                self.panel.orderOut(nil)
            }
        }
        if !on {
            pinned = false
            peekUntil = .distantPast
            panel.ignoresMouseEvents = true
            // Opened on purpose lasts until the line tucks away, however that
            // happens: an empty line then goes, as with the shortcut, and over
            // a full screen app the line goes too.
            if keepOpen || openedOnPurpose {
                keepOpen = false
                openedOnPurpose = false
                if line.liveCount == 0 { wanted = false }
                refresh()
            }
        }
    }

    @objc private func toggle() {
        if isRevealed {
            guard noteEditor.close() else { return }
            setRevealed(false)
        } else {
            keepOpen = true
            wanted = true
            openedOnPurpose = true
            panel.placeOnScreen()
            updateCapacity()
            refresh()
            reveal(pinned: true)
        }
    }

    private func startMouseTracking() {
        guard mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func stopMouseTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        panel.ignoresMouseEvents = true
    }

    /// How long the cursor rests against the top edge before the line comes
    /// down. Short enough to feel instant, long enough that a quick trip to
    /// the menu bar does not trigger it.
    private static let revealDelay: TimeInterval = 0.25

    /// The menu bar strip at the top of a screen. With an auto-hiding menu
    /// bar the visible frame reaches the top, so the system thickness is used.
    static func menuBarBand(of screen: NSScreen) -> NSRect {
        var h = screen.frame.maxY - screen.visibleFrame.maxY
        if h < 1 { h = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top) }
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - h, width: screen.frame.width, height: h)
    }

    /// A click anywhere in the top bar of any screen, a menu or an icon, puts the line away.
    private func watchMenuBarClicks() {
        let handler: (NSEvent?) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = NSEvent.mouseLocation
                guard NSScreen.screens.contains(where: { NSMouseInRect(p, Self.menuBarBand(of: $0), false) }) else { return }
                self.menuBarSuppressed = true
                self.hotZoneSince = nil
                if self.isRevealed {
                    self.pinned = false
                    self.setRevealed(false)
                }
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in handler(e); return e }) {
            clickMonitors.append(local)
        }
    }
    /// How long the cursor is away before the line tucks back up.
    private static let retractDelay: TimeInterval = 0.5

    private func tick() {
        if Self.systemChordsEnabled, !chordMonitor.isRunning { _ = chordMonitor.start() }
        let mouse = NSEvent.mouseLocation
        let now = Date()

        let screenUnderPointer = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let inMenuBar = screenUnderPointer.map { NSMouseInRect(mouse, Self.menuBarBand(of: $0), false) } ?? false
        if !inMenuBar { menuBarSuppressed = false }

        guard isRevealed else {
            // Resting in the menu bar brings the line down on that screen.
            // Pushing against the top edge is part of it, and it also works
            // when another display sits above and the pointer never stops.
            // An empty line stays up there: only the shortcut and the menu
            // bring it down on purpose.
            if Self.opensFromMenuBar, let screen = screenUnderPointer,
               inMenuBar, !menuBarSuppressed, !FullScreen.blocksLine(on: screen) {
                let since = hotZoneSince ?? now
                hotZoneSince = since
                if now.timeIntervalSince(since) >= Self.revealDelay {
                    hotZoneSince = nil
                    if panel.screen != screen {
                        panel.placeOnScreen()
                        updateCapacity()
                    }
                    wanted = true
                    keepOpen = true
                    refresh()
                    reveal()
                }
            } else {
                hotZoneSince = nil
            }
            return
        }

        updateMousePassThrough(mouse)

        // The line's zone runs from its lowest point up to the top of the
        // screen, menu bar included, so moving up never hides it.
        var zone = panel.frame
        if let screen = panel.screen { zone.size.height = screen.frame.maxY - zone.minY }
        let inside = NSMouseInRect(mouse, zone, false)
        if inside && pinned { pinned = false }

        let busy = pinned || GrabView.isDragging || GrabView.isShowingMenu
            || line.pressedID != nil || now < peekUntil || noteEditor.isEditing
        if inside || busy {
            awaySince = nil
        } else {
            let since = awaySince ?? now
            awaySince = since
            if now.timeIntervalSince(since) >= Self.retractDelay {
                awaySince = nil
                setRevealed(false)
            }
        }
    }

    /// The panel spans the whole width of the screen, so it only accepts the
    /// mouse while the cursor is over a photo. Everywhere else, clicks go to
    /// whatever is underneath.
    private func updateMousePassThrough(_ mouse: NSPoint) {
        guard !GrabView.isDragging else { return }
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        var overPhoto = line.hitRects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(flipped) }
        // A line longer than the screen also takes the band the photos hang
        // in, gaps included, so a swipe anywhere along it moves it.
        if !overPhoto, line.items.count > line.visibleCount, Line.keepOnLine != nil {
            let band = line.hitRects.values.reduce(CGRect.null) { $0.union($1) }
            overPhoto = !band.isNull && flipped.y >= band.minY - 4 && flipped.y <= band.maxY + 4
        }
        if panel.ignoresMouseEvents == overPhoto {
            panel.ignoresMouseEvents = !overPhoto
        }
    }

    // MARK: Shortcut


    private func setKeep(_ n: Int?) {
        guard n != Line.keepOnLine else { return }
        Line.keepOnLine = n
        updateCapacity()
        line.trim()
    }

    private func setSize(_ size: Layout.Size) {
        guard size != Layout.size else { return }
        Layout.size = size
        panel.placeOnScreen(panel.screen)
        updateCapacity()
        line.reloadThumbnails()
    }

    private func updateCapacity() {
        let usable = panel.frame.width - 200
        let fits = max(3, min(12, Int(usable / Layout.spacing)))
        line.visibleCount = fits
        line.maxItems = max(fits - 1, Line.keepOnLine ?? (fits - 1))
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        let menu = NSMenu()
        // Items say themselves whether they can be used, like Take everything
        // down on an empty line.
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

    }

    /// The shirt fills in while copied images are hung, so it shows at a
    /// glance that the clipboard is being watched. It is dimmed while the
    /// line is empty, so resting in the menu bar and seeing nothing come down
    /// does not look broken.
    private func updateStatusIcon() {
        let on = ClipboardWatcher.isEnabled
        let count = line.liveCount
        let description = on ? L("Tendedero, hanging copied images") : "ClipLine"
        let state = count == 0 ? L("The line is empty") : String(format: L("%d on the line"), count)
        let image = NSImage(systemSymbolName: "paperclip",
                            accessibilityDescription: "\(description), \(state)")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = false
        statusItem.button?.toolTip = "\(description)\n\(state)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(ClosureMenuItem(L("New note")) { [weak self] in self?.newNote() })
        menu.addItem(ClosureMenuItem(L("Region capture · Shift+Z")) { [weak self] in self?.captureRegion() })

        let toggleItem = ClosureMenuItem(isRevealed ? L("Hide line") : L("Show line")) { [weak self] in
            self?.toggle()
        }
        menu.addItem(toggleItem)

        let clearItem = ClosureMenuItem(L("Take everything down")) { [weak self] in
            self?.line.clear()
        }
        clearItem.isEnabled = line.liveCount > 0
        menu.addItem(clearItem)

        let inbox = ClosureMenuItem(L("Handle screenshots")) { [weak self] in
            self?.setInbox(!Inbox.isEnabled)
        }
        inbox.state = Inbox.isEnabled ? .on : .off
        inbox.toolTip = L("Screenshots hang instantly and skip the Desktop")
        menu.addItem(inbox)

        let clipboard = ClosureMenuItem(L("Hang copied images")) { [weak self] in
            self?.setClipboard(!ClipboardWatcher.isEnabled)
        }
        clipboard.state = ClipboardWatcher.isEnabled ? .on : .off
        clipboard.toolTip = L("Images you copy hang on the line too")
        menu.addItem(clipboard)

        let bringDown = NSMenuItem(title: L("Bring the line down"), action: nil, keyEquivalent: "")
        let options = NSMenu()
        let hover = ClosureMenuItem(L("When the pointer rests in the menu bar")) {
            AppDelegate.opensFromMenuBar.toggle()
        }
        hover.state = Self.opensFromMenuBar ? .on : .off
        options.addItem(hover)
        let peek = ClosureMenuItem(L("When something new hangs")) {
            AppDelegate.peeksAtNew.toggle()
        }
        peek.state = Self.peeksAtNew ? .on : .off
        options.addItem(peek)
        let fullScreen = ClosureMenuItem(L("Over full screen apps")) { [weak self] in
            FullScreen.showLineOver.toggle()
            self?.refresh()
        }
        fullScreen.state = FullScreen.showLineOver ? .on : .off
        options.addItem(fullScreen)
        bringDown.submenu = options
        menu.addItem(bringDown)

        let folderItem = NSMenuItem(title: L("Also watch folders"), action: nil, keyEquivalent: "")
        let folderMenu = NSMenu()
        folderMenu.autoenablesItems = false
        let folders = Self.extraFolders
        for folder in folders {
            let item = ClosureMenuItem(FileManager.default.displayName(atPath: folder.path)) {
                NSWorkspace.shared.open(folder)
            }
            item.state = .on
            folderMenu.addItem(item)
        }
        if !folders.isEmpty { folderMenu.addItem(.separator()) }
        let add = ClosureMenuItem(L("Add Folder…")) { [weak self] in self?.chooseExtraFolder() }
        add.isEnabled = folders.count < Self.maxExtraFolders
        folderMenu.addItem(add)
        if !folders.isEmpty {
            let stop = NSMenuItem(title: L("Stop Watching"), action: nil, keyEquivalent: "")
            let stopMenu = NSMenu()
            for folder in folders {
                stopMenu.addItem(ClosureMenuItem(FileManager.default.displayName(atPath: folder.path)) { [weak self] in
                    AppDelegate.extraFolders.removeAll { $0.standardizedFileURL == folder.standardizedFileURL }
                    self?.startWatcher()
                })
            }
            stop.submenu = stopMenu
            folderMenu.addItem(stop)
        }
        folderItem.submenu = folderMenu
        menu.addItem(folderItem)

        let keepItem = NSMenuItem(title: L("Keep on line"), action: nil, keyEquivalent: "")
        let keeps = NSMenu()
        let fit = ClosureMenuItem(L("As many as fit")) { [weak self] in self?.setKeep(nil) }
        fit.state = Line.keepOnLine == nil ? .on : .off
        keeps.addItem(fit)
        for n in Line.keepChoices {
            let item = ClosureMenuItem(String(format: L("%d photos"), n)) { [weak self] in self?.setKeep(n) }
            item.state = Line.keepOnLine == n ? .on : .off
            keeps.addItem(item)
        }
        keepItem.submenu = keeps
        menu.addItem(keepItem)

        let sizeItem = NSMenuItem(title: L("Size"), action: nil, keyEquivalent: "")
        let sizes = NSMenu()
        for (size, title) in [(Layout.Size.small, L("Small")), (.medium, L("Medium")), (.large, L("Large"))] {
            let item = ClosureMenuItem(title) { [weak self] in self?.setSize(size) }
            item.state = Layout.size == size ? .on : .off
            sizes.addItem(item)
        }
        sizeItem.submenu = sizes
        menu.addItem(sizeItem)

        let shortcutInfo = NSMenuItem(title: L("Show / hide · Caps Lock+Shift"), action: nil, keyEquivalent: "")
        shortcutInfo.isEnabled = false
        menu.addItem(shortcutInfo)
        menu.addItem(ClosureMenuItem(L("Screenshot permissions…")) {
            _ = CGRequestScreenCaptureAccess()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        })

        menu.addItem(ClosureMenuItem(L("Open screenshots folder")) { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.watcher.folder)
        })

        menu.addItem(.separator())

        let sound = ClosureMenuItem(L("Sounds")) { [weak self] in
            guard let self else { return }
            self.line.soundOn.toggle()
        }
        sound.state = line.soundOn ? .on : .off
        menu.addItem(sound)

        let login = ClosureMenuItem(L("Open at login")) {
            AppDelegate.toggleLaunchAtLogin()
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        // The app never connects to anything, so it cannot tell when a new
        // version is out. The website can: it is opened with this version
        // and language, and says whether there is a newer one.
        menu.addItem(ClosureMenuItem(L("Check for Updates…")) {
            NSWorkspace.shared.open(AppDelegate.updatesURL)
        })

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Quit ClipLine"), key: "q") {
            NSApp.terminate(nil)
        })
    }

    /// tendedero.app with the running version, and the menus' language when
    /// the website has it too, so the page answers in the same words.
    private static var updatesURL: URL {
        URL(string: "https://github.com/xinna2001/tendedero/releases/latest")!
    }

    private static func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Could not change the login setting")
            alert.informativeText = L("Move Tendedero to the Applications folder and try again.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    // MARK: Quick Look

    /// With no window of ours in front, Quick Look finds its controller here.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLook.shared.take(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLook.shared.release(panel)
    }

}
