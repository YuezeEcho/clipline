import AppKit
import ApplicationServices

/// Images use our own panel; recordings keep their normal external player.
@MainActor
final class SystemImageOpener {
    let editor = ImageEditorController()
    var onWillOpen: (() -> Void)?
    var onEditorVisibilityChanged: ((Bool) -> Void)? {
        get { editor.onVisibilityChanged }
        set { editor.onVisibilityChanged = newValue }
    }
    var onSaved: ((URL) -> Void)? {
        get { editor.onSaved }
        set { editor.onSaved = newValue }
    }
    static func requestWindowPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    func open(_ url: URL, on screen: NSScreen?) {
        onWillOpen?()
        if CaptureMedia.isVideo(url) { NSWorkspace.shared.open(url) }
        else { editor.open(url, on: screen) }
    }
    func openInSystemEditor(_ url: URL) {
        onWillOpen?()
        Self.openInPreview(url)
    }
    /// An explicit alternative: always use macOS Preview, even when another app
    /// is registered as the default image viewer. Leave its window management to macOS.
    static func openInPreview(_ url: URL) {
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
            NSSound.beep()
            log.error("Preview is unavailable")
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: application,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                log.error("Could not open image in Preview: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async { NSSound.beep() }
            }
        }
    }
    func stop() { editor.stop() }
}

enum EditorWindowLayout {
    static func frame(in visible: CGRect) -> CGRect {
        let width = floor(min(860, max(600, visible.width * 0.60), max(1, visible.width - 40)))
        let height = floor(min(640, max(400, visible.height * 0.70), max(1, visible.height - 40)))
        return CGRect(x: floor(visible.midX - width / 2), y: floor(visible.midY - height / 2),
                      width: width, height: height)
    }

}
