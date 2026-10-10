import AppKit
import AVFoundation

enum CaptureMedia {
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
    static func isVideo(_ url: URL) -> Bool { videoExtensions.contains(url.pathExtension.lowercased()) }

    /// Called on the capture-loading queue for movies. Full recordings remain
    /// files on disk; only a bounded cover is retained for each hanging card.
    static func thumbnail(_ url: URL, maxPixels: Int = 320) -> NSImage? {
        guard isVideo(url) else { return makeThumbnail(url, maxPixels: maxPixels) }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        guard let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
    }
}

enum CaptureLibrary {
    struct Card { let url: URL; let thumbnail: NSImage }

    /// A directory switch replaces just the capture row, never pinned photos.
    /// Read the latest 100 image/movie files in the active save folders.
    static func load(_ locations: CaptureLocations, limit: Int = 100, savedPaths: [String]? = nil) -> [Card] {
        var urls: [URL] = []
        for folder in locations.folders {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder,
                includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
            urls += files.filter { locations.accepts($0) && ScreenshotWatcher.isCandidate($0, in: folder, kind: .all) }
        }
        if let savedPaths {
            let paths = Set(savedPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
            urls = urls.filter { paths.contains($0.standardizedFileURL.path) }
        }
        func date(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        }
        return urls.sorted { date($0) == date($1) ? $0.path < $1.path : date($0) < date($1) }
            .suffix(limit).compactMap { url in
                guard let thumbnail = CaptureMedia.thumbnail(url) else { return nil }
                return Card(url: url.standardizedFileURL.absoluteURL, thumbnail: thumbnail)
            }
    }
}
