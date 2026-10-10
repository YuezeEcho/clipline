import SwiftUI

enum Layout {
    static let panelHeight: CGFloat = 210
    static let ropeTop: CGFloat = 10
    static let spacing: CGFloat = 174
    static let cardWidth: CGFloat = 150
    static let pinAbove: CGFloat = 9.5

    /// The rope hangs as a parabola from edge to edge of the screen.
    static func sag(width: CGFloat) -> CGFloat { min(30, width * 0.018) }

    static func ropeY(x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return ropeTop }
        let f = x / width
        return ropeTop + 4 * sag(width: width) * f * (1 - f)
    }

}

struct LineView: View {
    @ObservedObject private var language = AppLanguage.shared
    @ObservedObject var line: Line
    @ObservedObject var clipboard: ClipboardHistory
    @ObservedObject var pinnedPhotos: PinnedPhotos

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                Rope(width: width)

                ZStack {
                    if line.section == .clipboard {
                        ClipboardView(history: clipboard, gust: line.gust)
                            .transition(.asymmetric(insertion: .move(edge: .trailing),
                                                    removal: .move(edge: .trailing))
                                .animation(.spring(response: 0.48, dampingFraction: 0.9)))
                    } else {
                        ZStack(alignment: .topLeading) {
                            ScreenshotRow(line: line, hasPinnedPhotos: !pinnedPhotos.photos.isEmpty)
                            PinnedPhotoLayer(photos: pinnedPhotos, line: line, width: width)
                                .zIndex(1)
                        }
                            .transition(.asymmetric(insertion: .move(edge: .leading),
                                                    removal: .move(edge: .leading))
                                .animation(.spring(response: 0.48, dampingFraction: 0.9)))
                    }
                }
                .frame(width: width, height: 172)
                .clipped()

                if line.showsControls {
                    controls
                        .position(x: width / 2, y: 189)
                        .transition(.opacity)
                }
            }
            .coordinateSpace(name: "line")
            .animation(.easeInOut(duration: 0.3), value: line.items.isEmpty)
            // LinePanel slides the hosting view independently. The screenshot
            // document keeps its final width throughout the reveal animation.
        }
        .onPreferenceChange(HitRectsKey.self) { rects in
            MainActor.assumeIsolated { line.hitRects = rects }
        }
        .onPreferenceChange(ScreenshotLayoutRectsKey.self) { rects in
            MainActor.assumeIsolated { line.cardLayoutRects = rects }
        }
        .onPreferenceChange(LineControlsKey.self) { rect in
            MainActor.assumeIsolated { line.controlsRect = rect }
        }
        .onPreferenceChange(PinnedHitRectsKey.self) { rects in
            MainActor.assumeIsolated { pinnedPhotos.hitRects = rects }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                sectionButton(.screenshots, title: C("Captures", "截图与录屏", "截圖與錄影"), count: line.liveCount, icon: "photo")
                sectionButton(.clipboard, title: C("Clipboard", "剪贴板"), count: clipboard.entries.count, icon: "doc.on.clipboard")
            }
            .padding(3)
            .glassFrame(capsule: true)

            if line.section == .clipboard {
                Label(clipboard.isTracking ? C("Recording", "正在记录") : C("Paused", "已暂停"),
                      systemImage: clipboard.isTracking ? "circle.fill" : "pause.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(clipboard.isTracking ? Color.secondary : Color.orange)
                    .help(C("Clipboard history is cleared on quit", "剪贴板历史退出后清空"))
                Button { clipboard.setTracking(!clipboard.isTracking) } label: {
                    Image(systemName: clipboard.isTracking ? "pause.circle" : "play.circle")
                        .font(.system(size: 15))
                        .frame(width: 26, height: 26)
                }
                .help(clipboard.isTracking ? C("Pause recording", "暂停记录") : C("Resume recording", "继续记录"))
                .accessibilityLabel(clipboard.isTracking ? C("Pause recording", "暂停记录") : C("Resume recording", "继续记录"))
                Button { clipboard.clear() } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .frame(width: 26, height: 26)
                }
                .disabled(clipboard.entries.isEmpty)
                .help(C("Clear clipboard history", "清空剪贴板历史"))
                .accessibilityLabel(C("Clear clipboard history", "清空剪贴板历史"))
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .glassFrame(capsule: true)
        .background(GeometryReader { g in
            Color.clear.preference(key: LineControlsKey.self, value: g.frame(in: .named("line")))
        })
    }

    private func sectionButton(_ section: Line.Section, title: String, count: Int, icon: String) -> some View {
        Button { line.section = section } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(title)
                Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 12)
            .frame(height: 25)
            .background(line.section == section ? Color.primary.opacity(0.12) : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .accessibilityAddTraits(line.section == section ? .isSelected : [])
    }
}

private struct LineControlsKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}

struct Hint: View {
    @ObservedObject private var language = AppLanguage.shared
    var body: some View {
        Text(L("Take a screenshot and it will hang here", "Haz una captura y se quedará colgada aquí"))
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
    }
}

/// A scrollable line of thumbnails. A short row stays centred on the rope;
/// longer rows scroll, with the latest capture brought into view.
private struct ScreenshotRow: View {
    @ObservedObject var line: Line
    let hasPinnedPhotos: Bool
    private static let tailID = "screenshot-tail"

    var body: some View {
        GeometryReader { geo in
            if line.items.isEmpty {
                if !hasPinnedPhotos {
                    Hint()
                        .position(x: geo.size.width / 2,
                                  y: Layout.ropeY(x: geo.size.width / 2, width: geo.size.width) + 34)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 0) {
                            // At most 100 bounded thumbnails: measuring every
                            // slot avoids lazy width estimates at capture time.
                            HStack(alignment: .top, spacing: Layout.spacing - Layout.cardWidth) {
                                ForEach(line.items) { item in
                                    HangingCard(screenWidth: geo.size.width) {
                                        PeggedView(item: item, line: line)
                                    }
                                    .background(GeometryReader { g in
                                        let frame = g.frame(in: .named("line"))
                                        let x = min(geo.size.width, max(0, frame.midX))
                                        let sag = Layout.ropeY(x: x, width: geo.size.width) - Layout.ropeTop
                                        let size = PeggedView.cardSize(for: item.thumb.size)
                                        Color.clear.preference(key: ScreenshotLayoutRectsKey.self, value: [item.id:
                                            CGRect(x: frame.midX - size.width / 2,
                                                   y: frame.minY + sag + PeggedView.cardOffsetBelowTop,
                                                   width: size.width, height: size.height)])
                                    })
                                    .id(item.id)
                                }
                            }
                            .padding(.leading, 28)
                            // Target the real padded end, so the last photo's
                            // border, tilt and shadow stay inside the display.
                            Color.clear.frame(width: 28, height: 1).id(Self.tailID)
                        }
                        .padding(.top, Layout.ropeTop - Layout.pinAbove)
                        .frame(minWidth: geo.size.width, alignment: .center)
                        .background(ScreenshotScrollBridge(line: line).frame(width: 1, height: 1), alignment: .topLeading)
                    }
                    .scrollIndicators(.hidden)
                    .onAppear { scrollToLatest(proxy) }
                    .onChange(of: line.items.last(where: { !$0.falling })?.id) { _, _ in
                        scrollToLatest(proxy)
                    }
                    .onChange(of: geo.size.width) { _, _ in scrollToLatest(proxy) }
                }
                .background(GeometryReader { g in
                    Color.clear.preference(key: ScreenshotViewportKey.self,
                                           value: g.frame(in: .named("line")))
                })
            }
        }
        .onPreferenceChange(ScreenshotViewportKey.self) { rect in
            MainActor.assumeIsolated { line.interactionRect = rect }
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard line.items.contains(where: { !$0.falling }) else { return }
        DispatchQueue.main.async { proxy.scrollTo(Self.tailID, anchor: .trailing) }
    }
}

/// Remember this row's native scroll view for wheel events over the fixed layer.
private struct ScreenshotScrollBridge: NSViewRepresentable {
    @ObservedObject var line: Line
    func makeNSView(context: Context) -> ScreenshotScrollProbe {
        let view = ScreenshotScrollProbe()
        view.line = line
        return view
    }
    func updateNSView(_ view: ScreenshotScrollProbe, context: Context) { view.resolve() }
    static func dismantleNSView(_ view: ScreenshotScrollProbe, coordinator: ()) { view.invalidate() }
}

private final class ScreenshotScrollProbe: NSView {
    weak var line: Line?
    private weak var observedScroll: NSScrollView?
    private var observations: [NSObjectProtocol] = []
    private var invalidated = false
    private var latestID: UUID?
    private var viewportWidth: CGFloat = 0
    private var pendingLatest = false
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); resolve() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); resolve() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func resolve() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard !self.invalidated else { return }
            guard self.line?.section == .screenshots,
                  self.window != nil, let scroll = self.enclosingScrollView else {
                self.detach()
                return
            }
            if self.observedScroll !== scroll {
                self.detach()
                self.observedScroll = scroll
                let clip = scroll.contentView
                clip.postsBoundsChangedNotifications = true
                self.observe(NSView.boundsDidChangeNotification, object: clip)
                clip.postsFrameChangedNotifications = true
                self.observe(NSView.frameDidChangeNotification, object: clip)
                if let document = scroll.documentView {
                    document.postsFrameChangedNotifications = true
                    self.observe(NSView.frameDidChangeNotification, object: document)
                }
            }
            self.line?.screenshotScrollView = scroll
            self.sample()
        }
    }
    private func observe(_ name: Notification.Name, object: NSView) {
        let observer = NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        observations.append(observer)
    }
    private func sample() {
        if let line, let scroll = observedScroll, line.section == .screenshots {
            let latest = line.items.last(where: { !$0.falling })?.id
            if latestID != latest || abs(viewportWidth - scroll.contentView.bounds.width) > 0.5 {
                latestID = latest
                viewportWidth = scroll.contentView.bounds.width
                pendingLatest = latest != nil
            }
        }
        settleLatestIfNeeded()
        guard let line, let scroll = observedScroll,
              scroll.window != nil, line.screenshotScrollView === scroll,
              line.section == .screenshots, line.revealed else { return }
        line.scrollSway.record(offset: scroll.contentView.bounds.minX,
                              viewportWidth: scroll.contentView.bounds.width,
                              contentWidth: scroll.documentView?.bounds.width ?? 0)
    }

    private func settleLatestIfNeeded() {
        guard pendingLatest, let line, line.section == .screenshots,
              let scroll = observedScroll, let document = scroll.documentView else { return }
        // SwiftUI can defer a hidden row's scrollTo until its document is laid
        // out. Wait for the complete fixed-width row, then align the real tail.
        let rowWidth = CGFloat(line.items.count) * Layout.spacing + 56 - (Layout.spacing - Layout.cardWidth)
        let expectedWidth = max(scroll.contentView.bounds.width, rowWidth)
        guard abs(document.bounds.width - expectedWidth) < 1 else { return }
        pendingLatest = false
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: max(0, document.bounds.width - clip.bounds.width), y: clip.bounds.minY))
        scroll.reflectScrolledClipView(clip)
    }
    func detach() {
        for observer in observations { NotificationCenter.default.removeObserver(observer) }
        observations.removeAll()
        if let scroll = observedScroll, line?.screenshotScrollView === scroll {
            line?.screenshotScrollView = nil
            line?.scrollSway.reset()
        }
        observedScroll = nil
    }
    func invalidate() {
        invalidated = true
        detach()
    }
    deinit {
        for observer in observations { NotificationCenter.default.removeObserver(observer) }
    }
}

private struct ScreenshotViewportKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}

private struct ScreenshotLayoutRectsKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Keep the pin on the curved rope as a card moves through either scroll row.
struct HangingCard<Content: View>: View {
    let screenWidth: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geo in
            let x = min(screenWidth, max(0, geo.frame(in: .named("line")).midX))
            let sag = Layout.ropeY(x: x, width: screenWidth) - Layout.ropeTop
            content
                .offset(y: sag)
                .frame(width: Layout.cardWidth, height: 166, alignment: .top)
        }
        .frame(width: Layout.cardWidth, height: 166, alignment: .top)
    }
}

/// A thin, neutral line: a mid gray core with a faint highlight and a soft
/// shadow, so it reads on light and dark backgrounds alike. It fades out at
/// both ends so it seems to come from beyond the screen.
struct Rope: View {
    let width: CGFloat

    private var path: Path {
        Path { p in
            let top = Layout.ropeTop
            p.move(to: CGPoint(x: -20, y: top))
            p.addQuadCurve(
                to: CGPoint(x: width + 20, y: top),
                control: CGPoint(x: width / 2, y: top + 2 * Layout.sag(width: width)))
        }
    }

    var body: some View {
        ZStack {
            path.stroke(Color.black.opacity(0.22), lineWidth: 1.4).offset(y: 1.2).blur(radius: 1.2)
            path.stroke(Color(white: 0.55), lineWidth: 1.2)
            path.stroke(Color.white.opacity(0.45), lineWidth: 0.4).offset(y: -0.35)
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.08),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        )
        .allowsHitTesting(false)
    }
}

struct HitRectsKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
