import Combine
import CoreGraphics
import Foundation

/// A small rope impulse from actual horizontal scrolling. Layout changes only
/// establish a baseline, so adding a capture never looks like a user gesture.
@MainActor
final class ScrollSway: ObservableObject {
    @Published private(set) var angle: Double = 0

    private struct Geometry {
        let viewport: CGFloat
        let content: CGFloat
    }

    private var geometry: Geometry?
    private var observedOffset: CGFloat?
    private var drivenOffset: CGFloat?
    private var drivenTime: TimeInterval?
    private var filteredVelocity: Double = 0
    private var stopTimer: Timer?
    private var stopGeneration: UInt = 0

    private static let sampleInterval: TimeInterval = 1.0 / 60.0
    private static let stoppingDelay: TimeInterval = 0.12
    private static let maximumAngle: Double = 5

    func record(offset: CGFloat, viewportWidth: CGFloat, contentWidth: CGFloat,
                now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard offset.isFinite, viewportWidth.isFinite, contentWidth.isFinite,
              now.isFinite, viewportWidth > 0, contentWidth > viewportWidth + 0.5 else {
            reset()
            return
        }

        guard let geometry,
              abs(geometry.viewport - viewportWidth) <= 0.5,
              abs(geometry.content - contentWidth) <= 0.5,
              let observedOffset, let drivenOffset else {
            establishBaseline(offset: offset, viewport: viewportWidth, content: contentWidth, now: now)
            return
        }

        if let drivenTime, now < drivenTime {
            establishBaseline(offset: offset, viewport: viewportWidth, content: contentWidth, now: now)
            return
        }

        // Bounds notifications also arrive for vertical movement and layout.
        // Neither refreshes the stop deadline when the horizontal offset stays put.
        guard abs(offset - observedOffset) > 0.01 else { return }
        self.observedOffset = offset
        scheduleStop()

        let elapsed = drivenTime.map { now - $0 } ?? Self.sampleInterval
        guard elapsed >= Self.sampleInterval else { return }
        // After an idle period, the first wheel delta belongs to a new gesture,
        // not to the entire interval since the previous bounds notification.
        let dt = min(0.08, max(Self.sampleInterval, elapsed))
        let velocity = Double(offset - drivenOffset) / dt
        let smoothing = 1 - exp(-dt / 0.055)
        filteredVelocity += (velocity - filteredVelocity) * smoothing
        let target = Self.maximumAngle * tanh(filteredVelocity / 850)
        if abs(target - angle) > 0.001 { angle = target }
        self.drivenOffset = offset
        drivenTime = now
    }

    func reset() {
        stopGeneration &+= 1
        stopTimer?.invalidate()
        stopTimer = nil
        geometry = nil
        observedOffset = nil
        drivenOffset = nil
        drivenTime = nil
        filteredVelocity = 0
        if angle != 0 { angle = 0 }
    }

    private func establishBaseline(offset: CGFloat, viewport: CGFloat, content: CGFloat,
                                   now: TimeInterval) {
        reset()
        geometry = Geometry(viewport: viewport, content: content)
        observedOffset = offset
        drivenOffset = offset
        // The first actual delta must respond even if it arrives within one
        // frame of layout. Throttle only after publishing a movement sample.
        drivenTime = nil
    }

    private func scheduleStop() {
        // Extend one one-shot timer during a gesture instead of allocating a
        // delayed task per event or keeping a frame-rate timer alive when idle.
        if let stopTimer {
            stopTimer.fireDate = Date(timeIntervalSinceNow: Self.stoppingDelay)
            return
        }
        stopGeneration &+= 1
        let generation = stopGeneration
        let timer = Timer(timeInterval: Self.stoppingDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.stopGeneration == generation else { return }
                self.stopTimer = nil
                self.filteredVelocity = 0
                self.drivenOffset = self.observedOffset
                self.drivenTime = nil
                if self.angle != 0 { self.angle = 0 }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        stopTimer = timer
    }
}
