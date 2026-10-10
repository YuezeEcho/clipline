import Foundation
import CoreGraphics

/// Screen geometry shared by menu-bar activation and automatic retraction.
enum TopEdgeTrigger {
    static let edgeHeight: CGFloat = 6

    static func contains(_ point: CGPoint, in frame: CGRect) -> Bool {
        !frame.isEmpty && point.x >= frame.minX && point.x <= frame.maxX
            && point.y >= frame.minY && point.y <= frame.maxY
    }

    static func isAtEdge(_ point: CGPoint, in frame: CGRect) -> Bool {
        contains(point, in: frame) && point.y >= frame.maxY - edgeHeight
    }

    static func menuBarBand(frame: CGRect, height: CGFloat) -> CGRect {
        let h = min(frame.height, max(height, edgeHeight))
        return CGRect(x: frame.minX, y: frame.maxY - h, width: frame.width, height: h)
    }

}

/// Collect input before asynchronous accessibility validation. One click never
/// changes visibility, and a pair belongs to one screen and foreground app.
struct MenuBarDoubleClickTrigger {
    static func effectiveInterval(system: TimeInterval) -> TimeInterval {
        system.isFinite && system > 0 ? max(0.7, system) : 0.7
    }
    struct Pair: Sendable {
        let firstPoint: CGPoint
        let secondPoint: CGPoint
        let screen: CGRect
        let context: Int32
        let reveal: Bool
    }
    private struct FirstClick {
        let point: CGPoint
        let screen: CGRect
        let context: Int32
        let time: TimeInterval
        let reveal: Bool
    }
    private var first: FirstClick?

    mutating func reset() { first = nil }

    mutating func click(point: CGPoint, screen: CGRect, time: TimeInterval,
                        interval: TimeInterval, context: Int32, wasRevealed: Bool) -> Pair? {
        if let first, first.screen == screen, first.context == context, time >= first.time,
           time - first.time <= interval,
           hypot(point.x - first.point.x, point.y - first.point.y) <= 10 {
            self.first = nil
            return Pair(firstPoint: first.point, secondPoint: point, screen: screen,
                        context: context, reveal: first.reveal)
        }
        first = FirstClick(point: point, screen: screen, context: context,
                           time: time, reveal: !wasRevealed)
        return nil
    }
}
