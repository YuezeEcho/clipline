import AppKit
import AVFoundation
import Combine
import SwiftUI

/// One muted player for the entire rope. No player exists for idle cards.
@MainActor
final class VideoPreview: ObservableObject {
    @Published private(set) var activeID: UUID?
    private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var pending: DispatchWorkItem?
    private var requestedID: UUID?

    func start(_ id: UUID, url: URL) {
        guard requestedID != id else { return }
        stop()
        requestedID = id
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.requestedID == id else { return }
            let player = AVQueuePlayer()
            player.isMuted = true
            player.volume = 0
            self.player = player
            self.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            self.activeID = id
            player.play()
        }
        pending = work
        // Passing over a movie during scrolling doesn't start decoding it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func stop(_ id: UUID? = nil) {
        if let id, requestedID != id { return }
        pending?.cancel()
        pending = nil
        player?.pause()
        looper?.disableLooping()
        player?.removeAllItems()
        looper = nil
        player = nil
        requestedID = nil
        activeID = nil
    }
}

struct VideoPreviewSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> MovieLayerView { MovieLayerView() }
    func updateNSView(_ view: MovieLayerView, context: Context) { view.videoLayer.player = player }
    static func dismantleNSView(_ view: MovieLayerView, coordinator: ()) { view.videoLayer.player = nil }
}

final class MovieLayerView: NSView {
    let videoLayer = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        videoLayer.videoGravity = .resizeAspect
        layer?.addSublayer(videoLayer)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }
}
