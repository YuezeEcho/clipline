import Foundation
import ImageIO
import AVFoundation

/// Watches the folder macOS saves screenshots to and reports new ones.
/// Clipline never takes screenshots itself: you keep your usual shortcut
/// (or CleanShot, or anything else) and the line just picks them up.
@MainActor
final class ScreenshotWatcher {
    let folder: URL
    /// On the Desktop we only accept real screenshots, tagged by macOS with an
    /// extended attribute. In a dedicated folder, any image counts.
    enum Kind { case images, recordings, all }
    private let kind: Kind
    private var known = Set<String>()
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var generation = 0
    private var videoChecks: [String: Task<Void, Never>] = [:]
    private var videoNextCheck: [String: TimeInterval] = [:]
    private var retries: [String: Int] = [:]
    private let onNew: (URL) -> Void
    private let onChange: () -> Void

    nonisolated private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp"]

    nonisolated static let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")

    /// Watches the folder macOS saves screenshots to, or a given folder.
    init(folder: URL? = nil, kind: Kind = .images, onNew: @escaping (URL) -> Void, onChange: @escaping () -> Void) {
        self.onNew = onNew
        self.onChange = onChange
        self.folder = folder ?? Self.screenshotFolder()
        self.kind = kind
    }

    static func screenshotFolder() -> URL {
        Inbox.locations.screenshots
    }

    /// Anything created after the app launched counts as new, even if it
    /// landed before the watcher was ready (macOS may be asking for Desktop
    /// access at that moment).
    private let launchDate = Date()

    func start() {
        stop()
        let files = listing()
        known = Set(files.filter { creationDate($0) < launchDate }.map(\.path))
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("Clipline: cannot watch \(folder.path)")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        let token = generation
        src.setEventHandler { [weak self] in
            guard let self, self.generation == token else { return }
            if self.source?.data.intersection([.delete, .rename]).isEmpty == false {
                self.stop()
                self.onChange()
            } else {
                self.scheduleScan()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        scan()
    }

    var isRunning: Bool { source != nil }

    func stop() {
        generation &+= 1
        videoChecks.values.forEach { $0.cancel() }
        videoChecks.removeAll()
        videoNextCheck.removeAll()
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
        retries.removeAll()
    }

    private func scheduleScan(delay: TimeInterval = 0.05) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        pending = work
        // React soon after the final rename. An incomplete write is retried
        // instead of adding an undecodable screenshot to the known set.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scan() {
        let files = listing()
        let paths = Set(files.map(\.path))
        known.formIntersection(paths)
        retries = retries.filter { paths.contains($0.key) }
        videoNextCheck = videoNextCheck.filter { paths.contains($0.key) }
        var needsRetry = false
        for url in files where !known.contains(url.path) {
            guard isCandidate(url) else { known.insert(url.path); continue }
            if CaptureMedia.isVideo(url) {
                checkVideo(url)
                needsRetry = true
                continue
            }
            if Self.isReady(url) {
                known.insert(url.path)
                retries.removeValue(forKey: url.path)
                onNew(url)
            } else {
                let attempts = (retries[url.path] ?? 0) + 1
                retries[url.path] = attempts
                if attempts < 30 { needsRetry = true }
            }
        }
        onChange()
        // In-place writes need not generate another directory event.
        if needsRetry { scheduleScan(delay: retries.values.contains(where: { $0 < 30 }) ? 0.1 : 1) }
    }

    nonisolated static func isReady(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete else { return false }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                       kCGImageSourceThumbnailMaxPixelSize: 16,
                                       kCGImageSourceShouldCache: false]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil
    }

    private func checkVideo(_ url: URL) {
        guard videoChecks[url.path] == nil, videoChecks.count < 8,
              ProcessInfo.processInfo.systemUptime >= (videoNextCheck[url.path] ?? 0) else { return }
        let token = generation
        videoChecks[url.path] = Task.detached(priority: .utility) { [weak self] in
            let asset = AVURLAsset(url: url)
            let duration = try? await asset.load(.duration)
            let tracks = try? await asset.loadTracks(withMediaType: .video)
            let ready = duration.map { $0.seconds.isFinite && $0.seconds > 0 } == true && !(tracks?.isEmpty ?? true)
            guard !Task.isCancelled else { return }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.videoChecks.removeValue(forKey: url.path)
                if ready && FileManager.default.fileExists(atPath: url.path) {
                    self.known.insert(url.path)
                    self.videoNextCheck.removeValue(forKey: url.path)
                    self.onNew(url)
                    self.onChange()
                    self.scheduleScan()
                } else {
                    // A visible movie can exist throughout a long recording.
                    // Retry until its container is finalized, without blocking UI.
                    self.videoNextCheck[url.path] = ProcessInfo.processInfo.systemUptime + 1
                }
            }
        }
    }

    private func listing() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        return urls.map { $0.standardizedFileURL.absoluteURL }.sorted { creationDate($0) < creationDate($1) }
    }

    private func creationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    private func isCandidate(_ url: URL) -> Bool {
        Self.isCandidate(url, in: folder, kind: kind)
    }

    nonisolated static func isCandidate(_ url: URL, in folder: URL, kind: Kind) -> Bool {
        if CaptureMedia.isVideo(url) { return kind != .images }
        guard kind != .recordings, imageExtensions.contains(url.pathExtension.lowercased()) else { return false }
        return folder.standardizedFileURL == desktop.standardizedFileURL ? isScreenCapture(url) : true
    }

    nonisolated private static func isScreenCapture(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) >= 0
        }
    }
}
