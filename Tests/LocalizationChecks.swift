import Foundation

/// Uses disposable preferences, never the user's interface language.
@main
struct LocalizationChecks {
    @MainActor static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAIL: " + message) }
            checks += 1
        }
        let variants: [(String, AppLanguageChoice)] = [
            ("zh", .zhHans), ("zh-CN", .zhHans), ("zh-SG", .zhHans), ("zh-Hans", .zhHans),
            ("zh-Hant", .zhHant), ("zh-TW", .zhHant), ("zh-HK", .zhHant), ("zh-MO", .zhHant),
            ("zh_Hant_HK", .zhHant), ("ZH-hant", .zhHant), ("zh-Hans-TW", .zhHans),
            ("zh-Hant-CN", .zhHant), ("yue-HK", .zhHant), ("en-US", .en), ("es-MX", .es)
        ]
        for (preferred, expected) in variants {
            check(AppLanguageChoice.automatic.resolved(preferredLanguages: [preferred]) == expected, "system language: " + preferred)
        }
        check(AppLanguageChoice.automatic.resolved(preferredLanguages: []) == .en, "empty system list falls back to English")
        check(AppLanguageChoice.automatic.resolved(preferredLanguages: ["fr-FR", "de"]) == .en, "unsupported system language falls back to English")
        check(AppLanguageChoice.automatic.resolved(preferredLanguages: ["fr", "zh-TW", "en"]) == .zhHant, "preferred supported language wins")
        check(AppLanguageChoice.automatic.resolved(preferredLanguages: ["en", "zh-TW"]) == .en, "English preferred before Chinese remains English")
        for choice in AppLanguageChoice.allCases where choice != .automatic {
            check(choice.resolved(preferredLanguages: ["zh-CN"]) == choice, "explicit selection wins over system")
        }

        let suite = "local.clipline.language-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["es-MX"], forKey: "AppleLanguages")
        var system = ["zh-TW"]
        let language = AppLanguage(defaults: defaults, preferredLanguages: { system })
        check(language.selected == .automatic && language.resolved == .zhHant, "fresh instance follows Traditional Chinese system")
        check(defaults.string(forKey: AppLanguage.preferenceKey) == nil, "initialization does not write language preference")
        language.selected = .zhHans
        check(language.resolved == .zhHans && defaults.string(forKey: AppLanguage.preferenceKey) == "zhHans", "Simplified Chinese applies and persists")
        language.selected = .zhHant
        check(language.resolved == .zhHant, "Traditional Chinese applies immediately")
        let restored = AppLanguage(defaults: defaults, preferredLanguages: { ["en"] })
        check(restored.selected == .zhHant && restored.resolved == .zhHant, "explicit language survives restart and system changes")
        language.selected = .es
        check(language.resolved == .es, "Spanish remains available")
        language.selected = .automatic
        check(language.resolved == .zhHant, "Follow System restores regional Chinese")
        system = ["zh-CN"]
        language.refresh()
        check(language.resolved == .zhHans, "system change refreshes automatic selection")
        check(defaults.stringArray(forKey: "AppleLanguages") == ["es-MX"], "app language never changes system preferences")
        defaults.set("invalid-choice", forKey: AppLanguage.preferenceKey)
        let malformed = AppLanguage(defaults: defaults, preferredLanguages: { ["en"] })
        check(malformed.selected == .automatic && malformed.resolved == .en, "unknown stored language safely falls back to system")

        for (english, pair) in AppLocalization.chinese {
            check(!pair.0.isEmpty && !pair.1.isEmpty, "Chinese translations exist: " + english)
            check(AppLocalization.text(english, language: .zhHans) == pair.0, "Simplified Chinese dictionary: " + english)
            check(AppLocalization.text(english, language: .zhHant) == pair.1, "Traditional Chinese dictionary: " + english)
            check(AppLocalization.text(english, language: .en) == english, "English retained: " + english)
        }
        check(AppLocalization.text("Clipboard", simplified: "剪贴板", language: .zhHant) == "剪貼簿", "Traditional Chinese uses idiomatic clipboard term")
        check(AppLocalization.text("Save to Desktop", language: .zhHant) == "儲存到桌面", "Traditional Chinese uses native save term")
        check(AppLocalization.text("Move to Trash", language: .zhHant) == "移到廢紙簍", "Traditional Chinese uses Finder trash term")
        check(AppLocalization.text("Unknown", simplified: "设置", traditional: "設定", language: .zhHant) == "設定", "explicit Traditional Chinese extension is honored")
        check(AppLocalization.text("Unknown", simplified: "这张图片", language: .zhHant) == "這張圖片", "new label has readable conversion fallback")
        check(AppLocalization.text("Unknown", language: .zhHant) == "Unknown", "missing translation safely keeps English")
        check(AppLocalization.text("Copy", spanish: "Copiar", language: .es) == "Copiar", "original Spanish translation remains available")
        check(AppLocalization.text("Clipboard history", language: .es) == "Historial del portapapeles", "new clipboard label has Spanish translation")
        check(AppLanguageChoice.zhHans.nativeName == "简体中文" && AppLanguageChoice.zhHant.nativeName == "繁體中文", "language names use their own script")

        // Exercise production helpers and notification delivery without using
        // shared or standard writable preferences in this test process.
        let globalLanguage = AppLanguage(defaults: defaults, preferredLanguages: { ["en"] }, appliesGlobally: true)
        globalLanguage.selected = .zhHans
        check(C("Clipboard", "剪贴板") == "剪贴板" && L("Copy", "Copiar") == "复制", "existing C/L helpers switch to Simplified Chinese")
        globalLanguage.selected = .zhHant
        check(C("Clipboard", "剪贴板") == "剪貼簿" && L("Copy", "Copiar") == "複製", "existing C/L helpers switch to Traditional Chinese")
        globalLanguage.selected = .en
        check(C("Clipboard", "剪贴板") == "Clipboard", "existing helper immediately switches to English")
        globalLanguage.selected = .es
        check(C("Clipboard", "剪贴板") == "Portapapeles" && L("Copy", "Copiar") == "Copiar", "both helper styles support Spanish")

        // Coverage follows real call sites so new user-visible English keys
        // cannot silently fall back to English in either Chinese script.
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sources = project.appendingPathComponent("Sources/Tendedero")
        let expression = try! NSRegularExpression(pattern: #"\b([CL])\(\s*"([^"]+)""#)
        let files = try! FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "swift" && file.lastPathComponent != "Localization.swift" {
            let text = try! String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in expression.matches(in: text, range: range) {
                let key = String(text[Range(match.range(at: 2), in: text)!])
                check(AppLocalization.chinese[key] != nil, "explicit Chinese coverage: \(file.lastPathComponent): \(key)")
                if text[Range(match.range(at: 1), in: text)!] == "C" {
                    check(AppLocalization.spanishStrings[key] != nil, "Spanish C-helper coverage: \(file.lastPathComponent): \(key)")
                }
            }
        }
        print("PASS: \(checks) locale resolution, persistence and localization checks")
    }
}
