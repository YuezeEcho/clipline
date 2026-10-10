import AppKit
import ServiceManagement
import SwiftUI

/// A regular window keeps longer preferences out of the menu-bar menu.
@MainActor
final class SettingsController: NSObject, NSWindowDelegate {
    private let line: Line
    private let clipboard: ClipboardHistory
    private let onSetInbox: (Bool) -> Void
    private let onSetLogin: (Bool) -> Void
    private let onVisibilityChanged: (Bool) -> Void
    private var window: NSWindow?
    private var languageObservation: NSObjectProtocol?
    private var announcedVisible = false
    private lazy var preferences = SettingsPreferences(line: line)

    init(line: Line, clipboard: ClipboardHistory,
         onSetInbox: @escaping (Bool) -> Void,
         onSetLogin: @escaping (Bool) -> Void,
         onVisibilityChanged: @escaping (Bool) -> Void) {
        self.line = line
        self.clipboard = clipboard
        self.onSetInbox = onSetInbox
        self.onSetLogin = onSetLogin
        self.onVisibilityChanged = onVisibilityChanged
        super.init()
        languageObservation = NotificationCenter.default.addObserver(
            forName: AppLanguage.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTitle() }
        }
    }

    func show() {
        preferences.refresh()
        if window == nil {
            let view = SettingsView(line: line, clipboard: clipboard,
                                    preferences: preferences,
                                    language: AppLanguage.shared,
                                    onSetInbox: onSetInbox, onSetLogin: onSetLogin)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 720),
                                  styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.delegate = self
            window.center()
            self.window = window
            updateTitle()
        }
        guard let window else { return }
        if !announcedVisible {
            announcedVisible = true
            onVisibilityChanged(true)
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard announcedVisible else { return }
        announcedVisible = false
        onVisibilityChanged(false)
    }

    private func updateTitle() {
        window?.title = C("Clipline Settings", "Clipline 设置", "Clipline 設定")
    }

    deinit {
        if let languageObservation {
            NotificationCenter.default.removeObserver(languageObservation)
        }
    }
}

@MainActor
final class SettingsPreferences: ObservableObject {
    @Published var inboxEnabled = false
    @Published var captureState: Inbox.CaptureState = .off
    @Published var captureLocations = CaptureLocations(screenshots: nil, recordings: nil)
    @Published var soundEnabled = true
    @Published var loginEnabled = false
    @Published var accessibilityGranted = false
    @Published var menuBarListening = false
    let runningApplicationURL: URL
    private let line: Line
    private let permissionCheck: () -> Bool
    private let listeningCheck: @MainActor () -> Bool

    init(line: Line, permissionCheck: @escaping () -> Bool = { MenuBarHitTest.isAuthorized },
         listeningCheck: @escaping @MainActor () -> Bool = { MenuBarClickMonitor.isListening },
         runningApplicationURL: URL = Bundle.main.bundleURL) {
        self.line = line
        self.runningApplicationURL = runningApplicationURL
        self.permissionCheck = permissionCheck
        self.listeningCheck = listeningCheck
    }

    func refreshAccessibility() {
        let granted = permissionCheck()
        if accessibilityGranted != granted { accessibilityGranted = granted }
        let listening = granted && listeningCheck()
        if menuBarListening != listening { menuBarListening = listening }
    }

    func refresh() {
        refreshAccessibility()
        inboxEnabled = Inbox.isEnabled
        refreshCaptureState()
        soundEnabled = line.soundOn
        loginEnabled = SMAppService.mainApp.status == .enabled
    }

    func refreshCaptureState() {
        let locations = Inbox.locations
        if locations != captureLocations { captureLocations = locations }
        let state = Inbox.captureState
        if captureState != state { captureState = state }
    }
}

@MainActor
struct SettingsView: View {
    @ObservedObject var line: Line
    @ObservedObject var clipboard: ClipboardHistory
    @ObservedObject var preferences: SettingsPreferences
    @ObservedObject var language: AppLanguage
    let onSetInbox: (Bool) -> Void
    let onSetLogin: (Bool) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(C("Settings", "设置", "設定"))
                    .font(.title2.weight(.semibold))
                Text(C("Make the clothesline feel at home.", "按你的习惯使用晾绳。", "依你的習慣使用曬衣繩。"))
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Picker(C("Language", "语言", "語言"), selection: $language.selected) {
                        ForEach(AppLanguageChoice.allCases) { choice in
                            Text(choice.nativeName).tag(choice)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(C("Language changes take effect immediately.", "切换语言立即生效。", "切換語言立即生效。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label(C("Language", "语言", "語言"), systemImage: "globe")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(C("Handle screenshots", "接管系统截图", "接管系統截圖"), isOn: Binding(
                        get: { preferences.inboxEnabled },
                        set: { enabled in
                            onSetInbox(enabled)
                            preferences.refresh()
                        }))
                    Text(captureStatus)
                        .font(.caption)
                        .foregroundStyle(preferences.captureState == .ready ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup(C("Screenshot and recording folder", "截图与录屏保存位置", "截圖與錄影儲存位置")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(preferences.captureLocations.screenshots.path)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            if preferences.captureLocations.recordings != preferences.captureLocations.screenshots {
                                Text(preferences.captureLocations.recordings.path)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                            Text(C("Change Save to in macOS Screenshot Options. The line follows that folder; pinned photos stay in place.",
                                   "在 macOS 截屏选项中修改保存位置，晾绳会跟随目录；固定图片保持不变。",
                                   "在 macOS 截圖選項中修改儲存位置，曬衣繩會跟隨目錄；固定圖片保持不變。"))
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(C("Restore default folder and instant screenshots", "恢复默认位置并开启即时截图", "恢復預設位置並開啟即時截圖")) {
                                _ = Inbox.apply(resetLocation: true)
                                onSetInbox(true)
                                preferences.refresh()
                            }
                        }
                        .padding(.top, 6)
                    }
                    Text(C("Double-click empty menu-bar space to show or hide the line.",
                           "双击菜单栏空白处，展开或收起晾绳。",
                           "按兩下選單列空白處，展開或收起曬衣繩。"))
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(C("Double-click tolerance is at least 0.7 seconds; a slower system setting is respected.",
                           "两次点击间隔可达 0.7 秒；系统设得更慢时也会跟随。",
                           "兩次點擊間隔可達 0.7 秒；系統設得更慢時也會跟隨。"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text(preferences.accessibilityGranted
                             ? C("Accessibility permission granted.", "辅助功能权限已生效。", "輔助使用權限已生效。")
                             : C("This copy of Clipline needs Accessibility permission.", "当前运行的 Clipline 尚未获得辅助功能权限。", "目前執行的 Clipline 尚未取得輔助使用權限。"))
                            .font(.caption)
                            .foregroundStyle(preferences.accessibilityGranted ? Color.green : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button(C("Open settings…", "打开设置…", "開啟設定…")) {
                            if !preferences.accessibilityGranted { SystemImageOpener.requestWindowPermission() }
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    DisclosureGroup(C("Authorize the running app", "确认授权的是当前应用", "確認授權的是目前應用程式")) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(C("Add this app with + in Accessibility settings. An older copy's permission may not apply.",
                                   "在辅助功能设置中用 + 添加下面这个应用。旧版应用的授权可能不适用于当前版本。",
                                   "在輔助使用設定中用 + 加入下面這個應用程式。舊版的授權可能不適用於目前版本。"))
                                .font(.caption)
                            Text(C("This is the app location on this Mac; other Macs may use a different location.",
                                   "以下是本机当前应用的位置，每个人的安装位置可能不同。",
                                   "以下是此 Mac 目前應用程式的位置，每個人的安裝位置可能不同。"))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(preferences.runningApplicationURL.path)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(C("Show current app in Finder", "在访达中显示当前应用", "在 Finder 中顯示目前應用程式")) {
                                NSWorkspace.shared.activateFileViewerSelecting([preferences.runningApplicationURL])
                            }
                        }.padding(.top, 6)
                    }
                    if preferences.accessibilityGranted && !preferences.menuBarListening {
                        Text(C("Mouse monitoring is unavailable; quit and reopen Clipline after authorizing it.",
                               "暂时无法监听鼠标；完成授权后请退出并重新打开 Clipline。",
                               "暫時無法監聽滑鼠；完成授權後請結束並重新開啟 Clipline。"))
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text(C("Close this window before trying a double-click in the menu bar.",
                           "关闭此设置窗口后，再双击菜单栏空白处测试。",
                           "關閉此設定視窗後，再按兩下選單列空白處測試。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(C("Sounds", "音效", "音效"), isOn: Binding(
                        get: { preferences.soundEnabled },
                        set: { enabled in
                            line.soundOn = enabled
                            preferences.refresh()
                        }))
                    Text(C("Long-press an image to edit it in Clipline, including over full-screen apps.",
                           "长按图片，在 Clipline 内编辑；支持在全屏应用上方使用。",
                           "長按圖片，在 Clipline 內編輯；支援在全螢幕應用程式上方使用。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(C("Open at login", "登录时启动", "登入時啟動"), isOn: Binding(
                        get: { preferences.loginEnabled },
                        set: { enabled in
                            onSetLogin(enabled)
                            preferences.refresh()
                        }))
                }
                .toggleStyle(.checkbox)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label(C("Clothesline", "晾绳", "曬衣繩"), systemImage: "photo.on.rectangle.angled")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text(C("Clipboard history keeps up to 100 items and is cleared when you quit.",
                           "剪贴板历史最多保留最近 100 条，退出后清空。",
                           "剪貼簿記錄最多保留最近 100 筆，結束程式後清空。"))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button(C("Clear clipboard history", "清空剪贴板历史", "清空剪貼簿記錄")) {
                            clipboard.clear()
                        }
                        .disabled(clipboard.entries.isEmpty)
                        Button(C("Take everything down", "移除全部截图", "移除所有截圖")) {
                            line.clear()
                        }
                        .disabled(line.liveCount == 0)
                    }
                    Text(C("Taking screenshots down keeps their files and your pinned photos.",
                           "移除截图只取下晾绳上的截图，保留源文件和固定图片。",
                           "移除截圖只取下曬衣繩上的截圖，保留原始檔案與固定圖片。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label(C("History", "历史管理", "歷史管理"), systemImage: "clock.arrow.circlepath")
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 540, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .frame(width: 540, height: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            preferences.refreshCaptureState()
            preferences.refreshAccessibility()
        }
    }

    private var captureStatus: String {
        switch preferences.captureState {
        case .off:
            return C("Instant screenshots are off; macOS may show its floating thumbnail.",
                     "即时截图未开启，macOS 仍可能显示浮动缩略图。",
                     "即時截圖未開啟，macOS 仍可能顯示浮動縮圖。")
        case .ready:
            return C("Instant screenshots are on; the system floating thumbnail is off.",
                     "即时截图已开启，系统浮动缩略图已关闭。",
                     "即時截圖已開啟，系統浮動縮圖已關閉。")
        case .folderUnavailable:
            return C("The selected folder is unavailable. Check its location and access permissions.",
                     "当前保存目录无法读取，请检查目录位置和访问权限。",
                     "目前儲存目錄無法讀取，請檢查目錄位置與存取權限。")
        case .thumbnailEnabled:
            return C("The system floating thumbnail is on. Restore instant screenshots to remove the delay.",
                     "系统浮动缩略图已开启，恢复即时截图可消除等待。",
                     "系統浮動縮圖已開啟，恢復即時截圖可消除等待。")
        }
    }

}
