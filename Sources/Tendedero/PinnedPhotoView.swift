import SwiftUI

/// Favourites stay in screen coordinates while the screenshot row scrolls behind.
struct PinnedPhotoLayer: View {
    @ObservedObject var photos: PinnedPhotos
    @ObservedObject var line: Line
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(photos.visiblePhotos(width: width)) { photo in
                let x = PinnedPhotos.center(position: photo.position, width: width)
                PinnedPhotoView(photo: photo, photos: photos, line: line, scrollSway: line.scrollSway, width: width)
                    .frame(width: Layout.cardWidth, height: 166, alignment: .top)
                    .position(x: x, y: Layout.ropeY(x: x, width: width) - Layout.pinAbove + 83)
                    .transition(.opacity)
            }
        }
        .frame(width: width, height: 172, alignment: .topLeading)
    }
}

private struct PinnedPhotoView: View {
    @ObservedObject private var language = AppLanguage.shared
    let photo: PinnedPhotos.Photo
    @ObservedObject var photos: PinnedPhotos
    @ObservedObject var line: Line
    @ObservedObject var scrollSway: ScrollSway
    let width: CGFloat
    @State private var arrived = false
    @State private var hovering = false
    @State private var swing: Double = 0
    @State private var dragOffset: CGFloat = 0

    private var center: CGFloat { PinnedPhotos.center(position: photo.position, width: width) }
    private var draggedCenter: CGFloat {
        PinnedPhotos.center(position: (center + dragOffset) / max(1, width), width: width)
    }

    var body: some View {
        VStack(spacing: -12) {
            Clothespin(isBlack: true).zIndex(1)
            Image(nsImage: photo.thumbnail)
                .resizable()
                .interpolation(.high)
                .frame(width: PeggedView.photoSize(for: photo.thumbnail.size).width,
                       height: PeggedView.photoSize(for: photo.thumbnail.size).height)
                .clipShape(RoundedRectangle(cornerRadius: Frame.radius - Frame.inset))
                .padding(Frame.inset)
                .glassFrame(cornerRadius: Frame.radius)
                .shadow(color: .black.opacity(hovering ? 0.3 : 0.24), radius: hovering ? 14 : 10, y: 6)
                .scaleEffect(hovering ? 1.025 : 1, anchor: .top)
                .overlay(alignment: .topLeading) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 20, height: 20)
                        .glassFrame(circle: true)
                        .padding(3)
                        .opacity(hovering ? 1 : 0)
                        .allowsHitTesting(false)
                }
                .overlay(PinnedGrabArea(photo: photo, photos: photos, line: line, width: width,
                                        onClick: { nudge(3) },
                                        onDrag: { dragOffset = $0 },
                                        onDrop: { delta in
                                            photos.move(photo.id, atX: center + delta, width: width)
                                            dragOffset = 0
                                            nudge(2)
                                        }))
                .background(GeometryReader { g in
                    Color.clear.preference(key: PinnedHitRectsKey.self,
                                           value: [photo.id: g.frame(in: .named("line"))])
                })
                .onHover { hovering = $0 }
                .accessibilityLabel(C("Pinned photo", "固定图片"))
                .help(C("Drag along the rope to move; double-click or right-click for options",
                        "沿晾绳拖动调整位置；双击或右键打开选项"))
        }
        .rotationEffect(.degrees(photo.tilt + swing + scrollingSwing), anchor: .top)
        .animation(.interpolatingSpring(stiffness: 100, damping: 9), value: scrollingSwing)
        .offset(x: draggedCenter - center,
                y: (arrived ? 0 : -46) + Layout.ropeY(x: draggedCenter, width: width) - Layout.ropeY(x: center, width: width))
        .opacity(arrived ? 1 : 0)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: hovering)
        .onAppear {
            swing = 16
            withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) { arrived = true }
            withAnimation(.interpolatingSpring(stiffness: 46, damping: 2.6)) { swing = 0 }
        }
        .onChange(of: line.gust) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 0...0.35)) {
                nudge(Double.random(in: 1.6...3.4))
            }
        }
    }

    private var scrollingSwing: Double {
        guard photos.draggingID != photo.id else { return 0 }
        // The middle of the rope gives a little more than the supported ends.
        let gain = 0.9 + 0.1 * sin(Double(photo.position) * .pi)
        return scrollSway.angle * gain
    }

    private func nudge(_ degrees: Double) {
        withAnimation(.easeOut(duration: 0.3)) { swing = degrees }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.interpolatingSpring(stiffness: 38, damping: 2.4)) { swing = 0 }
        }
    }
}

private struct PinnedGrabArea: NSViewRepresentable {
    let photo: PinnedPhotos.Photo
    let photos: PinnedPhotos
    let line: Line
    let width: CGFloat
    let onClick: () -> Void
    let onDrag: (CGFloat) -> Void
    let onDrop: (CGFloat) -> Void

    func makeNSView(context: Context) -> PinnedGrabView {
        let view = PinnedGrabView()
        configure(view)
        return view
    }
    func updateNSView(_ view: PinnedGrabView, context: Context) { configure(view) }
    static func dismantleNSView(_ view: PinnedGrabView, coordinator: ()) { view.cancelInteraction() }
    private func configure(_ view: PinnedGrabView) {
        view.onClick = onClick
        view.onDrag = onDrag
        view.onDrop = onDrop
        view.onBegin = { line.beginInteraction() }
        view.onEnd = { line.endInteraction() }
        view.onDragStart = { photos.draggingID = photo.id }
        view.onDragEnd = { photos.draggingID = nil; onDrag(0) }
        view.onRemove = { photos.remove(photo.id) }
        view.scrollProvider = { [weak line] in line?.screenshotScrollView }
        view.menuProvider = {
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(ClosureMenuItem(C("Replace image…", "更换图片…")) {
                line.onRequestReplacePin?(photo.id)
            })
            let positions = NSMenuItem(title: C("Move to", "移到"), action: nil, keyEquivalent: "")
            let options = NSMenu()
            options.autoenablesItems = false
            for (title, fraction) in [(C("Left", "左端"), 0.0), (C("Center", "中间"), 0.5), (C("Right", "右端"), 1.0)] {
                options.addItem(ClosureMenuItem(title) { photos.move(photo.id, atX: width * fraction, width: width) })
            }
            positions.submenu = options
            menu.addItem(positions)
            menu.addItem(ClosureMenuItem(C("Open", "打开")) { NSWorkspace.shared.open(photo.url) })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(C("Unpin", "取消固定")) { photos.remove(photo.id) })
            return menu
        }
    }
}

/// Native mouse handling leaves wheel events with the scrolling screenshots.
final class PinnedGrabView: NSView {
    var onClick: () -> Void = {}
    var onDrag: (CGFloat) -> Void = { _ in }
    var onDrop: (CGFloat) -> Void = { _ in }
    var onBegin: () -> Void = {}
    var onEnd: () -> Void = {}
    var onDragStart: () -> Void = {}
    var onDragEnd: () -> Void = {}
    var onRemove: () -> Void = {}
    var menuProvider: () -> NSMenu = { NSMenu() }
    var scrollProvider: () -> NSScrollView? = { nil }
    private var downX: CGFloat?
    private var dragging = false
    private var delta: CGFloat = 0

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
        finishPress()
        if event.clickCount == 2 { showMenu(with: event); return }
        let p = convert(event.locationInWindow, from: nil)
        let cross = NSRect(x: 0, y: isFlipped ? 0 : bounds.height - 26, width: 26, height: 26)
        if cross.contains(p) { onRemove(); return }
        downX = event.locationInWindow.x
        delta = 0
        dragging = false
        onBegin()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let x = downX else { return }
        delta = event.locationInWindow.x - x
        guard dragging || abs(delta) > 4 else { return }
        if !dragging { dragging = true; onDragStart() }
        onDrag(delta)
    }
    override func mouseUp(with event: NSEvent) {
        guard downX != nil else { return }
        if dragging { onDrop(delta) } else { onClick() }
        finishPress()
    }
    override func rightMouseDown(with event: NSEvent) { showMenu(with: event) }
    override func scrollWheel(with event: NSEvent) {
        if let scrollView = scrollProvider() { scrollView.scrollWheel(with: event) }
        else { super.scrollWheel(with: event) }
    }
    func cancelInteraction() { finishPress() }
    private func finishPress() {
        if downX != nil { downX = nil; onEnd() }
        if dragging { dragging = false; onDragEnd() }
    }
    private func showMenu(with event: NSEvent) {
        finishPress()
        onBegin()
        defer { onEnd() }
        NSMenu.popUpContextMenu(menuProvider(), with: event, for: self)
    }
}

struct PinnedHitRectsKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
