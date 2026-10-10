import AppKit
import SwiftUI
import Vision

/// Inspects only an offscreen view, invented files and disposable preferences.
@main
struct SettingsChecks {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let suite = "local.clipline.settings-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let originalSystemLanguages = defaults.stringArray(forKey: "AppleLanguages")
        let language = AppLanguage(defaults: defaults, preferredLanguages: { ["en"] }, appliesGlobally: true)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let clipboard = ClipboardHistory(pasteboard: pasteboard)
        clipboard.record(.text("Invented settings-test clipboard entry"), source: "Test")
        let line = Line(persistsScreenshots: false)
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("clipline-settings-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 60,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                    bitsPerPixel: 0)!
        try image.representation(using: .png, properties: [:])!.write(to: fixture)
        precondition(line.hang(fixture, quietly: true) != nil)
        let originalEntries = clipboard.entries.map(\.id)
        let originalScreenshots = line.items.map(\.id)
        var permissionGranted = false
        var listening = false
        let preferences = SettingsPreferences(line: line, permissionCheck: { permissionGranted },
                                               listeningCheck: { listening })
        var mutationCallbacks = 0
        let host = NSHostingView(rootView: SettingsView(line: line, clipboard: clipboard,
                                                       preferences: preferences, language: language,
                                                       onSetInbox: { _ in mutationCallbacks += 1 },
                                                       onSetLogin: { _ in mutationCallbacks += 1 }))
        host.sizingOptions = []
        let panel = NSPanel(contentRect: NSRect(x: -10_000, y: -10_000, width: 540, height: 720),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil); panel.close() }
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAIL: " + message) }
            checks += 1
        }
        check(preferences.runningApplicationURL == Bundle.main.bundleURL,
              "authorization guidance uses the running bundle on this Mac")
        for path in ["/Applications/Clipline.app", "/Users/Another Person/下载/Clipline-0.1.15.app"] {
            let relocated = SettingsPreferences(line: line, permissionCheck: { false }, listeningCheck: { false },
                                                runningApplicationURL: URL(fileURLWithPath: path))
            check(relocated.runningApplicationURL.path == path,
                  "authorization guidance follows relocated apps and different users, including spaces and Unicode")
        }
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let variants: [(AppLanguageChoice, [String])] = [
            (.en, ["Settings", "Language", "Screenshot and recording folder", "Double-click empty menu-bar space", "Handle screenshots", "Sounds", "Long-press an image", "This copy of Clipline needs Accessibility permission", "Open at login", "Clear clipboard history", "Take everything down"]),
            (.zhHans, ["设置", "语言", "截图与录屏保存位置", "双击菜单栏空白处", "接管系统截图", "音效", "长按图片", "当前运行的 Clipline 尚未获得辅助功能权限", "登录时启动", "清空剪贴板历史", "移除全部截图"]),
            (.zhHant, ["設定", "語言", "截圖與錄影儲存位置", "按兩下選單列空白處", "接管系統截圖", "音效", "長按圖片", "目前執行的 Clipline 尚未取得輔助使用權限", "登入時啟動", "清空剪貼簿記錄", "移除所有截圖"])
        ]
        for (choice, expectedLabels) in variants {
            language.selected = choice
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Cannot render settings") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]), let cgImage = bitmap.cgImage else { fatalError("Cannot encode settings") }
            try png.write(to: output.appendingPathComponent("settings-preview-\(choice.rawValue).png"))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = [choice == .zhHant ? "zh-Hant" : "zh-Hans", "en-US"]
            try VNImageRequestHandler(cgImage: cgImage).perform([request])
            let labels = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            for label in expectedLabels {
                check(labels.contains { $0.replacingOccurrences(of: " ", with: "").contains(label.replacingOccurrences(of: " ", with: "")) },
                      "\(choice.rawValue) rendered text is visible without truncation: \(label); actual: \(labels)")
            }
            check(host.bounds.size == CGSize(width: 540, height: 720), "settings dimensions remain stable")
            check(clipboard.entries.map(\.id) == originalEntries && line.items.map(\.id) == originalScreenshots,
                  "language switches preserve clipboard and screenshot history")
        }
        func renderedStatus(_ suffix: String) throws -> String {
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("settings-permission-\(suffix).png"))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: bitmap.cgImage!).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        }
        preferences.refreshAccessibility()
        check(!preferences.accessibilityGranted && !preferences.menuBarListening, "untrusted running process is reported accurately")
        permissionGranted = true
        listening = true
        preferences.refreshAccessibility()
        check(preferences.accessibilityGranted && preferences.menuBarListening, "new grant updates without reopening settings")
        language.selected = .en
        let grantedText = try renderedStatus("granted")
        check(grantedText.contains("Accessibility permission granted"), "granted message visibly replaces stale permission request")
        check(!grantedText.contains("needs Accessibility permission"), "authorized app does not display an authorization request")
        listening = false
        preferences.refreshAccessibility()
        check(preferences.accessibilityGranted && !preferences.menuBarListening, "permission and live mouse monitoring are distinct")
        let unavailableText = try renderedStatus("unavailable")
        check(unavailableText.contains("Mouse monitoring is unavailable"),
              "monitoring failure is visibly distinct from missing permission")
        permissionGranted = false
        listening = true
        preferences.refreshAccessibility()
        check(!preferences.accessibilityGranted && !preferences.menuBarListening, "revocation clears permission and listening status")
        check(mutationCallbacks == 0, "rendering and switching languages do not change system screenshot or login settings")
        check(defaults.stringArray(forKey: "AppleLanguages") == originalSystemLanguages, "system language preferences remain untouched")
        print("PASS: \(checks) offscreen settings layout, rendered-text and live-language checks")
    }
}
