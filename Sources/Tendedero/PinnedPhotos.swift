import AppKit
import Combine
import ImageIO

/// Favourite photos occupy a separate, stationary layer above the screenshot row.
/// Their files are app-owned copies; changing or removing a favourite never edits
/// the user's original image or the screenshot history.
@MainActor
final class PinnedPhotos: ObservableObject {
    struct Photo: Identifiable, Equatable {
        let id: UUID
        let url: URL
        var thumbnail: NSImage
        var position: CGFloat
        let tilt: Double

        static func == (lhs: Photo, rhs: Photo) -> Bool {
            lhs.id == rhs.id && lhs.position == rhs.position && lhs.tilt == rhs.tilt &&
            lhs.thumbnail === rhs.thumbnail && lhs.url == rhs.url
        }
    }

    @Published private(set) var photos: [Photo] = []
    @Published var draggingID: UUID?
    var hitRects: [UUID: CGRect] = [:]
    var onChange: (() -> Void)?
    let storageFolder: URL

    static let thumbnailPixels = 320
    static let cardWidth: CGFloat = 150
    static let spacing: CGFloat = 174
    private static let edgeInset: CGFloat = 16
    private static let maximumImageBytes: Int64 = 128 * 1024 * 1024
    private static let maximumImagePixels: Int64 = 100_000_000
    private let defaults: UserDefaults
    private let persists: Bool
    private let storeKey = "pinnedPhotos.v1"

    private struct StoredPhoto: Codable {
        let id: UUID
        let filename: String
        let position: Double
        let tilt: Double
    }

    init(storageFolder: URL? = nil, defaults: UserDefaults = .standard, persists: Bool = true) {
        self.storageFolder = (storageFolder ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                                       in: .userDomainMask)[0]
            .appendingPathComponent("Clipline/PinnedPhotos", isDirectory: true)).standardizedFileURL
        self.defaults = defaults
        self.persists = persists
        if persists { reload() }
    }

    /// Capacity follows the number of normal cards that fit across this screen.
    /// Narrowing a screen hides excess favourites; it never removes their files.
    static func capacity(width: CGFloat) -> Int {
        guard width.isFinite, width >= cardWidth + 2 * edgeInset else { return 0 }
        return min(100, max(0, Int(floor((width - 2 * edgeInset + spacing - cardWidth) / spacing))))
    }

    static func normalizedCenter(atX x: CGFloat, width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0 else { return 0.5 }
        let safeX = x.isFinite ? x : width / 2
        return center(position: safeX / width, width: width) / width
    }

    /// Preserve the relative position across screens while keeping the card in view.
    static func center(position: CGFloat, width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0 else { return 0 }
        let p = position.isFinite ? min(1, max(0, position)) : 0.5
        let inset = min(width / 2, cardWidth / 2 + edgeInset)
        return min(width - inset, max(inset, p * width))
    }

    func visiblePhotos(width: CGFloat) -> [Photo] {
        Array(photos.prefix(Self.capacity(width: width)))
    }

    @discardableResult
    func pin(from source: URL, atX x: CGFloat, width: CGFloat) -> UUID? {
        guard photos.count < Self.capacity(width: width), let thumbnail = thumbnail(from: source) else { return nil }
        let id = UUID()
        guard let ownedURL = copyImage(source, id: id) else { return nil }
        photos.append(Photo(id: id, url: ownedURL, thumbnail: thumbnail,
                            position: Self.normalizedCenter(atX: x, width: width),
                            tilt: .random(in: -2.5...2.5)))
        changed()
        return id
    }

    /// Replacing keeps the selected position and identity, and deletes only the
    /// previous app-owned copy after the replacement has been copied successfully.
    @discardableResult
    func replace(_ id: UUID, from source: URL) -> Bool {
        guard let i = photos.firstIndex(where: { $0.id == id }),
              let thumbnail = thumbnail(from: source) else { return false }
        let replacementID = UUID()
        guard let ownedURL = copyImage(source, id: replacementID) else { return false }
        let oldURL = photos[i].url
        // A replacement gets a new file name, independently of the card identity.
        photos[i] = Photo(id: id, url: ownedURL, thumbnail: thumbnail,
                          position: photos[i].position, tilt: photos[i].tilt)
        changed()
        deleteOwnedFile(oldURL)
        return true
    }

    func move(_ id: UUID, atX x: CGFloat, width: CGFloat) {
        guard let i = photos.firstIndex(where: { $0.id == id }) else { return }
        let position = Self.normalizedCenter(atX: x, width: width)
        guard photos[i].position != position else { return }
        photos[i].position = position
        changed()
    }

    func remove(_ id: UUID) {
        guard let photo = photos.first(where: { $0.id == id }) else { return }
        photos.removeAll { $0.id == id }
        hitRects[id] = nil
        if draggingID == id { draggingID = nil }
        changed()
        deleteOwnedFile(photo.url)
    }

    /// Rebuild thumbnails after relaunch; absent or invalid files stay off the line.
    func reload() {
        guard persists, let data = defaults.data(forKey: storeKey),
              let records = try? JSONDecoder().decode([StoredPhoto].self, from: data) else { return }
        var seen = Set<UUID>()
        photos = records.prefix(100).compactMap { record in
            guard seen.insert(record.id).inserted,
                  Self.isOwnedFilename(record.filename),
                  record.position.isFinite, record.tilt.isFinite else { return nil }
            let url = storageFolder.appendingPathComponent(record.filename)
            guard let thumbnail = thumbnail(from: url) else { return nil }
            return Photo(id: record.id, url: url, thumbnail: thumbnail,
                         position: min(1, max(0, CGFloat(record.position))),
                         tilt: min(2.5, max(-2.5, record.tilt)))
        }
        hitRects = [:]
        onChange?()
    }

    private func changed() {
        if persists {
            let records = photos.map { StoredPhoto(id: $0.id, filename: $0.url.lastPathComponent,
                                                   position: Double($0.position), tilt: $0.tilt) }
            if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: storeKey) }
        }
        onChange?()
    }

    private func copyImage(_ source: URL, id: UUID) -> URL? {
        guard source.isFileURL else { return nil }
        let ext = source.pathExtension.lowercased()
        let safeExtension = ext.isEmpty || ext.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) != nil ? "image" : ext
        let destination = storageFolder.appendingPathComponent(id.uuidString).appendingPathExtension(safeExtension)
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.createDirectory(at: storageFolder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source.resolvingSymlinksInPath(), to: destination)
            return destination
        } catch { return nil }
    }

    private func deleteOwnedFile(_ url: URL) {
        guard url.standardizedFileURL.deletingLastPathComponent() == storageFolder,
              Self.isOwnedFilename(url.lastPathComponent) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func isOwnedFilename(_ name: String) -> Bool {
        guard !name.contains("/"), !name.contains("\\"),
              UUID(uuidString: (name as NSString).deletingPathExtension) != nil else { return false }
        let ext = (name as NSString).pathExtension
        return !ext.isEmpty && ext.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) == nil
    }

    private func thumbnail(from url: URL) -> NSImage? {
        guard url.isFileURL else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let resolvedURL = url.resolvingSymlinksInPath()
        guard let values = try? resolvedURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let bytes = values.fileSize,
              bytes > 0, Int64(bytes) <= Self.maximumImageBytes,
              let source = CGImageSourceCreateWithURL(resolvedURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.int64Value > 0, height.int64Value > 0,
              width.int64Value <= Self.maximumImagePixels / height.int64Value else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.thumbnailPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
