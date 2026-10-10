import AppKit
import Combine
import CoreGraphics
import SwiftUI

/// Exercises only this process's view, private pasteboard and invented files.
/// Its nonactivating panel stays offscreen; no desktop pixels are captured.
@main
struct RenderPreview {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        verifyNativeScreenshotPress()
        verifyNativePinnedInteraction()
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let history = ClipboardHistory(pasteboard: pb)
        let line = Line(persistsScreenshots: false)
        line.revealed = true
        let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fixtures = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/layout-fixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtures) }
        let pinned = PinnedPhotos(storageFolder: fixtures.appendingPathComponent("Pinned", isDirectory: true),
                                  persists: false)
        try verifyScreenshotRetention(in: fixtures)
        for index in 1...18 {
            let file = fixtures.appendingPathComponent("Sample-\(index).png")
            try samplePNG(index).write(to: file)
            precondition(line.hang(file, quietly: true) != nil)
            history.record(.text("虚构剪贴板记录 \(index)\n设计笔记：把灵感挂在晾绳上。"), source: "Sample Notes")
        }
        history.record(ClipboardHistory.imageContent(try samplePNG(19))!, source: "Sample Image")
        for (index, x) in [CGFloat(155), 640, 1125].enumerated() {
            let file = fixtures.appendingPathComponent("Favourite-\(index + 1).png")
            try samplePNG(index + 31, favourite: true).write(to: file)
            precondition(pinned.pin(from: file, atX: x, width: 1280) != nil)
        }
        let host = LineHostingView(rootView: LineView(line: line, clipboard: history, pinnedPhotos: pinned))
        host.sizingOptions = []
        let window = LinePanel(content: host)
        defer { window.orderOut(nil); window.close() }
        guard window.collectionBehavior.contains(.fullScreenAuxiliary),
              window.collectionBehavior.contains(.canJoinAllSpaces),
              window.level == .statusBar, !window.canBecomeKey, !window.canBecomeMain,
              host.acceptsFirstMouse(for: nil) else {
            fatalError("Panel must support fullscreen Spaces and first-click interaction without taking focus")
        }
        // Showing our own offscreen panel makes SwiftUI execute arrival/onAppear.
        resize(window, width: 1280)
        window.orderFrontRegardless()
        settle(host)
        verifyScreenshotGeometry(line, host: host)
        verifyPinnedGeometry(pinned, width: 1280)
        try render(host, to: outputDirectory.appendingPathComponent("screenshot-preview.png"))
        try render(host, to: outputDirectory.appendingPathComponent("pinned-preview.png"))

        verifyScrollSway(host, line: line, pinned: pinned)

        let stationaryPositions = pinned.hitRects.mapValues(\.midX)
        let finalScreenshot = line.items.last!.id
        let beforeScroll = line.cardLayoutRects[finalScreenshot]
        scrollOurScreenshotRow(host, line: line, toLeadingEdge: true)
        settle(host)
        verifyPinnedGeometry(pinned, width: 1280, expectedCenters: stationaryPositions)
        requireVisible(line.items.first!.id, rects: line.hitRects, viewport: line.interactionRect,
                       message: "Horizontal scrolling must reveal old screenshot cards behind the favourites")
        if let beforeScroll, let afterScroll = line.cardLayoutRects[finalScreenshot] {
            precondition(abs(afterScroll.midX - beforeScroll.midX) > 100,
                         "Screenshot layer must scroll independently of favourites")
        }
        scrollOurScreenshotRow(host, line: line, toLeadingEdge: false)
        settle(host)

        var layoutAngles: [Double] = []
        let layoutObservation = line.scrollSway.$angle.sink { layoutAngles.append($0) }
        defer { layoutObservation.cancel() }
        resize(window, width: 640)
        settle(host)
        precondition(layoutAngles.allSatisfy { abs($0) <= 5 } && line.scrollSway.angle == 0,
                     "Resizing and bringing the newest card into view must leave no lingering or unbounded sway")
        verifyScreenshotGeometry(line, host: host)
        verifyPinnedGeometry(pinned, width: 640)
        try render(host, to: outputDirectory.appendingPathComponent("screenshot-preview-narrow.png"))

        // A new capture should scroll into view even when the row already overflows.
        let newFile = fixtures.appendingPathComponent("Sample-20.png")
        try samplePNG(20).write(to: newFile)
        layoutAngles.removeAll()
        let newest = line.hang(newFile, quietly: true)!
        let narrowStationaryPositions = pinned.hitRects.mapValues(\.midX)
        settle(host)
        precondition(layoutAngles.allSatisfy { abs($0) <= 5 } && line.scrollSway.angle == 0,
                     "A new screenshot's automatic scrolling must leave no lingering or unbounded sway")
        requireVisible(newest, rects: line.hitRects, viewport: line.interactionRect,
                       message: "New screenshot must scroll into view on a narrow panel")
        verifyPinnedGeometry(pinned, width: 640, expectedCenters: narrowStationaryPositions)

        line.section = .clipboard
        settle(host)
        verifyClipboardGeometry(history, line: line, host: host)
        precondition(pinned.hitRects.isEmpty, "Clipboard section must not retain favourite hit regions")
        try render(host, to: outputDirectory.appendingPathComponent("clipboard-preview-narrow.png"))

        resize(window, width: 1280)
        settle(host)
        verifyClipboardGeometry(history, line: line, host: host)
        precondition(pinned.hitRects.isEmpty, "Clipboard section must not display fixed favourites")
        try render(host, to: outputDirectory.appendingPathComponent("clipboard-preview.png"))

        history.record(.text("刚复制的新记录\n应该自动出现在可见区域。"), source: "Sample Notes")
        settle(host)
        verifyClipboardGeometry(history, line: line, host: host)
        line.section = .screenshots
        settle(host)
        verifyScreenshotGeometry(line, host: host)
        verifyPinnedGeometry(pinned, width: 1280, expectedCenters: stationaryPositions)

        let preservedPositions = pinned.photos.map(\.position)
        resize(window, width: 320)
        settle(host)
        verifyPinnedGeometry(pinned, width: 320)
        precondition(pinned.photos.count == 3 && pinned.photos.map(\.position) == preservedPositions,
                     "A narrower viewport must hide excess favourites without changing stored positions")
        resize(window, width: 1280)
        settle(host)
        verifyPinnedGeometry(pinned, width: 1280, expectedCenters: stationaryPositions)

        line.showsControls = false
        settle(host)
        precondition(line.controlsRect == .zero,
                     "Hiding the toolbar must remove its click region, not only its pixels")
        verifyPinnedGeometry(pinned, width: 1280, expectedCenters: stationaryPositions)
        precondition(line.interactionRect.width == 1280 && line.hitRects.count > 0,
                     "Hidden controls must preserve screenshot scrolling and interaction")
        try render(host, to: outputDirectory.appendingPathComponent("pinned-hidden-controls-preview.png"))
        line.section = .clipboard
        settle(host)
        precondition(line.controlsRect == .zero && pinned.hitRects.isEmpty,
                     "Hidden controls and favourite hit regions must stay absent in clipboard mode")
        precondition(history.interactionRect.width == 1280 && history.hitRects.count > 0,
                     "Clipboard scrolling must work while the toolbar is hidden")
        line.section = .screenshots
        line.showsControls = true
        settle(host)
        verifyScreenshotGeometry(line, host: host)
        verifyPinnedGeometry(pinned, width: 1280, expectedCenters: stationaryPositions)
        print("PASS: 19 screenshot thumbnails and 20 private clipboard cards overflow 640/1280 px panels; newest cards remain visible after insertion and section switching.")
        print("PASS: fixed favourite positions survive screenshot insertion, horizontal scrolling, section switching and narrow-screen hiding; hidden controls remove their click area in both sections.")
        print("PASS: native screenshot scroll bounds drive favourite sway in both directions, stop at rest and clear on hide/section change; inactive cached rows cannot drive motion and layout changes settle within bounds.")
        print("PASS: toolbar, both scroll viewports, first-click and fullscreen panel configuration checks. Rendered offscreen previews in \(outputDirectory.path)")
        print("Physical mouse, scrolling gestures and real fullscreen Spaces were not exercised.")
    }

    /// All offsets and notifications belong to this process's offscreen row.
    @MainActor private static func verifyScrollSway(_ host: NSView, line: Line, pinned: PinnedPhotos) {
        let positions = pinned.photos.map(\.position)
        let oldScroll = screenshotScrollView(host, line: line)
        precondition(line.scrollSway.angle == 0, "An initial layout must settle without retaining motion")

        scrollOurScreenshotRow(host, line: line, toLeadingEdge: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        precondition(line.scrollSway.angle < -0.01,
                     "A decreasing real scroll offset must sway the favourites in the negative direction")
        precondition(abs(line.scrollSway.angle) <= 5 && pinned.photos.map(\.position) == positions,
                     "Scroll motion must stay bounded and preserve favourite attachment positions")
        settle(host)
        precondition(line.scrollSway.angle == 0, "Stopping a gesture must return the sway target to rest")

        scrollOurScreenshotRow(host, line: line, toLeadingEdge: false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        precondition(line.scrollSway.angle > 0.01,
                     "An increasing real scroll offset must sway the favourites in the positive direction")
        line.revealed = false
        precondition(line.scrollSway.angle == 0, "Hiding the line must clear any pending scrolling impulse")
        scrollOurScreenshotRow(host, line: line, toLeadingEdge: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        precondition(line.scrollSway.angle == 0, "A hidden screenshot row must not drive favourite motion")
        line.revealed = true
        settle(host)

        scrollOurScreenshotRow(host, line: line, toLeadingEdge: false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        precondition(line.scrollSway.angle > 0.01)
        line.section = .clipboard
        precondition(line.scrollSway.angle == 0, "Changing sections must immediately clear favourite motion")
        settle(host)
        func contains(_ parent: NSView, target: NSView) -> Bool {
            parent === target || parent.subviews.contains { contains($0, target: target) }
        }
        print("Scroll lifecycle: old row in preview host=\(contains(host, target: oldScroll)), window attached=\(oldScroll.window != nil)")
        precondition(line.screenshotScrollView == nil,
                     "The removed screenshot row must release its wheel forwarding reference")
        oldScroll.contentView.scroll(to: .zero)
        oldScroll.reflectScrolledClipView(oldScroll.contentView)
        RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        precondition(line.scrollSway.angle == 0,
                     "A detached screenshot row's bounds notifications must not produce a new impulse")
        line.section = .screenshots
        settle(host)
        precondition(line.scrollSway.angle == 0 && pinned.photos.map(\.position) == positions,
                     "Reopening the screenshot row must establish a baseline and preserve every favourite position")
        if line.screenshotScrollView !== oldScroll {
            oldScroll.contentView.scroll(to: NSPoint(x: 100, y: oldScroll.contentView.bounds.minY))
            oldScroll.reflectScrolledClipView(oldScroll.contentView)
            RunLoop.current.run(until: Date().addingTimeInterval(0.025))
            precondition(line.scrollSway.angle == 0,
                         "An inactive cached row must not drive motion after a different screenshot row is attached")
        } else {
            // SwiftUI may reuse its retained native scroll view on this OS.
            // Once it is the active row again, its movement must drive sway.
            let maximum = max(0, (oldScroll.documentView?.bounds.width ?? 0) - oldScroll.contentView.bounds.width)
            let towardsLeading = oldScroll.contentView.bounds.minX > maximum / 2
            scrollOurScreenshotRow(host, line: line, toLeadingEdge: towardsLeading)
            RunLoop.current.run(until: Date().addingTimeInterval(0.025))
            let direction = towardsLeading ? -1.0 : 1.0
            precondition(line.scrollSway.angle * direction > 0.01,
                         "A reused native row must resume motion after establishing its reopening baseline")
            settle(host)
            scrollOurScreenshotRow(host, line: line, toLeadingEdge: false)
            settle(host)
        }
    }

    /// Calls only our own gesture component. The open callback is a counter,
    /// so this check never launches an external editor or writes a clipboard.
    @MainActor private static func verifyNativeScreenshotPress() {
        let view = GrabView(frame: NSRect(x: 0, y: 0, width: 150, height: 116))
        var copies = 0, opens = 0
        var pressed = false
        view.onClick = { copies += 1 }
        view.onLongPress = { opens += 1 }
        view.onPressChange = { pressed = $0 }
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: 75, y: 45), modifierFlags: [],
                              timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1,
                              clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: mouse(.leftMouseDown))
        view.mouseUp(with: mouse(.leftMouseUp))
        precondition(copies == 1 && opens == 0 && !pressed, "A short click must still copy")
        view.mouseDown(with: mouse(.leftMouseDown))
        RunLoop.current.run(until: Date().addingTimeInterval(0.52))
        precondition(opens == 1 && copies == 1 && !pressed, "A long press must trigger Open once")
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        view.mouseUp(with: mouse(.leftMouseUp))
        precondition(opens == 1 && copies == 1, "Releasing a long press must not copy or open again")
        view.mouseDown(with: mouse(.leftMouseDown))
        view.cancelPress()
        RunLoop.current.run(until: Date().addingTimeInterval(0.52))
        view.mouseUp(with: mouse(.leftMouseUp))
        precondition(opens == 1 && copies == 1 && !pressed, "Cancellation must stop a pending long press")
        print("PASS: screenshot long press opens once, release does not copy, and short click/cancellation keep their behavior.")
    }

    /// Calls our component directly with local event objects. Events are never
    /// posted to the operating system or delivered to another app's window.
    @MainActor private static func verifyNativePinnedInteraction() {
        let line = Line(persistsScreenshots: false)
        let view = PinnedGrabView(frame: NSRect(x: 0, y: 0, width: 150, height: 116))
        var beginCount = 0, endCount = 0, dragStartCount = 0, dragEndCount = 0
        var clickCount = 0, dropCount = 0
        var dragging = false
        var lastDelta: CGFloat = 0
        view.onBegin = { beginCount += 1; line.beginInteraction() }
        view.onEnd = { endCount += 1; line.endInteraction() }
        view.onDragStart = { dragStartCount += 1; dragging = true }
        view.onDragEnd = { dragEndCount += 1; dragging = false; lastDelta = 0 }
        view.onDrag = { lastDelta = $0 }
        view.onClick = { clickCount += 1 }
        view.onDrop = { _ in dropCount += 1 }

        func mouse(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 45), modifierFlags: [],
                              timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1,
                              clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: mouse(.leftMouseDown, x: 75))
        precondition(line.interactionDepth == 1 && beginCount == 1)
        view.mouseDragged(with: mouse(.leftMouseDragged, x: 110))
        precondition(dragging && lastDelta == 35 && dragStartCount == 1)
        view.cancelInteraction()
        precondition(line.interactionDepth == 0 && !dragging && lastDelta == 0 &&
                     endCount == 1 && dragEndCount == 1 && dropCount == 0,
                     "Dismantling a dragged favourite must release interaction without committing its position")
        view.cancelInteraction()
        precondition(endCount == 1 && dragEndCount == 1 && dropCount == 0,
                     "Repeated cancellation must not finish the same interaction twice")
        view.mouseUp(with: mouse(.leftMouseUp, x: 110))
        precondition(clickCount == 0 && dropCount == 0 && endCount == 1,
                     "A late mouse-up after cancellation must not click or drop the photo")

        view.mouseDown(with: mouse(.leftMouseDown, x: 75))
        view.mouseUp(with: mouse(.leftMouseUp, x: 75))
        precondition(clickCount == 1 && line.interactionDepth == 0 && beginCount == endCount)
        view.mouseDown(with: mouse(.leftMouseDown, x: 75))
        view.mouseDragged(with: mouse(.leftMouseDragged, x: 110))
        view.mouseUp(with: mouse(.leftMouseUp, x: 110))
        precondition(dropCount == 1 && !dragging && lastDelta == 0 &&
                     line.interactionDepth == 0 && beginCount == endCount && dragStartCount == dragEndCount,
                     "Normal dragging must commit once and balance its interaction callbacks")

        let firstScroll = CountingScrollView()
        let secondScroll = CountingScrollView()
        var currentScroll: NSScrollView?
        view.scrollProvider = { currentScroll }
        let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                              wheel1: 0, wheel2: 24, wheel3: 0)!
        let wheel = NSEvent(cgEvent: cgEvent)!
        currentScroll = firstScroll
        view.scrollWheel(with: wheel)
        precondition(firstScroll.receivedWheels == 1,
                     "A provider resolved after view creation must receive the favourite's wheel event")
        currentScroll = secondScroll
        view.scrollWheel(with: wheel)
        precondition(firstScroll.receivedWheels == 1 && secondScroll.receivedWheels == 1,
                     "Favourite wheel forwarding must resolve its live provider rather than cache the old row")
        print("PASS: native favourite drag cancellation is balanced and idempotent; late mouse-up is ignored; wheel events forward through the live provider. Events were not posted.")
    }

    @MainActor private static func verifyPinnedGeometry(_ pinned: PinnedPhotos, width: CGFloat,
                                                        expectedCenters: [UUID: CGFloat]? = nil) {
        let visible = pinned.visiblePhotos(width: width)
        precondition(pinned.hitRects.count == visible.count,
                     "Only favourites that fit this screen may have hit regions")
        for photo in visible {
            guard let rect = pinned.hitRects[photo.id] else { fatalError("Missing fixed favourite geometry") }
            let center = PinnedPhotos.center(position: photo.position, width: width)
            precondition(abs(rect.midX - center) < 8 && rect.width <= 166 && rect.height > 60,
                         "Favourite must stay near its chosen rope position")
            precondition(rect.minX >= -4 && rect.maxX <= width + 4,
                         "Favourite must remain inside the visible screen")
            if let expected = expectedCenters?[photo.id] {
                // The cards intentionally sway about the same attachment point.
                // Their centres may move a few pixels as that spring settles.
                precondition(abs(rect.midX - expected) < 8,
                             "Screenshot scrolling or insertion must not move fixed favourites")
            }
        }
    }

    /// Manipulates only the scroll view owned by this invented preview panel.
    @MainActor private static func scrollOurScreenshotRow(_ host: NSView, line: Line, toLeadingEdge: Bool) {
        let scroll = screenshotScrollView(host, line: line)
        guard let document = scroll.documentView else { fatalError("Missing screenshot document") }
        let targetX = toLeadingEdge ? 0 : max(0, document.bounds.width - scroll.contentView.bounds.width)
        scroll.contentView.scroll(to: NSPoint(x: targetX, y: scroll.contentView.bounds.minY))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @MainActor private static func screenshotScrollView(_ host: NSView, line: Line) -> NSScrollView {
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            let own = (view as? NSScrollView).map { [$0] } ?? []
            return own + view.subviews.flatMap(scrollViews)
        }
        guard let scroll = scrollViews(host).first(where: {
            ($0.documentView?.bounds.width ?? 0) > $0.contentView.bounds.width + 100
        }) else {
            fatalError("Preview must contain an overflowing native horizontal scroll view")
        }
        precondition(line.screenshotScrollView === scroll,
                     "Favourite scroll forwarding must reference the screenshot row's real scroll view")
        return scroll
    }

    @MainActor private static func resize(_ window: NSWindow, width: CGFloat) {
        window.setFrame(NSRect(x: -10000, y: -10000, width: width,
                               height: Layout.panelHeight), display: true)
    }

    @MainActor private static func settle(_ host: NSView) {
        // An offscreen host has no display-driven layout pass. Keep laying it
        // out while its native scroll bounds and lazy cards settle, just as an
        // onscreen application does on successive frames.
        let deadline = Date().addingTimeInterval(1.6)
        repeat {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(1.0 / 60)))
        } while Date() < deadline
        host.layoutSubtreeIfNeeded()
    }

    @MainActor private static func verifyScreenshotGeometry(_ line: Line, host: NSView) {
        verifyCommonGeometry(line, viewport: line.interactionRect, host: host)
        let newest = line.items.last(where: { !$0.falling })!.id
        
        requireVisible(newest, rects: line.hitRects, viewport: line.interactionRect,
                       message: "Latest screenshot must be visible after section layout")
        for item in line.items {
            guard let actual = line.hitRects[item.id], let resting = line.cardLayoutRects[item.id],
                  actual.intersects(line.interactionRect) else { continue }
            let size = PeggedView.cardSize(for: item.thumb.size)
            precondition(abs(resting.width - size.width) < 0.5 && abs(resting.height - size.height) < 0.5,
                         "Flight destination must use unrotated card dimensions")
            if abs(actual.midX - resting.midX) >= 8 || abs(actual.minY - resting.minY) >= 8 {
                print("Rope geometry: actual=\(actual), resting=\(resting), tilt=\(item.tilt), clip=\(String(describing: line.screenshotScrollView?.contentView.bounds))"); fflush(stdout)
                fatalError("Rendered screenshot cards must follow the curved rope")
            }
        }
        precondition(line.hitRects.values.filter { $0.intersects(line.interactionRect) }.count >= 3,
                     "Screenshot viewport must contain multiple cards")
    }

    @MainActor private static func verifyClipboardGeometry(_ history: ClipboardHistory, line: Line, host: NSView) {
        verifyCommonGeometry(line, viewport: history.interactionRect, host: host)
        requireVisible(history.entries.first!.id, rects: history.hitRects,
                       viewport: history.interactionRect,
                       message: "Newest clipboard entry must be visible after section layout")
        precondition(history.hitRects.values.filter { $0.intersects(history.interactionRect) }.count >= 3,
                     "Clipboard viewport must contain multiple cards")
    }

    @MainActor private static func verifyCommonGeometry(_ line: Line, viewport: CGRect, host: NSView) {
        precondition(abs(viewport.width - host.bounds.width) < 1 && viewport.height > 100,
                     "Scroll viewport must match panel width")
        print("Geometry: panel=\(host.bounds), toolbar=\(line.controlsRect), viewport=\(viewport)"); fflush(stdout)
        precondition(line.controlsRect.width > 0 && line.controlsRect.minY >= 168 &&
                     line.controlsRect.maxY <= Layout.panelHeight &&
                     line.controlsRect.minX >= 0 && line.controlsRect.maxX <= host.bounds.width,
                     "Toolbar must fit inside the panel below the hanging cards")
    }

    private static func requireVisible(_ id: UUID, rects: [UUID: CGRect], viewport: CGRect, message: String) {
        guard let rect = rects[id] else { fatalError("\(message): missing card geometry") }
        let visible = rect.intersection(viewport)
        guard visible.width >= rect.width * 0.8, visible.height >= rect.height * 0.8 else {
            fatalError("\(message): card \(rect), viewport \(viewport)")
        }
    }

    @MainActor private static func render(_ host: NSView, to url: URL) throws {
        guard let snapshot = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            fatalError("Could not create preview bitmap")
        }
        host.cacheDisplay(in: host.bounds, to: snapshot)
        // All cards draw opaque sample colors or text in their own view hierarchy.
        precondition(snapshot.pixelsWide > 0 && snapshot.pixelsHigh > 0)
        try snapshot.representation(using: .png, properties: [:])!.write(to: url)
    }

    @MainActor private static func verifyScreenshotRetention(in fixtures: URL) throws {
        let model = Line(persistsScreenshots: false)
        let largeSample = try samplePNG(99, width: 1024, height: 640)
        var files: [URL] = []
        for index in 1...113 {
            let file = fixtures.appendingPathComponent("Retention-\(index).png")
            try largeSample.write(to: file)
            files.append(file)
            precondition(model.hang(file, quietly: true) != nil)
        }
        precondition(model.liveCount == 100, "Screenshot history must retain only the latest 100")
        precondition(model.items.filter { !$0.falling }.first!.url == files[13])
        precondition(model.items.last!.url == files.last!)
        precondition(model.items.allSatisfy { max($0.thumb.size.width, $0.thumb.size.height) <= 320 },
                     "Screenshot thumbnails must stay within their 320 px memory limit")
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        precondition(model.items.count == 100)
        precondition(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
                     "Evicting thumbnails must never delete their original files")
        for file in files { try FileManager.default.removeItem(at: file) }
        print("PASS: 113 invented captures retain latest 100 thumbnails at <=320 px without deleting original files."); fflush(stdout)
    }

    @MainActor private static func samplePNG(_ number: Int, width: Int = 320, height: Int = 200,
                                            favourite: Bool = false) throws -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<height { for x in 0..<width {
            bitmap.setColor(NSColor(calibratedHue: (Double(number) * 0.067 + Double(x) / 2200).truncatingRemainder(dividingBy: 1),
                                    saturation: 0.62, brightness: 0.96 - Double(y) / Double(height) * 0.2,
                                    alpha: 1), atX: x, y: y)
        } }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSString(string: favourite ? "FAV \(number - 30)" : "\(number)").draw(at: NSPoint(x: 26, y: 60), withAttributes: [
            .font: NSFont.systemFont(ofSize: favourite ? 52 : 70, weight: .bold), .foregroundColor: NSColor.white
        ])
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])!
    }
}

@MainActor private final class CountingScrollView: NSScrollView {
    private(set) var receivedWheels = 0
    override func scrollWheel(with event: NSEvent) { receivedWheels += 1 }
}
