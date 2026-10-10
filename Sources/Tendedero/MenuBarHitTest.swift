import AppKit
import ApplicationServices

/// Inspect roles, actions and ancestry only; never menu titles or contents.
/// Inert containers are blank only when they belong to an actual menu bar.
enum MenuBarHitTest {
    static var isAuthorized: Bool { AXIsProcessTrusted() }

    enum Result: Equatable, Sendable { case blank, occupied, unavailable }

    struct Node {
        let role: String?
        let hasActions: Bool
    }

    static func classify(_ ancestry: [Node]) -> Result {
        for node in ancestry {
            guard let role = node.role else { return .unavailable }
            if role == (kAXMenuBarRole as String) { return .blank }
            if node.hasActions { return .occupied }
            guard isContainer(role) else {
                return isWindowContainer(role) ? .unavailable : .occupied
            }
        }
        return .unavailable
    }

    static func isBlank(_ ancestry: [Node]) -> Bool { classify(ancestry) == .blank }

    static func classify(at point: CGPoint, primaryTop: CGFloat) -> Result {
        guard isAuthorized else { return .unavailable }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.12)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x),
                                               Float(primaryTop - point.y), &element) == .success,
              var current = element else { return .unavailable }
        var ancestry: [Node] = []
        let deadline = ProcessInfo.processInfo.systemUptime + 0.4
        for _ in 0..<6 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return .unavailable }
            AXUIElementSetMessagingTimeout(current, 0.12)
            var roleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &roleValue) == .success,
                  let role = roleValue as? String else { return .unavailable }
            if role == (kAXMenuBarRole as String) {
                ancestry.append(Node(role: role, hasActions: false))
                return classify(ancestry)
            }
            // A foreground app may temporarily return a window/application
            // during a menu-bar rebuild. Retry, but never accept it as blank.
            if isWindowContainer(role) { return .unavailable }
            guard isContainer(role) else { return .occupied }
            var actions: CFArray?
            let result = AXUIElementCopyActionNames(current, &actions)
            guard result == .success || result == .actionUnsupported else { return .unavailable }
            let hasActions = actions.map { CFArrayGetCount($0) > 0 } ?? false
            ancestry.append(Node(role: role, hasActions: hasActions))
            if hasActions { return .occupied }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID(),
                  !CFEqual(parent, current) else { return .unavailable }
            current = unsafeBitCast(parent, to: AXUIElement.self)
        }
        return .unavailable
    }

    private static func isWindowContainer(_ role: String) -> Bool {
        role == (kAXApplicationRole as String) || role == (kAXWindowRole as String)
            || role == "AXWebArea" || role == (kAXScrollAreaRole as String)
    }

    private static func isContainer(_ role: String) -> Bool {
        role == (kAXGroupRole as String) || role == (kAXUnknownRole as String)
    }
}
