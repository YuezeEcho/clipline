import AppKit
import QuartzCore

/// Samples layer positions on Clipline's own offscreen window. No desktop capture,
/// real clipboard data or external application window is used.
@main
struct LineRevealChecks {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let line = Line(persistsScreenshots: false)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let clipboard = ClipboardHistory(pasteboard: pasteboard)
        let pinned = PinnedPhotos(persists: false)
        let host = LineHostingView(rootView: LineView(line: line, clipboard: clipboard, pinnedPhotos: pinned))
        host.sizingOptions = []
        let panel = LinePanel(content: host)
        panel.setFrame(CGRect(x: -10_000, y: -10_000, width: 1440, height: Layout.panelHeight), display: true)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil); panel.close() }
        panel.contentView?.layoutSubtreeIfNeeded()
        CATransaction.flush()
        func offset() -> CGFloat {
            let layer = host.superview!.layer!
            return (panel.slideView.isAnimating ? layer.presentation() ?? layer : layer).frame.minY
        }
        func baseY() -> CGFloat { host.superview!.layer!.position.y - host.superview!.frame.minY }
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError("FAIL: " + message) }
            checks += 1
        }
        func wait(_ duration: TimeInterval) {
            CATransaction.flush()
            RunLoop.main.run(until: Date().addingTimeInterval(duration))
            panel.contentView?.layoutSubtreeIfNeeded()
            CATransaction.flush()
        }
        check(host.superview!.isHidden, "first frame is hidden, without flashing visible content before the layer is attached")
        check(host.frame.size == CGSize(width: 1440, height: Layout.panelHeight), "hidden host already has its final layout size")
        line.revealed = true
        let slide = host.superview!.layer!.animation(forKey: "clothesline-slide") as? CAKeyframeAnimation
        check(panel.slideView.isAnimating && (slide?.values?.first as? NSNumber)?.doubleValue == Double(LineSlideView.hiddenY + baseY()), "first reveal starts above the panel even before the presentation layer exists")
        wait(0.10)
        let first = offset()
        check(first > 1 && first < LineSlideView.hiddenY - 1, "actual native window content is between hidden and shown at 100ms")
        wait(0.10)
        check(offset() < first, "later compositor frames continue moving down")
        check(host.frame.width == 1440 && host.frame.height == Layout.panelHeight, "animation never interpolates document width or height")
        wait(0.4)
        check(!panel.slideView.isAnimating && offset() == 0, "spring completes at the exact resting position")
        line.revealed = false
        let retract = host.superview!.layer!.animation(forKey: "clothesline-slide") as? CAKeyframeAnimation
        check(panel.slideView.isAnimating && (retract?.values?.first as? NSNumber)?.doubleValue == Double(baseY()), "retraction starts from the visible position before commit")
        wait(0.1)
        check(offset() > 0 && offset() < LineSlideView.hiddenY, "retraction has intermediate frames")
        let reversalStart = offset()
        line.revealed = true
        let reversal = host.superview!.layer!.animation(forKey: "clothesline-slide") as? CAKeyframeAnimation
        check(abs(((reversal?.values?.first as? NSNumber)?.doubleValue ?? -999) - Double(reversalStart + baseY())) < 1, "interrupting a retraction preserves the displayed position without a flash")
        wait(0.6)
        check(offset() == 0 && !panel.slideView.isAnimating, "reversed animation settles normally")
        line.revealed = false
        wait(0.3)
        check(host.superview!.isHidden, "retraction finishes fully hidden")
        panel.setFrame(CGRect(x: -10_000, y: -10_000, width: 800, height: Layout.panelHeight), display: true)
        panel.contentView?.layoutSubtreeIfNeeded()
        check(host.frame.width == 800 && host.superview!.isHidden, "display resize preserves hidden state and updates width immediately")
        line.revealed = true
        wait(0.1)
        check(offset() > 1 && offset() < LineSlideView.hiddenY - 1, "a second reveal on another width remains animated")
        wait(0.6)
        check(host.frame.width == 800 && offset() == 0, "resized display reveal settles with unchanged width")
        print("PASS: \(checks) actual intermediate reveal/retract frames, reversal, hidden first frame and fixed-layout checks")
    }
}
