import AppKit

/// Creates only disposable captures. Real Trash checks move these fixtures,
/// then remove only the exact test URLs returned by macOS.
@main
struct CaptureDeletionChecks {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAIL: " + message) }
            checks += 1
        }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("clipline-delete-test-" + UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 30, pixelsHigh: 20,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let data = image.representation(using: .png, properties: [:])!
        func fixture(_ folder: String, _ name: String = UUID().uuidString + ".png") throws -> URL {
            let directory = root.appendingPathComponent(folder)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }
        var trashed: [URL] = []
        defer { for url in trashed { try? manager.removeItem(at: url) } }
        let line = Line(persistsScreenshots: false, trashFile: { url in
            var result: NSURL?
            try manager.trashItem(at: url, resultingItemURL: &result)
            guard let result else { fatalError("No Trash URL returned for test fixture") }
            trashed.append(result as URL)
        })
        // These files deliberately live outside both fixed inbox directories.
        let url = try fixture("User chosen screenshot folder")
        let id = line.hang(url, quietly: true)!
        check(!line.isInInbox(id), "fixture is a custom-folder capture")
        line.discard(id)
        check(!manager.fileExists(atPath: url.path), "corner deletion removes the original custom-folder file")
        check(trashed.count == 1 && manager.fileExists(atPath: trashed[0].path), "file exists in macOS Trash, rather than being permanently deleted")
        let trashData = try Data(contentsOf: trashed[0])
        check(trashData == data, "trashed image bytes preserved")
        check(line.liveCount == 0 && line.items.first?.falling == true, "successful deletion starts the falling animation")
        line.discard(id)
        check(trashed.count == 1, "repeated click during falling does not trash again")
        let videoURL = try fixture("User chosen recording folder", "invented-" + UUID().uuidString + ".mov")
        let videoID = line.hang(videoURL, quietly: true, thumbnail: NSImage(size: NSSize(width: 30, height: 20)))!
        line.discard(videoID)
        check(!manager.fileExists(atPath: videoURL.path) && trashed.count == 2, "recording file uses the same Trash behavior")
        let retained = try fixture("Kept files")
        let retainedID = line.hang(retained, quietly: true)!
        line.drop(retainedID, quietly: true)
        check(manager.fileExists(atPath: retained.path) && trashed.count == 2, "explicit take-down keeps the original file")
        let allA = try fixture("Kept files"), allB = try fixture("Kept files")
        _ = line.hang(allA, quietly: true); _ = line.hang(allB, quietly: true)
        line.clear()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        check(line.liveCount == 0 && manager.fileExists(atPath: allA.path) && manager.fileExists(atPath: allB.path),
              "take-everything-down still preserves all original files")
        check(trashed.count == 2, "bulk take-down never calls Trash")
        let failureURL = try fixture("Read only simulation")
        let failure = Line(persistsScreenshots: false, trashFile: { _ in throw CocoaError(.fileWriteNoPermission) })
        var reportedURL: URL?
        var reportedCode: Int?
        failure.onTrashError = { url, error in reportedURL = url; reportedCode = (error as NSError).code }
        let failureID = failure.hang(failureURL, quietly: true)!
        var falls = 0
        failure.onFall = { _ in falls += 1 }
        failure.discard(failureID)
        check(failure.liveCount == 1 && failure.items.first?.falling == false, "permission failure retains the card")
        check(manager.fileExists(atPath: failureURL.path), "permission failure preserves the original")
        check(falls == 0, "failure never plays a misleading deletion animation")
        check(reportedURL == failureURL && reportedCode == CocoaError.fileWriteNoPermission.rawValue,
              "failure reports the exact file and reason to the user-facing handler")
        print("PASS: \(checks) capture deletion checks (only temporary test files moved to Trash)")
    }
}
