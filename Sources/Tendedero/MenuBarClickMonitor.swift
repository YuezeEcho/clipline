import AppKit
import ApplicationServices

/// Observe mouse events before AppKit dispatch: an empty system menu bar need
/// not send an NSEvent to any application. This tap never consumes an event.
@MainActor
final class MenuBarClickMonitor {
    struct Click {
        let point: CGPoint // Quartz coordinates, origin at the primary top-left.
        let type: CGEventType
        let time: TimeInterval
        let hasModifiers: Bool
    }
    private(set) static var isListening = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    var onClick: ((Click) -> Void)?

    func start() {
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        stopTap()
    }

    private func stopTap() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        Self.isListening = false
    }

    private func refresh() {
        guard MenuBarHitTest.isAuthorized else { stopTap(); return }
        if let tap {
            if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
            Self.isListening = CGEvent.tapIsEnabled(tap: tap)
            return
        }
        let types: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .listenOnly, eventsOfInterest: mask,
                                        callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            MainActor.assumeIsolated {
                let monitor = Unmanaged<MenuBarClickMonitor>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    monitor.refresh()
                } else {
                    monitor.onClick?(MenuBarClickMonitor.click(from: event, type: type))
                }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Self.isListening = CGEvent.tapIsEnabled(tap: tap)
    }

    static func click(from event: CGEvent, type: CGEventType) -> Click {
        Click(point: event.location, type: type, time: Double(event.timestamp) / 1_000_000_000,
              hasModifiers: !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty)
    }
}
