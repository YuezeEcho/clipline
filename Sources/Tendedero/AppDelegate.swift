import AppKit
import Carbon
import Combine
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let line = Line(persistsScreenshots: !ProcessInfo.processInfo.arguments.contains("--demo"),
                            restoresSavedCaptures: false)
    private let isDemo = ProcessInfo.processInfo.arguments.contains("--demo")
    private let clipboard = ClipboardHistory(pasteboard: ProcessInfo.processInfo.arguments.contains("--demo")
                                             ? NSPasteboard.withUniqueName() : .general)
    private let pinnedPhotos = PinnedPhotos(persists: !ProcessInfo.processInfo.arguments.contains("--demo"))
    private var choosingPhoto = false
    private var editingImage = false
    private lazy var imageOpener: SystemImageOpener = {
        let opener = SystemImageOpener()
        opener.onWillOpen = { [weak self] in
            guard let self else { return }
            self.keepOpen = false
            self.setRevealed(false)
            self.resetMenuBarTrigger()
        }
        opener.onEditorVisibilityChanged = { [weak self] visible in
            guard let self else { return }
            self.editingImage = visible
            self.resetMenuBarTrigger()
        }
        opener.onSaved = { [weak self] url in
            guard let self, let locations = self.activeLocations,
                  locations.accepts(url) else { return }
            _ = self.line.hang(url, quietly: true)
        }
        return opener
    }()
    private enum ToolWindow: Hashable { case settings }
    private var openTools = Set<ToolWindow>()
    private var toolScreen: NSScreen?
    private var toolWasRevealed = false
    private var toolPreviousApp: NSRunningApplication?
    private var suspendsLine: Bool { choosingPhoto || editingImage || !openTools.isEmpty }
    private lazy var settings = SettingsController(
        line: line, clipboard: clipboard,
        onSetInbox: { [weak self] in self?.setInbox($0) },
        onSetLogin: { AppDelegate.setLaunchAtLogin($0) },
        onVisibilityChanged: { [weak self] in self?.toolVisibilityChanged(.settings, visible: $0) })
    private var panel: LinePanel!
    private var statusItem: NSStatusItem!
    private var watcher: ScreenshotWatcher!
    private var captureSettingsTimer: Timer?
    private var recordingWatcher: ScreenshotWatcher?
    private var activeLocations: CaptureLocations?
    private var captureFolderGeneration = 0
    private var loadingCaptureFolder = false
    private var pendingCaptures: [URL] = []
    private let captureLoadingQueue = DispatchQueue(label: "Clipline capture covers", qos: .userInitiated)
    private var signalSources: [DispatchSourceSignal] = []
    private var hotKey: HotKey?
    private var clipboardHotKey: HotKey?
    private var cancellables = Set<AnyCancellable>()
    private var mouseTimer: Timer?

    /// Whether the panel is ordered in. It can be in and still tucked away
    /// above the top edge, like an auto-hiding Dock.
    private var isPresent = false
    /// Whether the line has slid down into view.
    private var isRevealed = false
    /// Opened on purpose with the shortcut or the menu: it stays down until
    /// the cursor has visited it and left, or the shortcut is pressed again.
    private var pinned = false
    /// A new screenshot shows itself for a moment, then tucks away.
    private var peekUntil = Date.distantPast
    private let menuBarActivation = MenuBarActivation()
    private var statusMenuIsOpen = false
    private let menuBarClickMonitor = MenuBarClickMonitor()
    private var awaySince: Date?
    /// Set when you open the line on purpose, so it stays up while empty.
    private var keepOpen = false
    private var lastLiveCount = 0
    private var lastScreenshotID: UUID?
    /// The screen a new capture was taken on: the line goes there.
    private var pendingScreen: NSScreen?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = LineHostingView(rootView: LineView(line: line, clipboard: clipboard, pinnedPhotos: pinnedPhotos))
        host.sizingOptions = []
        panel = LinePanel(content: host)
        panel.placeOnScreen()

        if !isDemo {
            if Inbox.isEnabled { Inbox.apply() }
            restoreSettingsOnTermination()
            startWatcher()
            startCaptureSettingsMonitoring()
        }

        hotKey = HotKey(keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey) { [weak self] in
            self?.toggle()
        }
        clipboardHotKey = HotKey(keyCode: kVK_ANSI_V, modifiers: controlKey | optionKey) { [weak self] in
            self?.showClipboard()
        }

        clipboard.onChange = { [weak self] in
            guard let self else { return }
            if self.line.liveCount == 0 && self.pinnedPhotos.photos.isEmpty && !self.clipboard.entries.isEmpty && !self.isRevealed {
                self.line.section = .clipboard
            }
            self.refresh()
        }
        if !isDemo { clipboard.start() }

        line.$section.dropFirst().sink { [weak self] _ in
            // Old card frames must not swallow clicks after switching sections.
            self?.line.hitRects.removeAll()
            self?.line.cardLayoutRects.removeAll()
            self?.clipboard.hitRects.removeAll()
            self?.pinnedPhotos.hitRects.removeAll()
        }.store(in: &cancellables)
        line.canPinPhoto = { [weak self] width in
            guard let self, !self.isDemo else { return false }
            return self.pinnedPhotos.photos.count < PinnedPhotos.capacity(width: width)
        }
        line.onRequestPin = { [weak self] x, width in self?.choosePinnedImage(atX: x, width: width) }
        line.onRequestReplacePin = { [weak self] id in self?.choosePinnedImage(replacing: id) }
        line.onRequestOpen = { [weak self] url in
            guard let self else { return }
            self.imageOpener.open(url, on: self.panel.screen)
        }
        line.onRequestSystemOpen = { [weak self] url in
            self?.imageOpener.openInSystemEditor(url)
        }
        line.onTrashError = { [weak self] url, error in
            guard let self else { return }
            self.setRevealed(false)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = C("Could not move this file to Trash", "无法将文件移到废纸篓", "無法將檔案移到廢紙簍")
            alert.informativeText = url.lastPathComponent + "\n" + error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        pinnedPhotos.onChange = { [weak self] in self?.refresh() }

        setUpStatusItem()
        watchMenuBarClicks()

        line.onFall = { [weak self] item in self?.fall(item) }

        line.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.itemsChanged() }
            .store(in: &cancellables)

        // Reassert the auxiliary panel after an app or Space transition.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                    if self?.isDemo == false {
                        self?.clipboard.poll()
                        Inbox.maintainInstantCapture()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.refresh() }
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel.placeOnScreen()
            }
        }

        if !isDemo && !Inbox.wasOffered {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.offerInbox() }
        }

        if !isDemo && !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            keepOpen = true
            refresh()
            reveal(pinned: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.line.liveCount == 0, self.clipboard.entries.isEmpty, self.pinnedPhotos.photos.isEmpty else { return }
                self.keepOpen = false
                self.setRevealed(false)
            }
        }
        if isDemo {
            seedDemo()
            showClipboard()
        }
        // Menu and double-click activation work before the first capture or copy.
        refresh()
    }

    private func seedDemo() {
        for text in ["Ship a little joy.\n把灵感挂在晾绳上。", "https://example.com/design-notes",
                     "今天的灵感：\n截图和文字，都可以像照片一样随手取用。"] {
            clipboard.record(.text(text), source: "Notes")
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 160,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<160 { for x in 0..<320 {
            bitmap.setColor(NSColor(calibratedHue: 0.46 + Double(x) / 1600,
                                    saturation: 0.5, brightness: 0.95 - Double(y) / 800,
                                    alpha: 1), atX: x, y: y)
        } }
        if let png = bitmap.representation(using: .png, properties: [:]),
           let content = ClipboardHistory.imageContent(png) {
            clipboard.record(content, source: "Preview")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        imageOpener.stop()
        clipboard.stop()
        stopMouseTracking()
        captureSettingsTimer?.invalidate()
        watcher?.stop()
        recordingWatcher?.stop()
        captureFolderGeneration &+= 1
        menuBarClickMonitor.stop()
        menuBarActivation.reset()
        if !isDemo && Inbox.isEnabled { Inbox.restore() }
    }

    // MARK: Inbox mode

    private func startWatcher(animated: Bool = false) {
        watcher?.stop()
        recordingWatcher?.stop()
        recordingWatcher = nil
        let locations = Inbox.locations
        let savedPaths = activeLocations == nil ? line.savedPaths(in: locations) : nil
        activeLocations = locations
        captureFolderGeneration &+= 1
        let generation = captureFolderGeneration
        loadingCaptureFolder = true
        pendingCaptures.removeAll()
        if animated {
            resetMenuBarTrigger()
            setRevealed(false)
            line.section = .screenshots
        }
        line.replaceContents([], saveChanges: false)
        lastLiveCount = 0
        lastScreenshotID = nil
        let sameFolder = locations.screenshots == locations.recordings
        watcher = ScreenshotWatcher(folder: locations.screenshots, kind: sameFolder ? .all : .images,
            onNew: { [weak self] url in self?.enqueueCapture(url) },
            onChange: { [weak self] in self?.screenshotFilesChanged() })
        watcher.start()
        if !sameFolder {
            let recordings = ScreenshotWatcher(folder: locations.recordings, kind: .recordings,
                onNew: { [weak self] url in self?.enqueueCapture(url) },
                onChange: { [weak self] in self?.screenshotFilesChanged() })
            recordings.start()
            recordingWatcher = recordings
        }
        captureLoadingQueue.async { [weak self] in
            let cards = CaptureLibrary.load(locations, savedPaths: savedPaths)
            DispatchQueue.main.async {
                guard let self, self.captureFolderGeneration == generation else { return }
                self.line.replaceContents(cards)
                self.line.rememberFolders(locations)
                self.lastLiveCount = self.line.liveCount
                self.lastScreenshotID = self.line.items.last?.id
                self.loadingCaptureFolder = false
                let pending = self.pendingCaptures
                self.pendingCaptures.removeAll()
                for url in pending { self.enqueueCapture(url) }
                if animated {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in
                        guard let self, self.captureFolderGeneration == generation else { return }
                        self.keepOpen = true
                        self.panel.placeOnScreen()
                        self.refresh()
                        self.reveal(pinned: true)
                    }
                }
            }
        }
    }

    private func enqueueCapture(_ url: URL) {
        guard activeLocations?.accepts(url) == true else { return }
        if loadingCaptureFolder {
            if !pendingCaptures.contains(url) { pendingCaptures.append(url) }
            return
        }
        guard !line.items.contains(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path && !$0.falling }) else { return }
        let generation = captureFolderGeneration
        captureLoadingQueue.async { [weak self] in
            let thumbnail = CaptureMedia.thumbnail(url)
            DispatchQueue.main.async {
                guard let self, let thumbnail, self.captureFolderGeneration == generation,
                      self.activeLocations?.accepts(url) == true else { return }
                self.hangCapture(url, thumbnail: thumbnail)
            }
        }
    }

    private func startCaptureSettingsMonitoring() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Inbox.maintainInstantCapture()
                if Inbox.locations != self.activeLocations {
                    self.startWatcher(animated: true)
                } else if self.watcher?.isRunning == false || self.recordingWatcher?.isRunning == false {
                    self.startWatcher()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        captureSettingsTimer = timer
    }

    private func setInbox(_ on: Bool) {
        guard !isDemo else { return }
        Inbox.isEnabled = on
        if on {
            if !Inbox.apply() {
                let alert = NSAlert()
                alert.messageText = C("Could not enable instant screenshots.", "无法开启即时截图。", "無法開啟即時截圖。")
                alert.informativeText = C("Check access to the selected folders and try again.", "请检查当前保存目录的访问权限后重试。", "請檢查目前儲存目錄的存取權限後重試。")
                alert.runModal()
            }
        } else {
            Inbox.restore()
        }
        if Inbox.locations != activeLocations {
            startWatcher(animated: true)
        } else if watcher?.isRunning == false {
            startWatcher()
        }
    }

    private func screenshotFilesChanged() {
        line.prune()
        line.refreshChangedThumbnails()
    }

    /// Asked once. Changing system settings is the user's call, never ours.
    private func offerInbox() {
        Inbox.wasOffered = true
        let alert = NSAlert()
        alert.messageText = L("Let Clipline handle your screenshots?",
                              "¿Quieres que Clipline se encargue de tus capturas?")
        alert.informativeText = L(
            "The system floating thumbnail will be turned off so captures reach the line without waiting. Save locations remain yours to choose; the line follows changes in Screenshot Options. Turning this off or quitting restores your previous thumbnail setting.",
            "Se desactivará la miniatura flotante para colgar las capturas sin esperar. El tendedero sigue la ubicación elegida en Opciones de Captura. Al desactivarlo o salir se restaura el ajuste anterior de la miniatura.")
        alert.addButton(withTitle: L("Turn on", "Activar"))
        alert.addButton(withTitle: L("Not now", "Ahora no"))
        if let icon = NSImage(named: "Clipline") ?? NSApp.applicationIconImage { alert.icon = icon }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { setInbox(true) }
    }

    /// Quitting from the menu or logging out runs applicationWillTerminate.
    /// A plain kill does not, so settings are also restored on those signals.
    private func restoreSettingsOnTermination() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                if Inbox.isEnabled { Inbox.restore() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Showing and hiding

    /// The settings window receives focus without the status-level clothesline
    /// covering it. Reopening the same window must restore it only once.
    private func toolVisibilityChanged(_ tool: ToolWindow, visible: Bool) {
        if visible {
            resetMenuBarTrigger()
            guard openTools.insert(tool).inserted else { return }
            line.beginInteraction()
            if openTools.count == 1 {
                toolScreen = panel.screen
                toolWasRevealed = isRevealed
                toolPreviousApp = NSWorkspace.shared.frontmostApplication
                setRevealed(false)
                panel.orderOut(nil)
            }
        } else {
            guard openTools.remove(tool) != nil else { return }
            line.endInteraction()
            guard openTools.isEmpty else { return }
            let screen = NSScreen.screens.first { $0.frame == toolScreen?.frame } ?? LinePanel.screenUnderPointer()
            panel.placeOnScreen(screen)
            refresh()
            if toolWasRevealed { reveal(pinned: true) }
            panel.orderFrontRegardless()
            if toolPreviousApp?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                toolPreviousApp?.activate(options: [])
            }
            toolScreen = nil
            toolPreviousApp = nil
        }
    }

    /// Hide the nonactivating status-level strip while a normal file panel is
    /// open, then put it back on the screen where the position was selected.
    private func choosePinnedImage(atX x: CGFloat = 0, width: CGFloat = 0, replacing id: UUID? = nil) {
        guard !isDemo, !suspendsLine else { return }
        choosingPhoto = true
        line.beginInteraction()
        let originalScreen = panel.screen
        let wasRevealed = isRevealed
        let previousApp = NSWorkspace.shared.frontmostApplication
        panel.orderOut(nil)
        defer {
            choosingPhoto = false
            line.endInteraction()
            let screen = NSScreen.screens.first { $0.frame == originalScreen?.frame } ?? LinePanel.screenUnderPointer()
            panel.placeOnScreen(screen)
            refresh()
            if wasRevealed { reveal(pinned: true) }
            panel.orderFrontRegardless()
            if previousApp?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previousApp?.activate(options: [])
            }
        }
        let picker = NSOpenPanel()
        picker.title = C("Choose a pinned photo", "选择要固定的图片")
        picker.prompt = C("Pin image", "固定图片")
        picker.allowedContentTypes = [.image]
        picker.allowsMultipleSelection = false
        picker.canChooseDirectories = false
        picker.canChooseFiles = true
        NSApp.activate(ignoringOtherApps: true)
        guard picker.runModal() == .OK, let url = picker.url else { return }
        let succeeded: Bool
        if let id { succeeded = pinnedPhotos.replace(id, from: url) }
        else { succeeded = pinnedPhotos.pin(from: url, atX: x, width: width) != nil }
        if !succeeded {
            let alert = NSAlert()
            alert.messageText = C("Could not pin this image", "无法固定这张图片")
            alert.informativeText = C("Choose a readable image file, such as PNG, JPEG or HEIC. The screen's pin limit may also have been reached.",
                                     "请选择可读取的图片文件，例如 PNG、JPEG 或 HEIC；当前屏幕的固定数量也可能已达上限。")
            alert.runModal()
        }
    }

    private func itemsChanged() {
        let live = line.liveCount
        let newestID = line.items.last(where: { !$0.falling })?.id
        if live > lastLiveCount || (live == lastLiveCount && newestID != lastScreenshotID) {
            panel.placeOnScreen(pendingScreen)
            pendingScreen = nil
            refresh()
            reveal(peekFor: 2.5)
        } else if live == 0 && clipboard.entries.isEmpty && pinnedPhotos.photos.isEmpty && !keepOpen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, self.line.liveCount == 0, self.clipboard.entries.isEmpty, self.pinnedPhotos.photos.isEmpty, !self.keepOpen else { return }
                self.setRevealed(false)
            }
        }
        lastLiveCount = live
        lastScreenshotID = newestID
    }

    // MARK: The capture flying to the line

    /// A new screenshot lifts off from where it was taken and flies to its
    /// place on the line. Without a known capture area it simply drops in.
    private func hangCapture(_ url: URL, thumbnail: NSImage) {
        let switchedSection = line.section != .screenshots
        line.section = .screenshots
        let from = CaptureMedia.isVideo(url) ? nil : captureRect(of: url)
        if let from {
            let center = CGPoint(x: from.midX, y: from.midY)
            pendingScreen = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
        }
        guard let id = line.hang(url, flying: from != nil, thumbnail: thumbnail), let from else { return }
        // Let the line come down and lay out before measuring the landing spot.
        DispatchQueue.main.asyncAfter(deadline: .now() + (switchedSection ? 0.55 : 0.08)) { [weak self] in
            self?.fly(id, from: from, deadline: ProcessInfo.processInfo.systemUptime + 1)
        }
    }

    private func fly(_ id: UUID, from: CGRect, deadline: TimeInterval) {
        guard !suspendsLine, isPresent, isRevealed, let screen = panel.screen,
              let item = line.items.first(where: { $0.id == id }), !item.falling,
              line.items.last(where: { !$0.falling })?.id == id else {
            line.land(id)
            return
        }
        guard !panel.slideView.isAnimating, let rect = line.cardLayoutRects[id],
              rect.minX >= line.interactionRect.minX,
              rect.maxX <= line.interactionRect.maxX,
              let to = cardFrame(for: id) else {
            if ProcessInfo.processInfo.systemUptime < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
                    self?.fly(id, from: from, deadline: deadline)
                }
            } else { line.land(id) }
            return
        }
        let pixels = Int(max(from.width, from.height) * screen.backingScaleFactor)
        guard let image = makeThumbnail(item.url, maxPixels: min(3000, max(400, pixels)))?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            line.land(id)
            return
        }
        CaptureFlight.fly(image: image, from: from, to: to, tilt: CGFloat(item.tilt), on: screen) { [weak self] in
            self?.line.land(id)
        }
    }

    /// A discarded card falls over the whole screen, from where it hangs.
    private func fall(_ item: Pegged) {
        guard !panel.slideView.isAnimating, !suspendsLine, line.section == .screenshots, isPresent, isRevealed, !item.flying, let screen = panel.screen,
              let card = cardFrame(for: item.id),
              let image = item.thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        CaptureFlight.fall(image: image, card: card, tilt: CGFloat(item.tilt), on: screen)
    }

    /// Use the displayed card's actual position after horizontal scrolling.
    private func cardFrame(for id: UUID) -> CGRect? {
        guard let rect = line.cardLayoutRects[id], rect.intersects(line.interactionRect) else { return nil }
        return CGRect(x: panel.frame.minX + rect.minX,
                      y: panel.frame.maxY - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    /// Keep the hidden panel available, including with no items.
    private func refresh() {
        guard !suspendsLine else { return }
        present()
        if isRevealed { panel.orderFrontRegardless() }
        startMouseTracking()
    }

    private func present() {
        guard !isPresent else { return }
        isPresent = true
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func reveal(pinned: Bool = false, peekFor seconds: TimeInterval = 0) {
        guard !suspendsLine, isPresent else { return }
        if pinned { self.pinned = true }
        if seconds > 0 { peekUntil = Date().addingTimeInterval(seconds) }
        awaySince = nil
        setRevealed(true)
    }

    private func setRevealed(_ on: Bool) {
        guard on != isRevealed else { return }
        if on { line.refreshChangedThumbnails() }
        isRevealed = on
        line.revealed = on
        if !on {
            pinned = false
            peekUntil = .distantPast
            panel.ignoresMouseEvents = true
        } else {
            updateMousePassThrough(NSEvent.mouseLocation)
        }
    }

    @objc private func toggle() {
        resetMenuBarTrigger()
        guard !suspendsLine else { return }
        if isRevealed {
            setRevealed(false)
            if line.liveCount == 0 && clipboard.entries.isEmpty && pinnedPhotos.photos.isEmpty {
                keepOpen = false
                refresh()
            }
        } else {
            keepOpen = true
            panel.placeOnScreen()
            refresh()
            reveal(pinned: true)
        }
    }

    private func showClipboard() {
        resetMenuBarTrigger()
        guard !suspendsLine else { return }
        if !isDemo { clipboard.poll() }
        if isRevealed && line.section == .clipboard {
            toggle()
            return
        }
        line.section = .clipboard
        keepOpen = true
        panel.placeOnScreen()
        refresh()
        reveal(pinned: true)
    }

    private func showScreenshots() {
        resetMenuBarTrigger()
        guard !suspendsLine else { return }
        line.section = .screenshots
        keepOpen = true
        panel.placeOnScreen()
        refresh()
        reveal(pinned: true)
    }

    private func startMouseTracking() {
        guard mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func stopMouseTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        panel.ignoresMouseEvents = true
    }

    /// The menu bar strip at the top of a screen. With an auto-hiding menu
    /// bar the visible frame reaches the top, so the system thickness is used.
    static func menuBarBand(of screen: NSScreen) -> NSRect {
        TopEdgeTrigger.menuBarBand(frame: screen.frame, height: LinePanel.topInset(on: screen))
    }

    private func resetMenuBarTrigger() {
        menuBarActivation.reset()
    }

    private func watchMenuBarClicks() {
        menuBarActivation.onActivate = { [weak self] pair in
            guard let self, !self.suspendsLine, !self.statusMenuIsOpen,
                  MenuBarHitTest.isAuthorized,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pair.context,
                  let screen = NSScreen.screens.first(where: { $0.frame == pair.screen }) else { return }
            if pair.reveal {
                self.keepOpen = true
                self.panel.placeOnScreen(screen)
                self.refresh()
                self.reveal(pinned: true)
            } else {
                self.setRevealed(false)
            }
        }
        menuBarClickMonitor.onClick = { [weak self] click in self?.handleMenuBarClick(click) }
        menuBarClickMonitor.start()
    }

    private func handleMenuBarClick(_ event: MenuBarClickMonitor.Click) {
        guard !suspendsLine, !statusMenuIsOpen else { resetMenuBarTrigger(); return }
        // Use the event's position, not a later sample of a moving pointer.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let point = CGPoint(x: event.point.x, y: primaryTop - event.point.y)
        guard let screen = NSScreen.screens.first(where: {
            TopEdgeTrigger.contains(point, in: Self.menuBarBand(of: $0))
        }) else { resetMenuBarTrigger(); return }
        if event.type == .leftMouseDragged {
            menuBarActivation.drag(point: point, screen: screen.frame)
            return
        }
        guard event.type == .leftMouseDown, !event.hasModifiers,
              MenuBarHitTest.isAuthorized else { resetMenuBarTrigger(); return }
        menuBarActivation.click(point: point, screen: screen.frame, time: event.time,
                                interval: MenuBarDoubleClickTrigger.effectiveInterval(system: NSEvent.doubleClickInterval),
                                context: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
                                wasRevealed: isRevealed, primaryTop: primaryTop)
    }
    /// How long the cursor is away before the line tucks back up.
    private static let retractDelay: TimeInterval = 0.5

    private func tick() {
        guard !suspendsLine else { return }
        let mouse = NSEvent.mouseLocation
        let now = Date()

        // Merely touching or hovering at the top no longer reveals the line.
        guard isRevealed else { return }

        updateMousePassThrough(mouse)

        // The line's zone runs from its lowest point up to the top of the
        // screen, menu bar included, so moving up never hides it.
        var zone = panel.frame
        if let screen = panel.screen { zone.size.height = screen.frame.maxY - zone.minY }
        let inside = TopEdgeTrigger.contains(mouse, in: zone)
        if inside && pinned { pinned = false }

        let busy = pinned || GrabView.isDragging || line.pressedID != nil || line.interactionDepth > 0 || statusMenuIsOpen || now < peekUntil
        if inside || busy {
            awaySince = nil
        } else {
            let since = awaySince ?? now
            awaySince = since
            if now.timeIntervalSince(since) >= Self.retractDelay {
                awaySince = nil
                setRevealed(false)
            }
        }
    }

    /// The visible scroll row also accepts events between cards, so a
    /// horizontal gesture doesn't break when the pointer crosses a gap.
    private func updateMousePassThrough(_ mouse: NSPoint) {
        if panel.slideView.isAnimating {
            panel.ignoresMouseEvents = true
            return
        }
        guard !GrabView.isDragging, pinnedPhotos.draggingID == nil else { return }
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        let viewport = line.section == .screenshots ? line.interactionRect : clipboard.interactionRect
        let overPin = line.section == .screenshots && pinnedPhotos.hitRects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(flipped) }
        let interactive = overPin || viewport.contains(flipped) || (line.showsControls && line.controlsRect.contains(flipped))
        if panel.ignoresMouseEvents == interactive {
            panel.ignoresMouseEvents = !interactive
        }
    }

    // MARK: Menu bar

    func menuWillOpen(_ menu: NSMenu) {
        statusMenuIsOpen = true
        guard !suspendsLine else { return }
        resetMenuBarTrigger()
        setRevealed(false)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusMenuIsOpen = false
        resetMenuBarTrigger()
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = CliplineIcon.menuBarImage()
        statusItem.button?.image = image
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggleItem = ClosureMenuItem(isRevealed ? L("Hide line", "Ocultar tendedero")
                                                 : L("Show line", "Mostrar tendedero")) { [weak self] in
            self?.toggle()
        }
        toggleItem.keyEquivalent = "t"
        toggleItem.keyEquivalentModifierMask = [.control, .option]
        toggleItem.isEnabled = !suspendsLine
        menu.addItem(toggleItem)

        if !line.showsControls {
            let screenshots = ClosureMenuItem(C("Captures", "截图与录屏", "截圖與錄影")) { [weak self] in self?.showScreenshots() }
            screenshots.isEnabled = !suspendsLine
            menu.addItem(screenshots)
        }

        let historyItem = ClosureMenuItem(C("Clipboard history", "剪贴板历史")) { [weak self] in
            self?.showClipboard()
        }
        historyItem.keyEquivalent = "v"
        historyItem.keyEquivalentModifierMask = [.control, .option]
        historyItem.isEnabled = !suspendsLine
        menu.addItem(historyItem)

        let tracking = ClosureMenuItem(clipboard.isTracking ? C("Pause clipboard recording", "暂停剪贴板记录")
                                      : C("Resume clipboard recording", "继续剪贴板记录")) { [weak self] in
            guard let self else { return }
            self.clipboard.setTracking(!self.clipboard.isTracking)
        }
        menu.addItem(tracking)
        let controls = ClosureMenuItem(C("Show section controls", "显示切换栏")) { [weak self] in
            self?.line.showsControls.toggle()
        }
        controls.state = line.showsControls ? .on : .off
        menu.addItem(controls)
        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(L("Open screenshots folder", "Abrir carpeta de capturas")) { [weak self] in
            guard let self, let watcher = self.watcher else { return }
            NSWorkspace.shared.open(watcher.folder)
        })
        menu.addItem(ClosureMenuItem(C("Settings…", "设置…", "設定…"), key: ",") { [weak self] in
            self?.settings.show()
        })

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Quit Clipline", "Salir de Clipline"), key: "q") {
            NSApp.terminate(nil)
        })
    }

    private static func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled, SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            } else if !enabled, SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Could not change the login setting", "No se pudo cambiar el inicio de sesión")
            alert.informativeText = L("Move Clipline to the Applications folder and try again.",
                                      "Mueve Clipline a la carpeta Aplicaciones y vuelve a intentarlo.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
