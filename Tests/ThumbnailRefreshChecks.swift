import AppKit
import ImageIO

/// These checks use disposable files and a non-persistent Line. They neither
/// open the default image editor nor read/write the user's screenshot history.
@main
struct ThumbnailRefreshChecks {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAIL: " + message) }
            checks += 1
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("clipline-thumbnail-checks-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        func imageData(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> Data {
            let context = CGContext(data: nil, width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let image = context.makeImage()!
            let buffer = NSMutableData()
            let destination = CGImageDestinationCreateWithData(buffer, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            precondition(CGImageDestinationFinalize(destination))
            return buffer as Data
        }
        var revision: TimeInterval = 1
        func save(_ data: Data, to url: URL, atomic: Bool = false) throws {
            try data.write(to: url, options: atomic ? .atomic : [])
            // Deliberately different dates avoid relying on filesystem timing.
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 + revision)], ofItemAtPath: url.path)
            revision += 1
        }
        let original = imageData(width: 1200, height: 800, red: 0.2, green: 0.5, blue: 0.9)
        let edited = imageData(width: 800, height: 1200, red: 0.9, green: 0.3, blue: 0.1)
        let screenshot = root.appendingPathComponent("Screenshot.png")
        try save(original, to: screenshot)
        let line = Line(persistsScreenshots: false)
        let id = line.hang(screenshot, quietly: true, flying: true)!
        let first = line.items[0]
        check(line.liveCount == 1 && first.id == id, "initial screenshot hangs once")
        check(first.thumb.size == NSSize(width: 320, height: 213), "initial image is bounded to 320 pixels")
        line.refreshChangedThumbnails()
        check(line.items[0].thumb === first.thumb, "unchanged image keeps its NSImage")

        try save(edited, to: screenshot)
        line.refreshChangedThumbnails()
        let afterEdit = line.items[0]
        check(afterEdit.thumb !== first.thumb, "same-path external save replaces the thumbnail")
        check(afterEdit.thumb.size == NSSize(width: 213, height: 320), "edited portrait thumbnail stays bounded to 320 pixels")
        check(afterEdit.id == first.id && afterEdit.url == first.url && afterEdit.tilt == first.tilt,
              "editing preserves screenshot identity, path and tilt")
        check(afterEdit.flying && !afterEdit.falling, "editing preserves animation state")
        check(line.liveCount == 1 && line.copiedID == nil, "refresh neither hangs duplicates nor copies")
        line.refreshChangedThumbnails()
        check(line.items[0].thumb === afterEdit.thumb, "successful refresh updates the metadata baseline")

        try save(original, to: screenshot, atomic: true)
        line.refreshChangedThumbnails()
        let afterAtomic = line.items[0]
        check(afterAtomic.thumb !== afterEdit.thumb && afterAtomic.thumb.size.width == 320,
              "atomic replacement at the same path refreshes the thumbnail")
        let oldDate = (try fm.attributesOfItem(atPath: screenshot.path))[.modificationDate] as! Date
        try original.write(to: screenshot, options: .atomic)
        try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: screenshot.path)
        line.refreshChangedThumbnails()
        let sameMetadataReplacement = line.items[0].thumb
        check(sameMetadataReplacement !== afterAtomic.thumb,
              "replacement inode detects a save even when size and modification date match")

        var partial = edited
        partial.replaceSubrange(0..<8, with: [UInt8](repeating: 0, count: 8))
        try save(partial, to: screenshot)
        let incompleteDate = (try fm.attributesOfItem(atPath: screenshot.path))[.modificationDate] as! Date
        line.refreshChangedThumbnails()
        check(line.items[0].thumb === sameMetadataReplacement, "invalid temporary contents preserve the old thumbnail")
        line.refreshChangedThumbnails()
        check(line.items[0].thumb === sameMetadataReplacement, "repeated failed decoding does not erase the image")
        // Finish the same in-place save while retaining its size, date and
        // inode. A failed attempt must not have consumed this new stamp.
        try edited.write(to: screenshot)
        try fm.setAttributes([.modificationDate: incompleteDate], ofItemAtPath: screenshot.path)
        line.refreshChangedThumbnails()
        let repaired = line.items[0].thumb
        check(repaired !== sameMetadataReplacement && repaired.size.height == 320,
              "completed save with identical metadata is retried after failed decoding")

        try fm.removeItem(at: screenshot)
        line.refreshChangedThumbnails()
        check(line.items[0].thumb === repaired && line.liveCount == 1,
              "transiently absent file is left for the caller's pruning policy")
        try save(original, to: screenshot)
        line.refreshChangedThumbnails()
        check(line.items[0].thumb !== repaired, "returning same-path file refreshes after temporary absence")
        line.drop(id, quietly: true)
        let falling = line.items[0].thumb
        try save(edited, to: screenshot)
        line.refreshChangedThumbnails()
        check(line.items[0].thumb === falling && line.liveCount == 0, "dropped cards are not refreshed")
        let rehungID = line.hang(screenshot, quietly: true)!
        check(rehungID != id && line.liveCount == 1, "rehanging after removal starts a fresh thumbnail baseline")
        let rehung = line.items.first { $0.id == rehungID }!
        line.refreshChangedThumbnails()
        check(line.items.first { $0.id == rehungID }!.thumb === rehung.thumb, "rehung unchanged image avoids decoding")

        let other = root.appendingPathComponent("Other.png")
        try save(original, to: other)
        let otherID = line.hang(other, quietly: true)!
        let untouched = line.items.first { $0.id == otherID }!.thumb
        try save(original, to: screenshot)
        line.refreshChangedThumbnails()
        check(line.items.first { $0.id == otherID }!.thumb === untouched,
              "editing one screenshot keeps another screenshot's image untouched")
        let fileBeforeRefresh = try Data(contentsOf: screenshot)
        line.refreshChangedThumbnails()
        let fileAfterRefresh = try Data(contentsOf: screenshot)
        check(fileAfterRefresh == fileBeforeRefresh, "refresh never writes the original image file")
        check(Line(persistsScreenshots: false).items.isEmpty, "non-persistent checks leave no restorable screenshot history")
        print("PASS: \(checks) external-edit thumbnail refresh checks")
    }
}
