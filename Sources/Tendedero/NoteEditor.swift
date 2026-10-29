import AppKit
import ClipLineCore

/// A writable sheet below the clip. The app keeps the line open while editing.
@MainActor
final class NoteEditor: NSObject, NSTextViewDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var textView: NSTextView?
    private var status: NSTextField?
    private var note: NoteRecord?
    private var store: NoteStore?
    private var saveWork: DispatchWorkItem?
    var onSaved: (URL) -> Void = { _ in }
    var onClosed: () -> Void = {}
    var isEditing: Bool { window?.isVisible == true }

    func open(_ note: NoteRecord, store: NoteStore, anchor: NSPoint) {
        if self.note?.id == note.id, let window, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil); return
        }
        guard close() else { return }
        self.note = note; self.store = store
        let panel = NoteWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 310),
                            styleMask: [.titled, .closable, .resizable],
                            backing: .buffered, defer: false)
        panel.title = L("Edit note")
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = NSColor(srgbRed: 1, green: 0.975, blue: 0.86, alpha: 1)
        panel.delegate = self
        panel.minSize = NSSize(width: 300, height: 200)
        let content = panel.contentView!
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 42, width: 420, height: 268))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let text = NSTextView(frame: scroll.bounds)
        text.isRichText = false
        text.isEditable = true
        text.isSelectable = true
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.font = .systemFont(ofSize: 17)
        text.textColor = .darkGray
        text.backgroundColor = panel.backgroundColor
        text.textContainerInset = NSSize(width: 18, height: 18)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.string = note.text
        text.delegate = self
        text.setAccessibilityLabel(L("Note text"))
        scroll.documentView = text
        content.addSubview(scroll)
        let label = NSTextField(labelWithString: L("Saved locally"))
        label.frame = NSRect(x: 18, y: 12, width: 265, height: 18)
        label.autoresizingMask = [.width]
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        content.addSubview(label)
        let paste = NSButton(title: L("Paste"), target: self, action: #selector(pasteText))
        paste.frame = NSRect(x: 308, y: 8, width: 94, height: 28)
        paste.autoresizingMask = [.minXMargin]
        paste.bezelStyle = .rounded
        content.addSubview(paste)
        let screen = NSScreen.screens.first { $0.visibleFrame.contains(anchor) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
        panel.setFrameOrigin(NSPoint(x: min(max(anchor.x - 210, bounds.minX), bounds.maxX - 420),
                                     y: max(bounds.minY, min(anchor.y - 340, bounds.maxY - 340))))
        self.window = panel; self.textView = text; self.status = label
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(text)
    }

    @objc private func pasteText() {
        guard let textView else { return }
        window?.makeFirstResponder(textView)
        textView.paste(nil)
    }

    func textDidChange(_ notification: Notification) {
        status?.stringValue = L("Saving…")
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    @discardableResult
    func save() -> Bool {
        saveWork?.cancel(); saveWork = nil
        guard let note, let store, let textView else { return true }
        do {
            self.note = try store.update(note.id, text: textView.string, expectedRevision: note.revision)
            status?.stringValue = L("Saved locally")
            onSaved(store.url(for: note.id))
            return true
        } catch {
            status?.stringValue = error.localizedDescription
            return false
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { save() }
    @discardableResult
    func close() -> Bool {
        guard save() else { return false }
        window?.close()
        return true
    }
    func windowWillClose(_ notification: Notification) {
        saveWork?.cancel(); saveWork = nil
        window = nil; note = nil; textView = nil
        onClosed()
    }

    /// Flush or report conflict before Botmux updates the same open note.
    func prepareExternalUpdate(_ id: UUID) throws {
        if note?.id == id, !save() { throw NoteStoreError.conflict }
    }
    func refresh(_ updated: NoteRecord) {
        guard note?.id == updated.id else { return }
        note = updated; textView?.string = updated.text
        status?.stringValue = L("Saved locally")
    }
    #if DEBUG
    func insertForUIChecks(_ text: String) -> Bool {
        guard let textView, let window, isEditing else { return false }
        textView.insertText(text, replacementRange: NSRange(location: 0, length: (textView.string as NSString).length))
        guard save() else { return false }
        if let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: ClipPaths.base.appendingPathComponent("editor-preview.png"))
        }
        return true
    }
    func pasteForUIChecks(_ expected: String) -> Bool {
        guard let textView, let window else { return false }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9) else { return false }
        let handled = window.performKeyEquivalent(with: event)
        guard handled && textView.string == expected && save() else { return false }
        if let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: ClipPaths.base.appendingPathComponent("editor-preview.png"))
        }
        return true
    }
    #endif
}

private final class NoteWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
