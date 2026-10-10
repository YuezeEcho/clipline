import Foundation
import CoreGraphics

/// A validated pair is the only thing that toggles the line. Distinguish a
/// known interactive hit from a temporary AX failure after an app switch.
@MainActor
final class MenuBarActivation {
    typealias HitTest = @Sendable (CGPoint, CGFloat) async -> MenuBarHitTest.Result
    private let hitTest: HitTest
    private let retryDelay: @Sendable (Int) async -> Void
    private var trigger = MenuBarDoubleClickTrigger()
    private var validation: Task<Void, Never>?
    private var generation = 0
    private var pointerAnchor: (point: CGPoint, screen: CGRect)?
    var onActivate: ((MenuBarDoubleClickTrigger.Pair) -> Void)?

    init(hitTest: @escaping HitTest = { point, top in
        await Task.detached(priority: .userInitiated) {
            MenuBarHitTest.classify(at: point, primaryTop: top)
        }.value
    }, retryDelay: @escaping @Sendable (Int) async -> Void = { attempt in
        try? await Task.sleep(nanoseconds: attempt == 0 ? 80_000_000 : 160_000_000)
    }) {
        self.hitTest = hitTest
        self.retryDelay = retryDelay
    }

    func reset() {
        generation &+= 1
        trigger.reset()
        pointerAnchor = nil
        validation?.cancel()
        validation = nil
    }

    func drag(point: CGPoint, screen: CGRect) {
        guard let anchor = pointerAnchor, anchor.screen == screen,
              hypot(point.x - anchor.point.x, point.y - anchor.point.y) <= 10 else {
            reset()
            return
        }
    }

    func click(point: CGPoint, screen: CGRect, time: TimeInterval, interval: TimeInterval,
               context: Int32, wasRevealed: Bool, primaryTop: CGFloat) {
        pointerAnchor = (point, screen)
        guard let pair = trigger.click(point: point, screen: screen, time: time,
                                       interval: interval, context: context, wasRevealed: wasRevealed) else { return }
        generation &+= 1
        let token = generation
        validation?.cancel()
        let hitTest = self.hitTest, retryDelay = self.retryDelay
        validation = Task { [weak self] in
            for attempt in 0..<3 {
                guard !Task.isCancelled else { return }
                let first = await hitTest(pair.firstPoint, primaryTop)
                guard !Task.isCancelled else { return }
                if first == .occupied { return }
                let second = pair.firstPoint == pair.secondPoint ? first
                    : await hitTest(pair.secondPoint, primaryTop)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                if second == .occupied { return }
                if first == .blank && second == .blank {
                    self.onActivate?(pair)
                    return
                }
                if attempt < 2 { await retryDelay(attempt) }
            }
        }
    }
}
