import Foundation

@main
struct StorageChecks {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAIL: " + message) }
            checks += 1
        }
        let new = Inbox.folder
        let old = Inbox.legacyFolder
        let original = Inbox.Settings(location: "/Users/example/Desktop",
                                      screenshotLocation: "/Users/example/Captures",
                                      showsThumbnail: true)
        check(new.deletingLastPathComponent() == FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0],
              "future screenshot folder is in Pictures")
        check(Inbox.contains(new.appendingPathComponent("capture.png")), "new screenshot is managed")
        check(Inbox.contains(old.appendingPathComponent("capture.png")), "legacy screenshot is still managed")
        check(!Inbox.contains(new), "folder itself is not treated as a capture")
        check(!Inbox.contains(URL(fileURLWithPath: new.path + " copy/capture.png")), "similar prefix is not managed")
        check(!Inbox.contains(new.appendingPathComponent("../other/capture.png")), "normalized path cannot escape managed folder")
        check(Inbox.ownsLocation(old.path) && Inbox.ownsLocation(new.path), "old and new settings are owned")
        check(!Inbox.ownsLocation(nil) && !Inbox.ownsLocation(""), "missing locations are not owned")
        check(!Inbox.ownsLocation(new.appendingPathComponent("child").path), "nested folder is not an applied location")
        check(Inbox.settingsToSave(current: original, existingBackup: nil) == original, "first application preserves all original settings")

        let legacyApplied = Inbox.Settings(location: old.path, screenshotLocation: old.path, showsThumbnail: false)
        check(Inbox.settingsToSave(current: legacyApplied, existingBackup: original) == original,
              "upgrade preserves original backup instead of saving Library path")
        let newApplied = Inbox.Settings(location: new.path, screenshotLocation: new.path, showsThumbnail: false)
        check(Inbox.settingsToSave(current: newApplied, existingBackup: original) == original,
              "reapplication preserves backup")
        check(Inbox.settingsToSave(current: legacyApplied, existingBackup: nil) == Inbox.Settings(),
              "lost legacy backup falls back to system defaults")
        let partialApplied = Inbox.Settings(location: new.path, screenshotLocation: original.screenshotLocation,
                                            showsThumbnail: false)
        check(Inbox.settingsToSave(current: partialApplied, existingBackup: nil)
              == Inbox.Settings(screenshotLocation: original.screenshotLocation), "partial recovery retains user location")
        check(Inbox.settingsToRestore(current: newApplied, saved: original) == original, "new settings restore originals")
        check(Inbox.settingsToRestore(current: legacyApplied, saved: original) == original, "legacy settings restore originals")
        let userChangedSecondary = Inbox.Settings(location: new.path, screenshotLocation: "/Users/example/New Choice",
                                                  showsThumbnail: false)
        check(Inbox.settingsToRestore(current: userChangedSecondary, saved: original)
              == Inbox.Settings(location: original.location, screenshotLocation: "/Users/example/New Choice",
                                showsThumbnail: original.showsThumbnail),
              "restore does not overwrite changed screenshot-specific location")
        let changed = Inbox.Settings(location: "/Users/example/Downloads",
                                     screenshotLocation: "/Users/example/Images", showsThumbnail: false)
        check(Inbox.settingsToRestore(current: changed, saved: original)
              == Inbox.Settings(location: changed.location, screenshotLocation: changed.screenshotLocation, showsThumbnail: true),
              "custom folders preserved while original thumbnail setting restored")
        let thumbnailChanged = Inbox.Settings(location: new.path, screenshotLocation: new.path, showsThumbnail: true)
        check(Inbox.settingsToRestore(current: thumbnailChanged, saved: Inbox.Settings())?.showsThumbnail == true,
              "user reenabling thumbnail is preserved")
        check(Inbox.Settings(dictionary: original.dictionary) == original, "settings dictionary round trips")
        check(Inbox.Settings(dictionary: Inbox.Settings().dictionary) == Inbox.Settings(), "absent defaults round trip")
        let custom = Inbox.Settings(location: "/Users/example/Captures", recordingLocation: "/Users/example/Movies", showsThumbnail: false)
        check(Inbox.captureState(enabled: true, settings: custom) == .ready, "instant capture works in custom folders")
        check(Inbox.captureState(enabled: false, settings: custom) == .off, "disabled mode clearly reported")
        var drift = custom; drift.showsThumbnail = nil
        check(Inbox.captureState(enabled: true, settings: drift) == .thumbnailEnabled, "default thumbnail is enabled")
        check(Inbox.shouldDisableThumbnail(enabled: true, settings: drift), "thumbnail drift corrected without changing paths")
        check(!Inbox.shouldDisableThumbnail(enabled: false, settings: drift), "disabled mode leaves system setting alone")
        check(!Inbox.shouldDisableThumbnail(enabled: true, settings: custom), "ready mode avoids redundant writes")
        check(custom.locations(separate: true).screenshots.path == "/Users/example/Captures" && custom.locations(separate: true).recordings.path == "/Users/example/Movies", "separate user folders supported")
        check(Inbox.Settings(dictionary: custom.dictionary) == custom, "recording folder backup round trips")
        let independent = Inbox.Settings(screenshotLocation: "/Users/example/Specific", recordingLocation: "/Users/example/Videos")
        check(independent.locations(separate: true).screenshots.path == "/Users/example/Specific", "screenshot-specific preference takes precedence")
        check(CaptureLocations(screenshots: nil, recordings: nil).folders.count == 1, "shared system default needs one watcher")
        check(custom.locations(separate: true).accepts(URL(fileURLWithPath: "/Users/example/Captures/a.png")), "screenshot accepted in current folder")
        check(!custom.locations(separate: true).accepts(URL(fileURLWithPath: "/Users/example/Previous/a.png")), "previous folder excluded")
        check(custom.locations(separate: true).accepts(URL(fileURLWithPath: "/Users/example/Movies/a.MOV")), "recording accepted in current recording folder")
        check(!custom.locations(separate: true).accepts(URL(fileURLWithPath: "/Users/example/Captures/a.mov")), "recording does not leak from inactive folder")
        check(!custom.locations(separate: true).accepts(URL(fileURLWithPath: "/Users/example/Captures/sub/a.png")), "subfolders are not implicitly loaded")
        check(custom.locations(separate: false).screenshots == custom.locations(separate: false).recordings, "older systems use the shared save preference")
        check(independent.locations(separate: false).screenshots == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"), "stale unsupported keys cannot mask a changed shared folder")
        check(Inbox.settingsToRestore(current: newApplied, saved: original, restoreLocations: false)?.location == newApplied.location, "user-selected inbox folder survives quitting when Clipline did not set it")
        print("PASS: \(checks) storage migration and restore checks (no system preferences changed)")
    }
}
