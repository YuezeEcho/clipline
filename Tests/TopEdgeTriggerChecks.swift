import Foundation
import CoreGraphics
import AppKit

@main struct TopEdgeTriggerChecks {
    @MainActor static func main() {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            guard value else { fatalError("FAIL: " + message) }; checks += 1
        }
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let point = CGPoint(x: 600, y: 885)
        var trigger = MenuBarDoubleClickTrigger()
        func click(_ t: Double, _ blank: Bool = true, _ shown: Bool = false,
                   _ p: CGPoint? = nil, _ f: CGRect? = nil, _ interval: Double = 0.5) -> Bool? {
            guard blank else { trigger.reset(); return nil }
            return trigger.click(point: p ?? point, screen: f ?? frame, time: t,
                                 interval: interval, context: 42, wasRevealed: shown)?.reveal
        }
        check(TopEdgeTrigger.contains(CGPoint(x: 1440, y: 900), in: frame), "physical boundary included")
        let band = TopEdgeTrigger.menuBarBand(frame: frame, height: 32)
        check(band == CGRect(x: 0, y: 868, width: 1440, height: 32), "menu-bar/notch height reserved")
        check(!TopEdgeTrigger.contains(CGPoint(x: 600, y: 867), in: band), "browser tabs excluded")
        check(click(1) == nil && click(1.2) == true, "single click waits, double click opens immediately")
        check(click(1.3) == nil, "triple click does not open again")
        trigger.reset()
        check(click(2, true, true) == nil && click(2.2) == false, "double click closes line despite first-click retraction")
        check(click(3) == nil && click(3.6) == nil && click(3.8) == true, "slow clicks start a fresh pair")
        check(click(4, true, false, nil, nil, 0.8) == nil && click(4.7, true, false, nil, nil, 0.8) == true, "system double-click interval honored")
        check(click(5, false) == nil && click(5.2, false) == nil, "interactive menu items never trigger")
        check(click(6) == nil && click(6.1, false) == nil && click(6.2) == nil, "nonblank hit cancels pending pair")
        trigger.reset()
        check(click(7) == nil && click(7.2, true, false, CGPoint(x: 611, y: 885)) == nil, "far-apart blank clicks excluded")
        trigger.reset()
        check(click(8) == nil && click(8.2, true, false, CGPoint(x: 603, y: 889)) == true, "small pointer movement allowed")
        check(click(9) == nil && click(9.2, true, false, nil, CGRect(x: -1920, y: -200, width: 1920, height: 1080)) == nil, "display changes cancel pair")
        trigger.reset(); check(click(10) == nil, "pending first click")
        trigger.reset(); check(click(10.2) == nil, "drag or menu opening resets pair")
        check(click(9.9) == nil, "out-of-order event excluded")
        trigger.reset(); check(click(20) == nil && click(20.5) == true, "interval boundary included")
        trigger.reset(); check(click(21) == nil && click(21.501) == nil, "beyond interval excluded")
        func node(_ role: String?, _ actions: Bool = false) -> MenuBarHitTest.Node {
            MenuBarHitTest.Node(role: role, hasActions: actions)
        }
        let bar = node("AXMenuBar")
        check(MenuBarHitTest.isBlank([bar]), "background role accepted")
        check(MenuBarHitTest.isBlank([node("AXGroup"), bar]), "inert group on menu bar accepted")
        check(MenuBarHitTest.isBlank([node("AXUnknown"), node("AXGroup"), bar]), "nested blank containers accepted")
        for role in [nil, "AXMenuBarItem", "AXButton", "AXWindow", "AXWebArea", "AXMenuItem", "AXImage", "AXStaticText"] as [String?] {
            check(!MenuBarHitTest.isBlank([node(role), bar]), "interactive or unrelated descendants excluded")
        }
        check(!MenuBarHitTest.isBlank([node("AXGroup", true), bar]), "clickable status container excluded")
        check(!MenuBarHitTest.isBlank([node("AXUnknown", true), bar]), "unknown clickable item excluded")
        check(!MenuBarHitTest.isBlank([node("AXGroup")]), "group without menu-bar ancestor excluded")
        check(!MenuBarHitTest.isBlank([node("AXUnknown"), node("AXWindow")]), "fullscreen browser title bar excluded")
        check(!MenuBarHitTest.isBlank([]), "failed hits never count as blank")
        check(!MenuBarHitTest.isBlank([node("AXButton"), node("AXGroup"), bar]), "menu ancestry never legitimizes a button")
        // Construct local events only: never post input or inspect another app.
        let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                            mouseCursorPosition: CGPoint(x: 650, y: 12), mouseButton: .left)!
        event.timestamp = 40_250_000_000
        let click = MenuBarClickMonitor.click(from: event, type: .leftMouseDown)
        check(click.point == CGPoint(x: 650, y: 12) && click.type == .leftMouseDown,
              "raw system mouse location and event type preserved")
        check(click.time == 40.25, "Quartz timestamp uses seconds for double-click timing")
        check(!click.hasModifiers, "plain mouse click has no modifiers")
        for flag in [CGEventFlags.maskCommand, .maskControl, .maskAlternate, .maskShift] {
            event.flags = flag
            check(MenuBarClickMonitor.click(from: event, type: .leftMouseDown).hasModifiers,
                  "modified clicks do not activate")
        }
        event.flags = .maskAlphaShift
        check(!MenuBarClickMonitor.click(from: event, type: .leftMouseDown).hasModifiers,
              "Caps Lock does not block double-click activation")
        check(MenuBarDoubleClickTrigger.effectiveInterval(system: 0.2) == 0.7, "fast system setting still allows a comfortable pair")
        check(MenuBarDoubleClickTrigger.effectiveInterval(system: 0.8) == 0.8, "slower accessibility setting is preserved")
        check(MenuBarDoubleClickTrigger.effectiveInterval(system: .nan) == 0.7, "invalid interval falls back safely")
        check(MenuBarHitTest.classify([node(nil)]) == .unavailable, "query failure remains distinct from an interactive item")
        check(MenuBarHitTest.classify([node("AXWindow")]) == .unavailable, "menu-bar rebuilding permits a retry")
        check(MenuBarHitTest.classify([node("AXWebArea")]) == .unavailable, "web content beneath a revealing menu bar is retried, never accepted")
        check(MenuBarHitTest.classify([node("AXMenuBarItem")]) == .occupied, "actual menu item never retries into blank")
        print("PASS: \(checks) menu-bar double-click checks (no external UI accessed)")
    }
}
