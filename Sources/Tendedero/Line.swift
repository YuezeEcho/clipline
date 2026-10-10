import AppKit
import Combine
import os

let log = Logger(subsystem: "local.clipline.app", category: "line")

/// One screenshot hanging on the line.
struct Pegged: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var thumb: NSImage
    var isVideo: Bool { CaptureMedia.isVideo(url) }
    /// Every photo hangs a little crooked, like on a real line.
    let tilt = Double.random(in: -2.5...2.5)
    var falling = false
    /// Still flying in from where it was captured; the card waits hidden.
    var flying = false

    static func == (a: Pegged, b: Pegged) -> Bool {
        a.id == b.id && a.falling == b.falling && a.flying == b.flying && a.thumb === b.thumb
    }
}

/// The line itself: what hangs on it and what you can do with each item.
/// Browsing and taking down preserve files; explicit deletion uses the Trash.
@MainActor
final class Line: ObservableObject {
    enum Section { case screenshots, clipboard }
    @Published var section: Section = .screenshots {
        didSet {
            if section != .screenshots {
                videoPreview.stop()
                screenshotScrollView = nil
                scrollSway.reset()
            }
        }
    }
    let scrollSway = ScrollSway()
    let videoPreview = VideoPreview()
    var controlsRect: CGRect = .zero
    var interactionRect: CGRect = .zero
    @Published private(set) var items: [Pegged] = []
    @Published private(set) var gust = 0
    @Published var copiedID: UUID?
    @Published var draggingID: UUID?
    @Published var pressedID: UUID?
    /// Whether the line has slid down into view.
    @Published var revealed = false {
        didSet {
            if !revealed {
                videoPreview.stop()
                scrollSway.reset()
            } else if section == .screenshots, let scroll = screenshotScrollView {
                // The row can stay mounted while hidden. Seed its current
                // position so the first gesture after reopening also sways.
                scrollSway.record(offset: scroll.contentView.bounds.minX,
                                  viewportWidth: scroll.contentView.bounds.width,
                                  contentWidth: scroll.documentView?.bounds.width ?? 0)
            }
        }
    }
    @Published var showsControls = true {
        didSet {
            if persistsScreenshots { UserDefaults.standard.set(showsControls, forKey: "showLineControls") }
            if !showsControls { controlsRect = .zero }
        }
    }
    /// Context menus, photo picking and fixed-photo positioning keep the line open.
    private(set) var interactionDepth = 0
    func beginInteraction() { interactionDepth += 1 }
    func endInteraction() { interactionDepth = max(0, interactionDepth - 1) }
    var onRequestPin: ((CGFloat, CGFloat) -> Void)?
    var onRequestReplacePin: ((UUID) -> Void)?
    var canPinPhoto: ((CGFloat) -> Bool)?
    var onRequestOpen: ((URL) -> Void)?
    var onRequestSystemOpen: ((URL) -> Void)?
    var onTrashError: ((URL, Error) -> Void)?
    weak var screenshotScrollView: NSScrollView?


    /// Card frames in window coordinates, reported by the views. The panel
    /// uses them to only catch clicks over photos and let the rest through.
    var hitRects: [UUID: CGRect] = [:]
    /// Resting, unrotated frames for the flight animator; hitRects include sway.
    var cardLayoutRects: [UUID: CGRect] = [:]

    /// Keep a bounded thumbnail history; the full screenshots stay on disk.
    let maxItems = 100
    static let thumbnailPixels = 320


    var soundOn: Bool {
        get { !UserDefaults.standard.bool(forKey: "soundOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "soundOff") }
    }

    var liveCount: Int { items.filter { !$0.falling }.count }

    private let storeKey = "pegged"
    private let persistsScreenshots: Bool
    private let trashFile: (URL) throws -> Void
    /// Only live cards retain a stamp. Checking metadata is cheap; decoding
    /// again is reserved for images saved by an external editor.
    private var thumbnailStamps: [UUID: ThumbnailStamp] = [:]

    private struct ThumbnailStamp: Equatable {
        let modified: Date
        let bytes: UInt64
        let fileNumber: UInt64?

        static func read(_ url: URL) -> Self? {
            guard url.isFileURL,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modified = attributes[.modificationDate] as? Date,
                  let bytes = attributes[.size] as? NSNumber else { return nil }
            return Self(modified: modified, bytes: bytes.uint64Value,
                        fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
        }
    }

    init(persistsScreenshots: Bool = true, restoresSavedCaptures: Bool = true,
         trashFile: @escaping (URL) throws -> Void = {
             try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
         }) {
        self.persistsScreenshots = persistsScreenshots
        self.trashFile = trashFile
        if persistsScreenshots {
            showsControls = UserDefaults.standard.object(forKey: "showLineControls") as? Bool ?? true
            if restoresSavedCaptures { restore() }
            scheduleGust()
        }
    }

    // MARK: Hanging and dropping

    @discardableResult
    func hang(_ sourceURL: URL, quietly: Bool = false, flying: Bool = false, thumbnail: NSImage? = nil) -> UUID? {
        let url = sourceURL.standardizedFileURL.absoluteURL
        guard !items.contains(where: { $0.url.standardizedFileURL.path == url.path && !$0.falling }) else { return nil }
        let stamp = ThumbnailStamp.read(url)
        guard let thumb = thumbnail ?? CaptureMedia.thumbnail(url, maxPixels: Self.thumbnailPixels) else { return nil }
        var item = Pegged(url: url, thumb: thumb)
        item.flying = flying
        items.append(item)
        thumbnailStamps[item.id] = stamp
        // A full line lets the oldest photo fall off the far end.
        while liveCount > maxItems, let oldest = items.first(where: { !$0.falling }) {
            drop(oldest.id, quietly: true)
        }
        save()
        if !quietly { play("Tink", volume: 0.35) }
        return item.id
    }

    /// Replace the selected folder's row in one update. The old files stay on
    /// disk, and the independent PinnedPhotos collection is never touched.
    func replaceContents(_ cards: [CaptureLibrary.Card], saveChanges: Bool = true) {
        videoPreview.stop()
        items = cards.suffix(maxItems).map { Pegged(url: $0.url, thumb: $0.thumbnail) }
        thumbnailStamps = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            ThumbnailStamp.read(item.url).map { (item.id, $0) }
        })
        hitRects.removeAll()
        cardLayoutRects.removeAll()
        copiedID = nil
        pressedID = nil
        draggingID = nil
        if saveChanges { save() }
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
        videoPreview.stop(id)
        onFall?(items[i])
        items[i].falling = true
        thumbnailStamps[id] = nil
        hitRects[id] = nil
        save()
        if !quietly { play("Pop", volume: 0.25) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.items.removeAll { $0.id == id }
        }
    }

    func clear() {
        let live = items.filter { !$0.falling }
        for (n, item) in live.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(n)) { [weak self] in
                self?.drop(item.id, quietly: n > 0)
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
        if !item.isVideo, let png = pngData(item.url) { entry.setData(png, forType: .png) }
        entry.setString(item.url.absoluteString, forType: .fileURL)
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
        if let onRequestOpen { onRequestOpen(item.url) }
        else { NSWorkspace.shared.open(item.url) }
    }

    func openInSystemEditor(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), !item.isVideo else { return }
        if let onRequestSystemOpen { onRequestSystemOpen(item.url) }
        else { SystemImageOpener.openInPreview(item.url) }
    }

    /// Moves the file to the Trash and takes the photo off the line. When a
    /// drag ends on the Dock's Trash, macOS only reports it: deleting the file
    /// is the source app's job, as Finder does.
    func trash(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), !item.falling else { return }
        do {
            try trashFile(item.url)
            log.notice("Trashed \(item.url.lastPathComponent, privacy: .public)")
            if soundOn { Line.trashSound?.play() }
            drop(id, quietly: true)
        } catch {
            log.error("Could not trash \(item.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            if let onTrashError { onTrashError(item.url, error) }
            else { NSSound.beep() }
        }
    }

    private static let trashSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif",
        byReference: true)

    /// Used only to offer Save to Desktop for files in the default inbox.
    func isInInbox(_ id: UUID) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        return Inbox.contains(item.url)
    }

    /// The corner cross always means deletion, whatever capture folder is selected.
    func discard(_ id: UUID) { trash(id) }

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

    /// Pick up saves from the default image editor without repeatedly decoding
    /// unchanged images. A failed or still-changing save keeps the previous
    /// thumbnail and stamp so the next refresh can retry.
    func refreshChangedThumbnails() {
        for i in items.indices where !items[i].falling {
            let item = items[i]
            guard let stamp = ThumbnailStamp.read(item.url),
                  stamp != thumbnailStamps[item.id], !item.isVideo,
                  let thumb = makeThumbnail(item.url, maxPixels: Self.thumbnailPixels),
                  ThumbnailStamp.read(item.url) == stamp else { continue }
            items[i].thumb = thumb
            thumbnailStamps[item.id] = stamp
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
            if self.revealed && self.draggingID == nil { self.gust += 1 }
            self.scheduleGust()
        }
    }

    // MARK: Persistence

    func savedPaths(in locations: CaptureLocations) -> [String]? {
        guard persistsScreenshots,
              UserDefaults.standard.stringArray(forKey: "captureFolders") == locations.folders.map(\.path) else { return nil }
        return UserDefaults.standard.stringArray(forKey: storeKey)
    }

    func rememberFolders(_ locations: CaptureLocations) {
        if persistsScreenshots { UserDefaults.standard.set(locations.folders.map(\.path), forKey: "captureFolders") }
    }

    private func save() {
        guard persistsScreenshots else { return }
        let paths = items.filter { !$0.falling }.map(\.url.path)
        UserDefaults.standard.set(paths, forKey: storeKey)
    }

    private func restore() {
        let paths = UserDefaults.standard.stringArray(forKey: storeKey) ?? []
        for path in paths where FileManager.default.fileExists(atPath: path) {
            hang(URL(fileURLWithPath: path), quietly: true)
        }
    }

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

func makeThumbnail(_ url: URL, maxPixels: Int = 480) -> NSImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}
