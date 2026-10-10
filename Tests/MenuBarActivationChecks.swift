import Foundation
import CoreGraphics

actor ScriptedHits {
    private var results: [MenuBarHitTest.Result]
    private var calls = 0
    init(_ results: [MenuBarHitTest.Result]) { self.results = results }
    func next() -> MenuBarHitTest.Result {
        calls += 1
        return results.isEmpty ? .unavailable : results.removeFirst()
    }
    func count() -> Int { calls }
}

actor DelayedHit {
    private var continuation: CheckedContinuation<MenuBarHitTest.Result, Never>?
    func next() async -> MenuBarHitTest.Result {
        await withCheckedContinuation { continuation = $0 }
    }
    func ready() -> Bool { continuation != nil }
    func release() { continuation?.resume(returning: .blank); continuation = nil }
}

/// Async regressions simulate a rebuilding menu bar; no live UI is accessed.
@main struct MenuBarActivationChecks {
    @MainActor static func main() async {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            guard value else { fatalError("FAIL: " + message) }; checks += 1
        }
        func settle() async { try? await Task.sleep(nanoseconds: 30_000_000) }
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let p = CGPoint(x: 700, y: 886)
        func click(_ activation: MenuBarActivation, _ time: Double, shown: Bool = false,
                   point: CGPoint? = nil, context: Int32 = 42) {
            activation.click(point: point ?? p, screen: frame, time: time,
                             interval: MenuBarDoubleClickTrigger.effectiveInterval(system: 0.3),
                             context: context, wasRevealed: shown, primaryTop: 900)
        }
        func model(_ hits: ScriptedHits) -> MenuBarActivation {
            MenuBarActivation(hitTest: { _, _ in await hits.next() }, retryDelay: { _ in await Task.yield() })
        }
        let hits = ScriptedHits([.blank, .blank])
        let activation = model(hits)
        var shown: [Bool] = []
        activation.onActivate = { shown.append($0.reveal) }
        click(activation, 1)
        await settle()
        let countAfterOne = await hits.count()
        check(shown.isEmpty && countAfterOne == 0, "single blank click neither toggles nor queues an AX query")
        click(activation, 1.6)
        await settle()
        check(shown == [true], "a 0.6-second pair opens despite a fast system double-click setting")
        let samePointCalls = await hits.count()
        check(samePointCalls == 1, "same-point pair validates once instead of serially checking two clicks")
        click(activation, 1.7, shown: true)
        await settle()
        check(shown == [true], "a third click cannot immediately retract the just-opened line")
        click(activation, 2.1, shown: true)
        await settle()
        check(shown == [true, false], "a second complete pair closes the line exactly once")

        let warmingHits = ScriptedHits([.unavailable, .unavailable, .blank])
        let warming = model(warmingHits)
        var warmActions = 0
        warming.onActivate = { _ in warmActions += 1 }
        click(warming, 3); click(warming, 3.2)
        await settle()
        let warmCalls = await warmingHits.count()
        check(warmActions == 1 && warmCalls == 3, "menu bar becoming available after two failures still completes the original double-click")
        let occupiedHits = ScriptedHits([.occupied, .blank])
        let occupied = model(occupiedHits)
        var occupiedActions = 0
        occupied.onActivate = { _ in occupiedActions += 1 }
        click(occupied, 4); click(occupied, 4.2)
        await settle()
        let occupiedCalls = await occupiedHits.count()
        check(occupiedActions == 0 && occupiedCalls == 1, "menu/status item immediately rejects the pair without retry")
        let partialHits = ScriptedHits([.blank, .occupied])
        let partial = model(partialHits)
        var partialActions = 0
        partial.onActivate = { _ in partialActions += 1 }
        click(partial, 5); click(partial, 5.2, point: CGPoint(x: 707, y: 886))
        await settle()
        let partialCalls = await partialHits.count()
        check(partialActions == 0 && partialCalls == 2, "pointer jitter still validates both locations; a menu boundary cannot trigger")
        let jitterHits = ScriptedHits([.blank, .blank])
        let jitter = model(jitterHits)
        var jitterActions = 0
        jitter.onActivate = { _ in jitterActions += 1 }
        click(jitter, 6)
        jitter.drag(point: CGPoint(x: 703, y: 886), screen: frame)
        click(jitter, 6.2, point: CGPoint(x: 708, y: 886))
        await settle()
        check(jitterActions == 1, "minor mouse-down drag and trackpad jitter do not cancel a blank pair")
        let draggingHits = ScriptedHits([.blank])
        let dragging = model(draggingHits)
        var draggingActions = 0
        dragging.onActivate = { _ in draggingActions += 1 }
        click(dragging, 6.4)
        dragging.drag(point: CGPoint(x: 725, y: 886), screen: frame)
        click(dragging, 6.6)
        await settle()
        let draggingCalls = await draggingHits.count()
        check(draggingActions == 0 && draggingCalls == 0, "substantial drag cancels the pending first click")
        let missingHits = ScriptedHits([.unavailable, .unavailable, .unavailable, .blank])
        let missing = model(missingHits)
        var missingActions = 0
        missing.onActivate = { _ in missingActions += 1 }
        click(missing, 7); click(missing, 7.2)
        await settle()
        let missingCalls = await missingHits.count()
        check(missingActions == 0 && missingCalls == 3, "persistent failure is bounded and never guessed to be blank")
        click(missing, 8); click(missing, 8.2)
        await settle()
        check(missingActions == 1, "later double-click recovers after a failed attempt")
        let contextHits = ScriptedHits([.blank])
        let context = model(contextHits)
        var contextActions = 0
        context.onActivate = { _ in contextActions += 1 }
        click(context, 9, context: 42); click(context, 9.2, context: 43)
        await settle()
        let contextCalls = await contextHits.count()
        check(contextActions == 0 && contextCalls == 0, "two different foreground applications cannot share a pair")
        click(context, 9.4, context: 43)
        await settle()
        check(contextActions == 1, "new foreground application collects its own pair")

        let delayed = DelayedHit()
        let cancelled = MenuBarActivation(hitTest: { _, _ in await delayed.next() })
        var cancelledActions = 0
        cancelled.onActivate = { _ in cancelledActions += 1 }
        click(cancelled, 10); click(cancelled, 10.2)
        await settle()
        let ready = await delayed.ready()
        check(ready, "validation is actually suspended during simulated AX delay")
        cancelled.reset()
        await delayed.release()
        await settle()
        check(cancelledActions == 0, "window/menu/drag cancellation prevents a delayed validation from reopening the line")
        print("PASS: \(checks) asynchronous double-click activation checks (invented hits only)")
    }
}
