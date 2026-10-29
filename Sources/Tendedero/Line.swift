import AppKit
import AVFoundation
import Combine
import os
import ClipLineCore

let log = Logger(subsystem: "com.xinna2001.ClipLine", category: "line")

/// One screenshot hanging on the line.
struct Pegged: Identifiable, Equatable {
    let id: UUID
    let url: URL
    var thumb: NSImage
    /// Every photo hangs a little crooked, like on a real line.
    let tilt = Double.random(in: -2.5...2.5)
    var falling = false
    /// Still flying in from where it was captured; the card waits hidden.
    var flying = false
    /// A screen recording rather than a screenshot.
    var isRecording: Bool { Tendedero.isRecording(url) }
    var isNote: Bool { url.pathExtension == "clipnote" }

    init(url: URL, thumb: NSImage) {
        self.url = url; self.thumb = thumb
        self.id = (url.pathExtension == "clipnote" ? UUID(uuidString: url.deletingPathExtension().lastPathComponent) : nil) ?? UUID()
    }

    static func == (a: Pegged, b: Pegged) -> Bool {
        a.id == b.id && a.falling == b.falling && a.flying == b.flying && a.thumb === b.thumb
    }
}

/// The line itself: what hangs on it and what you can do with each item.
/// The files never move. The line is only a view onto them.
@MainActor
final class Line: ObservableObject {
    @Published private(set) var items: [Pegged] = []
    @Published private(set) var gust = 0
    @Published var copiedID: UUID?
    @Published var draggingID: UUID?
    @Published var pressedID: UUID?
    /// Whether the line has slid down into view.
    @Published var revealed = false

    /// Card frames in window coordinates, reported by the views. The panel
    /// uses them to only catch clicks over photos and let the rest through.
    var hitRects: [UUID: CGRect] = [:]
    static let emptyClipID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let newLayerClipID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    var onNewNote: () -> Void = {}
    var onNewLayer: () -> Void = {}
    var onEditNote: (UUID) -> Void = { _ in }
    var onDeleteNote: (UUID) -> Void = { _ in }
    var onError: (String) -> Void = { _ in }
    @Published private(set) var layers: [LayerRecord] = []
    @Published private(set) var activeLayerID: UUID?
    private var layerStore: LayerStore?
    private(set) var storageError: String?

    var activeLayerName: String { layers.first { $0.id == activeLayerID }?.name ?? L("Daily") }
    var layerPosition: String {
        "\(activeLayerName) · \((layers.firstIndex { $0.id == activeLayerID } ?? 0) + 1)/\(max(1, layers.count))"
    }

    var maxItems = Int.max
    /// How many photos fit across the screen. With Keep on line set, the
    /// line can hold more, and the rest are reached by scrolling.
    var visibleCount = 8
    /// How far the line is scrolled towards older photos, in points; 0 shows
    /// the newest.
    @Published var scroll: CGFloat = 0

    /// Keep on line, from the menu bar: how many photos the line keeps, or
    /// nil for as many as fit across the screen.
    nonisolated static let keepChoices = [25, 50, 100]
    nonisolated static var keepOnLine: Int? {
        get {
            let n = ClipSettings.defaults.integer(forKey: "keepOnLine")
            return keepChoices.contains(n) ? n : nil
        }
        set { ClipSettings.defaults.set(newValue ?? 0, forKey: "keepOnLine") }
    }


    var soundOn: Bool {
        get { !ClipSettings.defaults.bool(forKey: "soundOff") }
        set { ClipSettings.defaults.set(!newValue, forKey: "soundOff") }
    }

    var liveCount: Int { items.filter { !$0.falling }.count }

    private let storeKey = "pegged"

    init() {
        restore()
        scheduleGust()
    }

    // MARK: Hanging and dropping

    @discardableResult
    func hang(_ url: URL, quietly: Bool = false, flying: Bool = false) -> UUID? {
        guard !items.contains(where: { $0.url == url && !$0.falling }) else { return nil }
        guard let layerStore, layerStore.layer(containing: url.path) == nil,
              let thumb = makeThumbnail(url) else { return nil }
        do { try layerStore.replaceActivePaths(items.filter { !$0.falling }.map(\.url.path) + [url.path]) }
        catch { onError(error.localizedDescription); return nil }
        var item = Pegged(url: url, thumb: thumb)
        item.flying = flying
        items.append(item)
        layers = layerStore.layers
        scroll = 0
        // A full line lets the oldest photo fall off the far end. Only one: a
        // line hung on a wider screen keeps its length here instead of losing
        // several photos to a single capture.
        if liveCount > maxItems, let oldest = items.first(where: { !$0.falling }) {
            letGo(oldest.id)
        }
        if !quietly { play("Tink", volume: 0.35) }
        return item.id
    }

    /// The capture has reached the line: the real card takes over.
    func land(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].flying = false
    }

    /// Called just before a photo starts falling, so the fall can be drawn
    /// over the whole screen.
    var onFall: ((Pegged) -> Void)?

    func drop(_ id: UUID, quietly: Bool = false) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].falling else { return }
        guard save(excluding: id) else { return }
        onFall?(items[i])
        items[i].falling = true
        hitRects[id] = nil
        if !quietly { play("Pop", volume: 0.25) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.items.removeAll { $0.id == id && $0.falling }
        }
    }

    /// "Take everything down": every photo goes the way of its corner cross.
    func clear() {
        takeDown(items.filter { !$0.falling })
    }

    /// The photos hung before (left) or after (right) this one.
    func neighbours(of id: UUID, toTheLeft: Bool) -> [Pegged] {
        let live = items.filter { !$0.falling }
        guard let i = live.firstIndex(where: { $0.id == id }) else { return [] }
        return toTheLeft ? Array(live[..<i]) : Array(live[(i + 1)...])
    }

    /// Taking cards down only removes their membership in the active layer.
    func takeDown(_ id: UUID, toTheLeft: Bool) {
        takeDown(neighbours(of: id, toTheLeft: toTheLeft))
    }

    /// One after another, and only the first makes a sound.
    private func takeDown(_ live: [Pegged]) {
        for (n, item) in live.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(n)) { [weak self] in
                self?.discard(item.id, quietly: n > 0)
            }
        }
    }

    /// Photos whose file was deleted or moved away fall off by themselves.
    func prune() {
        for item in items where !item.falling && !FileManager.default.fileExists(atPath: item.url.path) {
            drop(item.id, quietly: true)
        }
    }

    // MARK: Actions on one photo

    func copy(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let entry = NSPasteboardItem()
        // A recording is copied as the file, which apps paste as the video.
        if item.isNote, let note = try? NoteStore.decode(item.url) {
            entry.setString(note.text, forType: .string)
        } else if !item.isRecording, let png = pngData(item.url) { entry.setData(png, forType: .png) }
        if !item.isNote { entry.setString(item.url.absoluteString, forType: .fileURL) }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([entry])

        copiedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copiedID == id { self?.copiedID = nil }
        }
    }

    func open(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.open(item.url)
    }

    /// Moves the file to the Trash and takes the photo off the line. When a
    /// drag ends on the Dock's Trash, macOS only reports it: deleting the file
    /// is the source app's job, as Finder does.
    @discardableResult
    func trash(_ id: UUID, quietly: Bool = false) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        guard layerStore != nil else { return false }
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            log.notice("Trashed \(item.url.lastPathComponent, privacy: .public)")
            if soundOn && !quietly { Line.trashSound?.play() }
            drop(id, quietly: true)
            return true
        } catch {
            log.error("Could not trash \(item.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            if !quietly { NSSound.beep() }
            return false
        }
    }

    private static let trashSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif",
        byReference: true)

    /// Whether the file lives in Tendedero's own folder. Those are discarded
    /// to the Trash, or the folder would fill up with forgotten screenshots.
    /// Files anywhere else, like the Desktop, stay where they are.
    func isInInbox(_ id: UUID) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        return item.url.standardizedFileURL.path.hasPrefix(Inbox.folder.standardizedFileURL.path + "/")
    }

    /// The corner cross and "Take down" both end up here.
    func discard(_ id: UUID, quietly: Bool = false) {
        drop(id, quietly: quietly)
    }

    /// Moves along a line that holds more than fit, from a scroll gesture.
    func scroll(by delta: CGFloat) {
        let most = CGFloat(max(0, items.count - (visibleCount - 1))) * Layout.spacing
        let next = min(most, max(0, scroll + delta))
        if next != scroll { scroll = next }
    }

    /// After Keep on line is lowered, the oldest photos past it go the way
    /// of a full line.
    func trim() {
        while liveCount > maxItems, let oldest = items.first(where: { !$0.falling }) {
            let before = liveCount
            letGo(oldest.id)
            if liveCount == before { break }
        }
        scroll = 0
    }

    private func letGo(_ id: UUID) {
        drop(id, quietly: true)
    }

    /// Inbox mode: keep a screenshot by moving it to the Desktop.
    func saveToDesktop(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let target = uniqueURL(in: desktop, for: item.url.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: item.url, to: target)
            drop(id, quietly: true)
        } catch {
            log.error("Could not save to Desktop: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    private func uniqueURL(in folder: URL, for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    /// Long press: open the photo in the system Markup editor. Markup does
    /// not edit video, so a recording opens in the trimming editor instead.
    func markup(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if item.isNote {
            onEditNote(item.id)
        } else if item.isRecording {
            Trim.shared.edit(item.url, size: item.thumb.size)
        } else {
            Markup.shared.edit(item.url)
        }
    }

    /// After editing, the photo on the line shows the new version.
    func reloadThumbnail(for url: URL) {
        guard let i = items.firstIndex(where: { $0.url == url && !$0.falling }),
              let thumb = makeThumbnail(url) else { return }
        items[i].thumb = thumb
    }

    /// Quick Look on this photo, with the rest of the line a key press away.
    func quickLook(_ id: UUID) {
        let live = items.filter { !$0.falling }
        guard let index = live.firstIndex(where: { $0.id == id }) else { return }
        QuickLook.shared.show(live.map(\.url), at: index)
    }

    /// After a change of size, every photo is redrawn sharp at the new one.
    func reloadThumbnails() {
        for i in items.indices where !items[i].falling {
            if let thumb = makeThumbnail(items[i].url) { items[i].thumb = thumb }
        }
    }

    func reveal(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: Breeze

    /// Every so often a little wind moves the line. It is the detail that
    /// makes it feel like an object and not a widget.
    private func scheduleGust() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 7...16)) { [weak self] in
            guard let self else { return }
            if !self.items.isEmpty && self.draggingID == nil { self.gust += 1 }
            self.scheduleGust()
        }
    }

    // MARK: Persistence

    @discardableResult
    private func save(excluding id: UUID? = nil) -> Bool {
        guard let layerStore else { return false }
        do {
            try layerStore.replaceActivePaths(items.filter { !$0.falling && $0.id != id }.map(\.url.path))
            layers = layerStore.layers
            return true
        } catch { onError(error.localizedDescription); return false }
    }

    /// Everything comes back as it was. This runs before the line knows its
    /// screen, so the capacity is still the default one: hanging through
    /// `hang` would let photos fall off a wide screen's line at every launch.
    private func restore() {
        do {
            layerStore = try LayerStore(url: ClipPaths.base.appendingPathComponent("layers.json"),
                legacyPaths: ClipSettings.defaults.stringArray(forKey: storeKey) ?? [], firstName: L("Daily"))
            restoreActiveLayer()
        } catch {
            storageError = error.localizedDescription
            log.error("Could not read layers; the original data was preserved")
        }
    }

    private func restoreActiveLayer() {
        guard let layerStore else { return }
        items = []
        layers = layerStore.layers
        activeLayerID = layerStore.activeID
        scroll = 0
        hitRects = [:]
        copiedID = nil; draggingID = nil; pressedID = nil
        let paths = layerStore.active.paths
        for path in paths where FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            guard !items.contains(where: { $0.url == url }), let thumb = makeThumbnail(url) else { continue }
            items.append(Pegged(url: url, thumb: thumb))
        }
    }

    @discardableResult
    func createLayer() -> Bool {
        guard let layerStore else { return false }
        do {
            _ = try layerStore.create(name: String(format: L("Layer %d"), layers.count + 1))
            restoreActiveLayer()
            return true
        } catch { onError(error.localizedDescription); return false }
    }

    @discardableResult
    func selectLayer(_ id: UUID? = nil) -> Bool {
        guard let layerStore else { return false }
        do {
            if let id { try layerStore.select(id) } else { try layerStore.selectNext() }
            restoreActiveLayer()
            return true
        } catch { onError(error.localizedDescription); return false }
    }

    func renameLayer(_ name: String) {
        guard let layerStore else { return }
        let value = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        guard !value.isEmpty else { return }
        do {
            try layerStore.renameActive(value)
            layers = layerStore.layers
        } catch { onError(error.localizedDescription) }
    }

    func layerContaining(_ url: URL) -> UUID? { layerStore?.layer(containing: url.path)?.id }

    // MARK: Helpers

    private func play(_ name: String, volume: Float) {
        guard soundOn, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }

    private func pngData(_ url: URL) -> Data? {
        if url.pathExtension.lowercased() == "png" { return try? Data(contentsOf: url) }
        guard let tiff = NSImage(contentsOf: url)?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Screen recordings, as macOS saves them.
func isRecording(_ url: URL) -> Bool {
    ["mov", "mp4"].contains(url.pathExtension.lowercased())
}

/// The default size covers a card at twice its size in points, as on a
/// Retina screen, and no more: every photo on the line keeps one in memory.
func makeThumbnail(_ url: URL, maxPixels: Int = Int(320 * Layout.size.scale)) -> NSImage? {
    if url.pathExtension == "clipnote" { return makeNoteThumbnail(url, maxPixels: maxPixels) }
    if isRecording(url) { return firstFrame(url, maxPixels: maxPixels) }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

/// Only the preview is abbreviated; the full text stays in NoteStore.
func makeNoteThumbnail(_ url: URL, maxPixels: Int) -> NSImage? {
    guard let note = try? NoteStore.decode(url) else { return nil }
    let image = NSImage(size: NSSize(width: 360, height: 280))
    image.lockFocus()
    NSColor(srgbRed: 1, green: 0.975, blue: 0.86, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 360, height: 280).fill()
    let text = note.text.isEmpty ? L("Double-click to write a note") : String(note.text.prefix(4000))
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byWordWrapping
    style.lineSpacing = 4
    NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: 23), .foregroundColor: NSColor.darkGray, .paragraphStyle: style
    ]).draw(with: NSRect(x: 22, y: 20, width: 316, height: 240),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    image.unlockFocus()
    return image
}

/// A recording shows its first frame.
private func firstFrame(_ url: URL, maxPixels: Int) -> NSImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
    guard let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}
