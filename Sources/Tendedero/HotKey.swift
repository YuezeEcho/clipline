import Carbon

/// Each shortcut owns its callback and event handler; multiple keys can coexist.
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let keyID: UInt32
    private let action: () -> Void
    private static let signature = OSType(0x434C_4950) // "CLIP"

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.keyID = UInt32(keyCode)
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr else {
                return OSStatus(eventNotHandledErr)
            }
            return MainActor.assumeIsolated {
                let shortcut = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
                guard id.signature == HotKey.signature, id.id == shortcut.keyID else {
                    return OSStatus(eventNotHandledErr)
                }
                DispatchQueue.main.async { shortcut.action() }
                return noErr
            }
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return }
        let id = EventHotKeyID(signature: Self.signature, id: keyID)
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let handler { RemoveEventHandler(handler) }
        if let ref { UnregisterEventHotKey(ref) }
    }
}
