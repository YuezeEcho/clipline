import AppKit
import ImageIO

/// Every fixture and image copy lives in a disposable test directory. These
/// checks never read standard app preferences or touch the user's photo files.
@main
struct PinnedPhotosChecks {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAIL: " + message) }
            checks += 1
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("clipline-pinned-checks-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let suite = "local.clipline.pinned-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = root.appendingPathComponent("Owned", isDirectory: true)
        let original = root.appendingPathComponent("Original.png")
        let other = root.appendingPathComponent("Replacement.png")
        func writeImage(_ url: URL, color: NSColor) throws -> Data {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 400,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                          isPlanar: false, colorSpaceName: .deviceRGB,
                                          bytesPerRow: 0, bitsPerPixel: 0)!
            for y in 0..<400 { for x in 0..<640 { bitmap.setColor(color, atX: x, y: y) } }
            let data = bitmap.representation(using: .png, properties: [:])!
            try data.write(to: url)
            return data
        }
        let originalData = try writeImage(original, color: NSColor(calibratedRed: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        let otherData = try writeImage(other, color: NSColor(calibratedRed: 0.9, green: 0.3, blue: 0.1, alpha: 1))
        let invalid = root.appendingPathComponent("Invalid.png")
        try Data([1, 2, 3]).write(to: invalid)

        let history = PinnedPhotos(storageFolder: folder, defaults: defaults)
        check(history.photos.isEmpty, "initial favourites are empty")
        check(!fm.fileExists(atPath: folder.path), "starting creates no directories")
        check(PinnedPhotos.capacity(width: 181) == 0, "insufficient width cannot show a full card")
        check(PinnedPhotos.capacity(width: 182) == 1, "first full card capacity")
        check(PinnedPhotos.capacity(width: 1440) == 8, "wide-screen capacity follows card spacing")
        check(PinnedPhotos.capacity(width: .infinity) == 0, "non-finite width is rejected")
        check(PinnedPhotos.capacity(width: -1) == 0, "negative width is rejected")
        check(PinnedPhotos.center(position: -2, width: 1000) == 91, "left edge keeps the whole card visible")
        check(PinnedPhotos.center(position: 2, width: 1000) == 909, "right edge keeps the whole card visible")
        check(PinnedPhotos.center(position: 0.7, width: 100) == 50, "small screen collapses the position to the centre")
        check(PinnedPhotos.normalizedCenter(atX: .nan, width: 1000) == 0.5, "invalid click uses centre")
        check(PinnedPhotos.normalizedCenter(atX: 5, width: 0) == 0.5, "invalid width has stable normalized position")
        check(history.pin(from: original, atX: 50, width: 100) == nil, "cannot pin when no card fits")
        check(history.pin(from: invalid, atX: 50, width: 1000) == nil, "invalid image is rejected")
        check(history.pin(from: root, atX: 50, width: 1000) == nil, "directories are rejected")
        check(history.pin(from: root.appendingPathComponent("Missing.png"), atX: 50, width: 1000) == nil, "missing image is rejected")
        check(history.pin(from: URL(string: "https://example.invalid/image.png")!, atX: 50, width: 1000) == nil, "remote URLs are rejected")

        let id = history.pin(from: original, atX: 500, width: 1000)!
        let first = history.photos[0]
        check(first.id == id && first.position == 0.5, "card records clicked normalized position")
        check(first.url.deletingLastPathComponent() == folder, "image lives in private storage")
        check(first.url != original && (try? Data(contentsOf: first.url)) == originalData, "private copy preserves the original image bytes")
        check(max(first.thumbnail.size.width, first.thumbnail.size.height) <= 320, "only a bounded 320-pixel thumbnail is retained")
        check((-2.5...2.5).contains(first.tilt), "crooked tilt stays subtle")
        check(history.visiblePhotos(width: 100).isEmpty && history.photos.count == 1, "narrow screen hides but never deletes favourites")

        var notifications = 0
        history.onChange = { notifications += 1 }
        history.move(id, atX: 850, width: 1000)
        check(history.photos[0].position == 0.85 && notifications == 1, "moving updates persisted normalized position")
        history.move(id, atX: 850, width: 1000)
        check(notifications == 1, "unchanged movement avoids unnecessary preference writes")
        let restored = PinnedPhotos(storageFolder: folder, defaults: defaults)
        check(restored.photos.count == 1 && restored.photos[0].id == id, "favourite identity survives restart")
        check(restored.photos[0].position == 0.85 && restored.photos[0].tilt == first.tilt, "position and tilt survive restart")
        check(PinnedPhotos.center(position: restored.photos[0].position, width: 2000) == 1700, "screen size change preserves relative location")

        check(!history.replace(id, from: invalid) && history.photos[0].url == first.url, "invalid replacement preserves existing photo")
        check(history.replace(id, from: other), "valid replacement succeeds")
        let replacement = history.photos[0]
        check(replacement.id == id && replacement.position == 0.85 && replacement.tilt == first.tilt, "replacement preserves position, tilt and identity")
        check(!fm.fileExists(atPath: first.url.path) && (try? Data(contentsOf: replacement.url)) == otherData, "replacement deletes previous app copy only after new copy succeeds")
        check((try? Data(contentsOf: original)) == originalData && (try? Data(contentsOf: other)) == otherData, "source images are never edited by replacement")
        restored.reload()
        check(restored.photos.first?.url == replacement.url, "reload picks up replacement file name")
        history.remove(UUID())
        check(history.photos.count == 1, "unknown removal is harmless")

        let twoCardScreen: CGFloat = 356
        let secondID = history.pin(from: original, atX: 100, width: twoCardScreen)!
        check(history.pin(from: original, atX: 100, width: twoCardScreen) == nil && history.photos.count == 2, "capacity rejects new favourite without evicting any")
        check(history.visiblePhotos(width: 182).count == 1 && history.photos.count == 2, "screen shrinking limits the visible layer only")
        history.hitRects[id] = CGRect(x: 0, y: 0, width: 150, height: 100)
        history.draggingID = id
        history.remove(id)
        check(history.hitRects[id] == nil && history.draggingID == nil, "removal releases interaction and drag state")
        check(!fm.fileExists(atPath: replacement.url.path), "removal deletes private copy")
        check(fm.fileExists(atPath: other.path) && fm.fileExists(atPath: original.path), "removal preserves user original files")
        history.remove(secondID)
        check(PinnedPhotos(storageFolder: folder, defaults: defaults).photos.isEmpty, "removal survives restart")

        let symlink = root.appendingPathComponent("Linked.png")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: original)
        let linkedID = history.pin(from: symlink, atX: 500, width: 1000)!
        let linkedCopy = history.photos[0].url
        try fm.removeItem(at: symlink)
        try fm.removeItem(at: original)
        check((try? Data(contentsOf: linkedCopy)) == originalData, "selected symlink is copied as independent image data")
        history.remove(linkedID)

        let missingID = history.pin(from: other, atX: 500, width: 1000)!
        try fm.removeItem(at: history.photos[0].url)
        check(PinnedPhotos(storageFolder: folder, defaults: defaults).photos.isEmpty, "missing private copies are skipped safely on restore")
        history.remove(missingID)

        // Persistent records never accept paths that could escape private storage.
        let malicious = "[{\"id\":\"\(UUID())\",\"filename\":\"../Replacement.png\",\"position\":0.5,\"tilt\":0}]"
        defaults.set(Data(malicious.utf8), forKey: "pinnedPhotos.v1")
        let unsafe = PinnedPhotos(storageFolder: folder, defaults: defaults)
        check(unsafe.photos.isEmpty && fm.fileExists(atPath: other.path), "restore rejects file names outside owned storage")
        defaults.set(Data("broken manifest".utf8), forKey: "pinnedPhotos.v1")
        check(PinnedPhotos(storageFolder: folder, defaults: defaults).photos.isEmpty, "malformed manifest is ignored")
        let transient = PinnedPhotos(storageFolder: root.appendingPathComponent("Transient"), defaults: defaults, persists: false)
        check(transient.pin(from: other, atX: 500, width: 1000) != nil && defaults.data(forKey: "pinnedPhotos.v1") == Data("broken manifest".utf8), "transient fixture neither reads nor writes persistent favourites")
        print("PASS: \(checks) pinned-photo storage, positioning and safety checks")
    }
}
