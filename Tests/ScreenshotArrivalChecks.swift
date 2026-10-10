import AppKit
import ImageIO

/// Exercises the actual SwiftUI/native scroll row on our own offscreen panel,
/// including a capture arriving while the clothesline is tucked away.
@main
struct ScreenshotArrivalChecks {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("clipline-arrival-checks-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let png = NSMutableData()
        let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var checks = 0
        for (width, count) in [(CGFloat(640), 3), (1440, 18), (640, 100)] {
            let line = Line(persistsScreenshots: false)
            let clipboard = ClipboardHistory(pasteboard: pasteboard)
            let pinned = PinnedPhotos(storageFolder: root.appendingPathComponent(UUID().uuidString), persists: false)
            func hang(_ n: Int, flying: Bool = false) throws -> UUID {
                let file = root.appendingPathComponent("\(width)-\(count)-\(n).png")
                try (png as Data).write(to: file)
                return line.hang(file, quietly: true, flying: flying)!
            }
            for n in 0..<count { _ = try hang(n) }
            let host = LineHostingView(rootView: LineView(line: line, clipboard: clipboard, pinnedPhotos: pinned))
            host.sizingOptions = []
            let panel = LinePanel(content: host)
            panel.setFrame(CGRect(x: -10_000, y: -10_000, width: width, height: Layout.panelHeight), display: true)
            panel.orderFrontRegardless()
            defer { panel.orderOut(nil); panel.close() }
            line.revealed = true
            pump(host, for: 0.6)
            line.revealed = false
            pump(host, for: 0.3)
            if let scroll = line.screenshotScrollView {
                scroll.contentView.scroll(to: CGPoint(x: 0, y: scroll.contentView.bounds.minY))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            let newest = try hang(count, flying: true)
            line.revealed = true
            pump(host, for: 0.12)
            fullyVisible(newest, line: line, width: width, label: "hidden arrival / \(count) cards / \(width) points")
            checks += 1
            line.land(newest)
            pump(host, for: 0.7)
            fullyVisible(newest, line: line, width: width, label: "after landing and oldest-card removal")
            checks += 1

            // Once it has arrived, ordinary browsing is never pulled back to the end.
            if let scroll = line.screenshotScrollView {
                scroll.contentView.scroll(to: CGPoint(x: 0, y: scroll.contentView.bounds.minY))
                scroll.reflectScrolledClipView(scroll.contentView)
                pump(host, for: 0.2)
                precondition(abs(scroll.contentView.bounds.minX) < 0.5, "manual browsing stays at the chosen position")
                checks += 1
            }

            line.section = .clipboard
            pump(host, for: 0.6)
            line.revealed = false
            _ = try hang(count + 1, flying: true)
            let final = try hang(count + 2, flying: true)
            line.section = .screenshots
            line.revealed = true
            pump(host, for: 0.6)
            // Eviction itself fires after 0.6 seconds. Wait for its following
            // layout pass, rather than sampling while the section is rebuilt.
            let settleDeadline = Date().addingTimeInterval(1)
            while Date() < settleDeadline && (line.screenshotScrollView == nil || line.items.contains(where: { $0.falling })) {
                pump(host, for: 0.05)
            }
            pump(host, for: 0.05)
            fullyVisible(final, line: line, width: width, label: "burst capture returning from clipboard")
            checks += 1
            if let scroll = line.screenshotScrollView {
                panel.setFrame(CGRect(x: -10_000, y: -10_000, width: 800, height: Layout.panelHeight), display: true)
                pump(host, for: 0.2)
                fullyVisible(final, line: line, width: 800, label: "display width changes while overflowed")
                precondition(!scroll.hasHorizontalScroller, "native scrollbar remains hidden")
                checks += 1
            }
        }
        print("PASS: \(checks) hidden capture arrival, first overflow, 100-card eviction, section and browsing checks")
    }

    @MainActor private static func pump(_ view: NSView, for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        repeat {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(1.0 / 60)))
        } while Date() < deadline
        view.layoutSubtreeIfNeeded()
    }

    @MainActor private static func fullyVisible(_ id: UUID, line: Line, width: CGFloat, label: String) {
        guard let rect = line.cardLayoutRects[id] else { fatalError("Missing arrival geometry: \(label)") }
        if rect.minX < 12 || rect.maxX > width - 12 {
            print("Arrival debug: \(label); clip=\(String(describing: line.screenshotScrollView?.contentView.bounds)); doc=\(String(describing: line.screenshotScrollView?.documentView?.bounds)); items=\(line.items.count)")
            fflush(stdout)
        }
        precondition(rect.minX >= 12 && rect.maxX <= width - 12,
                     "Latest screenshot must fit fully inside the right edge (\(label)): \(rect)")
    }
}
