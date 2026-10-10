import AppKit
import SwiftUI
import Combine
import QuartzCore

/// SwiftUI's plain buttons must accept the first click in this nonactivating panel.
final class LineHostingView: NSHostingView<LineView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A transparent strip along the top of the screen that floats over every
/// app and every Space, including full screen ones, never takes focus, and lets clicks pass through
/// outside the visible scroll row and its controls.
final class LinePanel: NSPanel {
    let slideView: LineSlideView
    private var revealObservation: AnyCancellable?

    init(content: NSView) {
        let line = (content as? LineHostingView)?.rootView.line
        slideView = LineSlideView(content: content, revealed: line?.revealed ?? true)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        contentView = slideView
        revealObservation = line?.$revealed.dropFirst().sink { [weak slideView] revealed in
            slideView?.setRevealed(revealed)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The line hangs on the screen you are using, which is the one with the
    /// pointer: that is where you just took the screenshot.
    static func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screen(containing: mouse)
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func screen(containing point: NSPoint) -> NSScreen? {
        // At a display boundary, prefer the screen whose top edge is being pushed.
        NSScreen.screens.first { TopEdgeTrigger.isAtEdge(point, in: $0.frame) }
            ?? NSScreen.screens.first { TopEdgeTrigger.contains(point, in: $0.frame) }
    }

    static func topInset(on screen: NSScreen) -> CGFloat {
        max(NSStatusBar.system.thickness, screen.safeAreaInsets.top,
            screen.frame.maxY - screen.visibleFrame.maxY)
    }

    func placeOnScreen(_ screen: NSScreen? = nil) {
        guard let screen = screen ?? LinePanel.screenUnderPointer() else { return }
        // Reserve menu-bar/notch space even when a fullscreen app auto-hides the menu bar.
        let target = NSRect(x: screen.frame.minX, y: screen.frame.maxY - Self.topInset(on: screen) - Layout.panelHeight,
                            width: screen.frame.width, height: Layout.panelHeight)
        if frame != target { setFrame(target, display: true) }
    }
}

/// Moves a fixed-size native layer, never a SwiftUI layout transaction. Starting
/// hidden also prevents the first screenshot from flashing at its final position.
final class LineSlideView: NSView {
    private let content: NSView
    private let movingView = NSView()
    private var timer: Timer?
    private var startY: CGFloat = 0
    private var targetY: CGFloat = 0
    private var duration: TimeInterval = 0
    private var offset: CGFloat = 0
    private(set) var revealed: Bool
    var isAnimating: Bool { timer != nil }
    static let hiddenY = Layout.panelHeight + 12
    static let revealDuration: TimeInterval = 0.52
    static let retractDuration: TimeInterval = 0.24

    init(content: NSView, revealed: Bool) {
        self.content = content
        self.revealed = revealed
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        movingView.wantsLayer = true
        movingView.isHidden = !revealed
        addSubview(movingView)
        movingView.addSubview(content)
        setOffset(revealed ? 0 : Self.hiddenY)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        if movingView.frame.size != bounds.size { movingView.setFrameSize(bounds.size) }
        if content.frame.size != bounds.size { content.setFrameSize(bounds.size) }
        setOffset(offset)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        movingView.setFrameSize(newSize)
        content.setFrameSize(newSize)
        setOffset(offset)
    }

    func setRevealed(_ revealed: Bool) {
        guard self.revealed != revealed else { return }
        self.revealed = revealed
        let baseY = (movingView.layer?.position.y ?? 0) - movingView.frame.minY
        startY = timer != nil ? (movingView.layer?.presentation().map { $0.position.y - baseY } ?? offset) : offset
        timer?.invalidate()
        targetY = revealed ? 0 : Self.hiddenY
        duration = revealed ? Self.revealDuration : Self.retractDuration
        movingView.layer?.removeAnimation(forKey: "clothesline-slide")
        let animation = CAKeyframeAnimation(keyPath: "position.y")
        animation.duration = duration
        animation.calculationMode = .linear
        animation.keyTimes = (0...60).map { NSNumber(value: Double($0) / 60) }
        animation.values = (0...60).map { index -> NSNumber in
            let t = Double(index) / 60
            let eased = revealed ? 1 - exp(-9 * t) * (cos(6.8 * t) + 9 / 6.8 * sin(6.8 * t)) : t * t
            return NSNumber(value: Double(baseY + (index == 60 ? targetY : startY + (targetY - startY) * CGFloat(eased))))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        movingView.isHidden = false
        setOffset(targetY)
        movingView.layer?.add(animation, forKey: "clothesline-slide")
        CATransaction.commit()
        // The compositor moves the layer even while SwiftUI is laying out a
        // long row. This timer only marks completion, never drives the frames.
        let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.movingView.layer?.removeAnimation(forKey: "clothesline-slide")
                if self?.revealed == false { self?.movingView.isHidden = true }
                self?.timer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func setOffset(_ y: CGFloat) {
        offset = y
        // Set the parent frame only at the endpoints. Intermediate movement
        // lives in its layer, leaving the hosted scroll geometry untouched.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        movingView.setFrameOrigin(NSPoint(x: 0, y: y))
        CATransaction.commit()
    }

    deinit { timer?.invalidate() }
}
