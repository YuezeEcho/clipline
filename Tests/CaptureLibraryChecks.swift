import AppKit
import AVFoundation
import CoreVideo

@main struct CaptureLibraryChecks {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipline-capture-checks-\(UUID().uuidString)")
        let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B")
        let movies = root.appendingPathComponent("Movies")
        for folder in [a,b,movies] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        func check(_ value: Bool, _ message: String) { guard value else { fatalError("FAIL: " + message) }; checks += 1 }
        func wait(_ seconds: Double, until done: () -> Bool = { false }) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end && !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = bitmap.representation(using: .png, properties: [:])!
        try png.write(to: a.appendingPathComponent("old.png"))
        try png.write(to: b.appendingPathComponent("new.png"))
        let video = movies.appendingPathComponent("recording.MOV")
        try makeMovie(video)
        let first = CaptureLocations(screenshots: a.path, recordings: movies.path)
        let second = CaptureLocations(screenshots: b.path, recordings: movies.path)
        let line = Line(persistsScreenshots: false)
        let suite = "local.clipline.capture-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let pins = PinnedPhotos(storageFolder: root.appendingPathComponent("Pins"), defaults: defaults)
        _ = pins.pin(from: a.appendingPathComponent("old.png"), atX: 200, width: 640)
        let fixedIDs = pins.photos.map(\.id)
        let loadedA = CaptureLibrary.load(first)
        line.replaceContents(loadedA)
        check(line.liveCount == 2, "image and recording loaded from separate selected folders")
        check(line.items.filter(\.isVideo).count == 1, "movie has a distinct type")
        check(line.items.allSatisfy { max($0.thumb.size.width, $0.thumb.size.height) <= 320 }, "covers are bounded thumbnails")
        line.replaceContents(CaptureLibrary.load(second))
        check(!line.items.contains { $0.url.lastPathComponent == "old.png" } && line.items.contains { $0.url.lastPathComponent == "new.png" }, "directory switch replaces old captures")
        check(pins.photos.map(\.id) == fixedIDs, "pinned photos independent of capture replacement")
        check(FileManager.default.fileExists(atPath: a.appendingPathComponent("old.png").path), "old directory file is retained")
        check(line.items.contains { $0.url.standardizedFileURL.path == video.standardizedFileURL.path }, "unchanged recording folder is retained: \(line.items.map { $0.url.path }) vs \(video.path)")
        check(CaptureLibrary.load(first, limit: 1).count == 1, "combined folder library respects limit")
        check(CaptureLibrary.load(first, savedPaths: []).isEmpty, "cleared screenshot row stays empty when restoring same folder")
        check(CaptureLibrary.load(first, savedPaths: [video.path]).count == 1, "same-folder startup restores only retained cards")
        check(CaptureMedia.thumbnail(video) != nil, "native movie cover decodes")
        let id = line.items.first(where: \.isVideo)!.id
        line.revealed = true
        line.videoPreview.start(id, url: video)
        wait(3) { line.videoPreview.activeID == id && (line.videoPreview.player?.currentTime().seconds ?? 0) > 0.1 }
        check(line.videoPreview.activeID == id, "hover starts preview after short dwell")
        check(line.videoPreview.player?.isMuted == true && line.videoPreview.player?.volume == 0, "preview is silent")
        check((line.videoPreview.player?.currentTime().seconds ?? 0) > 0.1, "native player advances invented movie frames")
        let surface = MovieLayerView(frame: NSRect(x: 0, y: 0, width: 160, height: 100))
        let panel = NSPanel(contentRect: NSRect(x: -10_000, y: -10_000, width: 160, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = surface
        panel.orderFrontRegardless()
        defer { surface.videoLayer.player = nil; panel.orderOut(nil); panel.close() }
        surface.videoLayer.player = line.videoPreview.player
        surface.layoutSubtreeIfNeeded()
        wait(2) { surface.videoLayer.isReadyForDisplay }
        check(surface.videoLayer.isReadyForDisplay, "native preview layer has decoded a frame for display")
        let secondID = UUID()
        line.videoPreview.start(secondID, url: video)
        check(line.videoPreview.player == nil && line.videoPreview.activeID == nil, "starting another preview releases prior player immediately")
        line.videoPreview.stop(secondID)
        wait(0.4)
        check(line.videoPreview.player == nil, "leaving during hover delay prevents playback")
        line.videoPreview.start(id, url: video); wait(0.4)
        line.revealed = false
        check(line.videoPreview.player == nil && line.videoPreview.activeID == nil, "hiding line stops video and releases player")
        line.revealed = true; line.videoPreview.start(id, url: video); wait(0.4)
        line.section = .clipboard
        check(line.videoPreview.player == nil, "switching to clipboard stops video")
        var received: [URL] = []
        let watcher = ScreenshotWatcher(folder: b, kind: .all, onNew: { received.append($0) }, onChange: {})
        watcher.start(); defer { watcher.stop() }
        wait(0.1)
        check(received.isEmpty, "existing images are not emitted again as new captures")
        func seen(_ url: URL) -> Bool { received.contains { $0.standardizedFileURL.path == url.standardizedFileURL.path } }
        func receivedCount(_ url: URL) -> Int { received.filter { $0.standardizedFileURL.path == url.standardizedFileURL.path }.count }
        let partial = b.appendingPathComponent("partial.png")
        try Data(png.prefix(20)).write(to: partial)
        wait(0.18)
        check(!seen(partial), "unfinished screenshot is not permanently marked received")
        try png.write(to: partial)
        wait(1) { seen(partial) }
        check(receivedCount(partial) == 1, "in-place completion is received by bounded retry")
        let recorded = b.appendingPathComponent("finished.mov")
        try FileManager.default.copyItem(at: video, to: recorded)
        wait(3) { seen(recorded) }
        check(seen(recorded), "completed recording enters folder watcher")
        wait(0.3)
        check(receivedCount(recorded) == 1, "recording is emitted once")
        let unfinished = b.appendingPathComponent("long-recording.mov")
        try Data([0,1,2,3]).write(to: unfinished)
        wait(3.2)
        check(!seen(unfinished), "unfinished recording is not hung early")
        try Data(contentsOf: video).write(to: unfinished)
        wait(3) { seen(unfinished) }
        check(seen(unfinished), "long recording is retried after the image retry window without another directory event")
        let hidden = b.appendingPathComponent(".temporary.png")
        try png.write(to: hidden); wait(0.1)
        check(!seen(hidden), "hidden capture temp files ignored")
        watcher.stop()
        let stopped = b.appendingPathComponent("stopped.png")
        try png.write(to: stopped); wait(0.2)
        check(!seen(stopped), "stopped watcher cannot deliver late events")
        check(!ScreenshotWatcher.isCandidate(video, in: movies, kind: .images), "image watcher excludes movies")
        check(!ScreenshotWatcher.isCandidate(partial, in: b, kind: .recordings), "recording watcher excludes images")
        line.replaceContents([])
        check(line.liveCount == 0 && pins.photos.map(\.id) == fixedIDs, "empty selected folder leaves fixed photos alone")
        print("PASS: \(checks) capture folder, movie cover, native silent playback and write-readiness checks")
    }

    static func makeMovie(_ url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64, AVVideoHeightKey: 48])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                         kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        for n in 0..<90 {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = buffer!
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<48 { for x in 0..<64 {
                let i = y * row + x * 4
                base[i] = UInt8(n * 2); base[i+1] = 90; base[i+2] = UInt8(255 - n * 2); base[i+3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            guard adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(n), timescale: 30)) else { throw writer.error! }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        guard done.wait(timeout: .now() + 10) == .success, writer.status == .completed else {
            throw writer.error ?? NSError(domain: "VideoTest", code: 1)
        }
    }
}
