import CoreGraphics
import Foundation

/// These checks use only the model and main run loop; no app, window, user
/// clipboard, screenshot directory, or persisted preferences are accessed.
@main
struct ScrollSwayChecks {
    @MainActor static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAIL: " + message) }
            checks += 1
        }
        let sway = ScrollSway()
        func sample(_ offset: CGFloat, _ time: TimeInterval, viewport: CGFloat = 1000,
                    content: CGFloat = 3000) {
            sway.record(offset: offset, viewportWidth: viewport, contentWidth: content, now: time)
        }
        func run(_ duration: TimeInterval) {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: duration))
        }

        check(sway.angle == 0, "initial rope is still")
        sample(500, 0)
        check(sway.angle == 0, "first nonzero offset establishes a baseline")
        sample(502, 0.005)
        check(sway.angle > 0, "a lone first delta inside one frame responds immediately")
        run(0.16)
        check(sway.angle == 0, "a lone short gesture relaxes without requiring another input")
        sway.reset()
        sample(500, 0)
        sample(520, 0.02)
        check(sway.angle > 0 && sway.angle < 5, "positive movement gives a subtle positive impulse")
        let firstAngle = sway.angle
        sample(540, 0.025)
        check(sway.angle == firstAngle, "subframe notifications are throttled")
        sample(560, 0.04)
        check(sway.angle > firstAngle, "throttled movement accumulates into the next sample")
        let movingAngle = sway.angle
        sample(560, 0.06)
        check(sway.angle == movingAngle, "unchanged horizontal bounds have no new impulse")

        sway.reset()
        check(sway.angle == 0, "reset immediately stops sway")
        sample(100, 1)
        sample(80, 1.02)
        check(sway.angle < 0, "reverse scrolling changes the sway direction")
        sway.reset()
        sample(0, 2)
        sample(2, 2.02)
        let slowAngle = sway.angle
        check(slowAngle > 0, "slow scrolling produces visible movement")
        sway.reset()
        sample(0, 3)
        sample(80, 3.02)
        let fastAngle = sway.angle
        check(fastAngle > slowAngle, "faster scrolling produces stronger sway")
        sample(10000, 3.04)
        check(sway.angle <= 5 && sway.angle > 0 && sway.angle.isFinite,
              "large wheel deltas stay within the five-degree limit")
        sample(-10000, 3.06)
        check(sway.angle >= -5 && sway.angle < 0 && sway.angle.isFinite,
              "large reversed deltas stay within the five-degree limit")

        sample(700, 3.1, viewport: 1400)
        check(sway.angle == 0, "resizing re-establishes the baseline without swaying")
        sample(720, 3.12, viewport: 1400)
        check(sway.angle > 0, "normal movement works after a resize")
        sample(0, 3.14, viewport: 1400, content: 3174)
        check(sway.angle == 0, "new screenshot content width clears layout-generated movement")
        sample(20, 3.16, viewport: 1400, content: 3174)
        check(sway.angle > 0, "a gesture after an insert uses the new baseline")
        sample(40, 2.5, viewport: 1400, content: 3174)
        check(sway.angle == 0, "a regressed clock resets instead of creating extreme velocity")
        sample(60, 2.52, viewport: 1400, content: 3174)
        check(sway.angle > 0, "movement resumes after a clock reset")

        sample(60, 2.6, viewport: 1400, content: 1400)
        check(sway.angle == 0, "non-scrollable content does not drive the rope")
        sample(.nan, 4)
        check(sway.angle == 0, "invalid offsets are ignored safely")
        sample(0, 4, viewport: .infinity)
        check(sway.angle == 0, "invalid viewport dimensions are ignored safely")
        sample(0, 4, content: .infinity)
        check(sway.angle == 0, "invalid content dimensions are ignored safely")
        sample(0, .nan)
        check(sway.angle == 0, "invalid timestamps are ignored safely")

        sample(0, 5)
        sample(20, 5.02)
        check(sway.angle > 0, "idle-stop test starts with movement")
        run(0.16)
        check(sway.angle == 0, "sway automatically relaxes after the last actual horizontal movement")
        sample(40, 5.04)
        check(sway.angle > 0, "the next gesture responds immediately after stopping")
        run(0.07)
        sample(60, 5.06)
        let extendedAngle = sway.angle
        run(0.07)
        check(sway.angle == extendedAngle && sway.angle > 0,
              "continued movement extends the stop deadline instead of an old stop interrupting it")
        run(0.07)
        check(sway.angle == 0, "an extended gesture still stops when its movement ends")

        sample(80, 5.08)
        check(sway.angle > 0, "a new gesture can begin again")
        run(0.06)
        sway.reset()
        sample(200, 6)
        check(sway.angle == 0, "reset removes the old gesture baseline")
        sample(220, 6.02)
        let newAngle = sway.angle
        run(0.075)
        check(sway.angle == newAngle && sway.angle > 0,
              "reset cancels the old stop callback so it cannot clear a new gesture")
        sample(220, 6.04)
        run(0.07)
        check(sway.angle == 0, "unchanged horizontal notifications do not extend the stop deadline")

        sample(400, 7)
        sample(420, 7.02)
        sway.reset()
        run(0.16)
        check(sway.angle == 0, "reset leaves no pending movement or stop task")
        print("PASS: \(checks) scroll-sway checks")
    }
}
