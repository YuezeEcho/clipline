import Foundation

/// Instant capture disables macOS's floating thumbnail. Save locations stay
/// under the user's control and are followed by the capture library.
enum Inbox {
    private static let domain = "com.apple.screencapture" as CFString
    // Support both the shared preference and capture-specific preferences.
    private static let locationKey = "location" as CFString
    private static let screenshotLocationKey = "location-screenshot" as CFString
    private static let recordingLocationKey = "location-video" as CFString
    static let usesSeparateLocations = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    private static let thumbnailKey = "show-thumbnail" as CFString

    private static let enabledKey = "inboxEnabled"
    private static let offeredKey = "inboxOffered"
    private static let savedKey = "inboxSavedSettings"

    static let folder: URL = {
        let base = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Clipline Screenshots", isDirectory: true)
    }()

    /// Existing captures keep their original URLs. Recognize this location
    /// when upgrading so it never becomes the user's restored save location.
    static let legacyFolder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Clipline/Screenshots", isDirectory: true)
    }()

    static func contains(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return [folder, legacyFolder].contains {
            path.hasPrefix($0.standardizedFileURL.path + "/")
        }
    }

    struct Settings: Equatable {
        var location: String?
        var screenshotLocation: String?
        var recordingLocation: String?
        var showsThumbnail: Bool?

        init(location: String? = nil, screenshotLocation: String? = nil,
             recordingLocation: String? = nil, showsThumbnail: Bool? = nil) {
            self.location = location
            self.screenshotLocation = screenshotLocation
            self.recordingLocation = recordingLocation
            self.showsThumbnail = showsThumbnail
        }

        init(dictionary: [String: Any]) {
            location = dictionary["location"] as? String
            screenshotLocation = dictionary["locationScreenshot"] as? String
            recordingLocation = dictionary["locationVideo"] as? String
            showsThumbnail = dictionary["thumbnail"] as? Bool
        }

        var dictionary: [String: Any] {
            var values: [String: Any] = [:]
            if let location { values["location"] = location }
            if let screenshotLocation { values["locationScreenshot"] = screenshotLocation }
            if let recordingLocation { values["locationVideo"] = recordingLocation }
            if let showsThumbnail { values["thumbnail"] = showsThumbnail }
            return values
        }

        var hasOwnedLocation: Bool {
            Inbox.ownsLocation(location) || Inbox.ownsLocation(screenshotLocation)
                || Inbox.ownsLocation(recordingLocation)
        }

        func locations(separate: Bool) -> CaptureLocations {
            CaptureLocations(screenshots: separate ? (screenshotLocation ?? location) : location,
                             recordings: separate ? (recordingLocation ?? location) : location)
        }

        var locations: CaptureLocations { locations(separate: Inbox.usesSeparateLocations) }
    }

    enum CaptureState: Equatable { case off, ready, folderUnavailable, thumbnailEnabled }

    static func captureState(enabled: Bool, settings: Settings) -> CaptureState {
        guard enabled else { return .off }
        return settings.showsThumbnail == false ? .ready : .thumbnailEnabled
    }

    static var captureState: CaptureState {
        let current = currentSettings()
        let state = captureState(enabled: isEnabled, settings: current)
        if isEnabled && !current.locations.folders.allSatisfy({ FileManager.default.isReadableFile(atPath: $0.path) }) {
            return .folderUnavailable
        }
        return state
    }

    static var locations: CaptureLocations { currentSettings().locations }

    static func ownsLocation(_ path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        return [folder, legacyFolder].contains { $0.standardizedFileURL.path == url.path }
    }

    /// Pure planning functions also let regression checks cover crash recovery
    /// and upgrades without changing macOS screenshot preferences.
    static func settingsToSave(current: Settings, existingBackup: Settings?) -> Settings {
        guard current.hasOwnedLocation else { return current }
        if let existingBackup { return existingBackup }
        // An old instance may have exited without leaving a backup. Restore
        // system defaults for our values and preserve any independent setting.
        return Settings(location: ownsLocation(current.location) ? nil : current.location,
                        screenshotLocation: ownsLocation(current.screenshotLocation) ? nil : current.screenshotLocation,
                        recordingLocation: ownsLocation(current.recordingLocation) ? nil : current.recordingLocation,
                        showsThumbnail: current.showsThumbnail == false ? nil : current.showsThumbnail)
    }

    static func settingsToRestore(current: Settings, saved: Settings, restoreLocations: Bool = true) -> Settings? {
        guard current.hasOwnedLocation || current.showsThumbnail == false else { return nil }
        // If the user changes a save location while Clipline runs, keep it.
        return Settings(location: restoreLocations && ownsLocation(current.location) ? saved.location : current.location,
                        screenshotLocation: restoreLocations && ownsLocation(current.screenshotLocation) ? saved.screenshotLocation : current.screenshotLocation,
                        recordingLocation: restoreLocations && ownsLocation(current.recordingLocation) ? saved.recordingLocation : current.recordingLocation,
                        showsThumbnail: current.showsThumbnail == false ? saved.showsThumbnail : current.showsThumbnail)
    }

    /// The user's choice, kept across launches.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Whether we already asked, so the offer appears only once.
    static var wasOffered: Bool {
        get { UserDefaults.standard.bool(forKey: offeredKey) }
        set { UserDefaults.standard.set(newValue, forKey: offeredKey) }
    }

    /// Whether instant capture is configured and the selected folders are readable.
    static var isApplied: Bool {
        captureState == .ready
    }

    @discardableResult
    static func apply(resetLocation: Bool = false) -> Bool {
        if resetLocation {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                NSLog("Clipline: cannot create screenshot folder: %@", error.localizedDescription)
                return false
            }
        }
        // Never save our own values as the "previous" ones, for example after
        // a crash left them applied, or the previous version used Library.
        let dictionary = UserDefaults.standard.dictionary(forKey: savedKey)
        let backup = dictionary.map(Settings.init(dictionary:))
        let current = currentSettings()
        let saved = backup ?? settingsToSave(current: current, existingBackup: nil)
        var values = saved.dictionary
        // Older versions changed the directory; this version normally changes
        // only the thumbnail. A user's own choice must survive quitting.
        values["changedLocation"] = resetLocation || (dictionary?["changedLocation"] as? Bool
            ?? (dictionary != nil && current.hasOwnedLocation))
        UserDefaults.standard.set(values, forKey: savedKey)
        if resetLocation {
            set(locationKey, folder.path)
            set(screenshotLocationKey, usesSeparateLocations ? folder.path : nil)
            set(recordingLocationKey, usesSeparateLocations ? folder.path : nil)
        }
        set(thumbnailKey, false)
        return isApplied
    }

    /// Keep instant capture instant if the system's thumbnail option is changed.
    /// Custom screenshot and recording locations are never changed back.
    static func maintainInstantCapture() {
        guard isEnabled else { return }
        let current = currentSettings()
        guard shouldDisableThumbnail(enabled: true, settings: current) else { return }
        set(thumbnailKey, false)
    }

    static func shouldDisableThumbnail(enabled: Bool, settings: Settings) -> Bool {
        enabled && settings.showsThumbnail != false
    }

    static func restore() {
        guard let dictionary = UserDefaults.standard.dictionary(forKey: savedKey) else { return }
        let saved = Settings(dictionary: dictionary)
        defer { UserDefaults.standard.removeObject(forKey: savedKey) }
        guard let restored = settingsToRestore(current: currentSettings(), saved: saved,
                                               restoreLocations: dictionary["changedLocation"] as? Bool ?? true) else { return }
        set(locationKey, restored.location)
        set(screenshotLocationKey, restored.screenshotLocation)
        set(recordingLocationKey, restored.recordingLocation)
        set(thumbnailKey, restored.showsThumbnail)
    }

    private static func currentSettings() -> Settings {
        CFPreferencesAppSynchronize(domain)
        return Settings(location: CFPreferencesCopyAppValue(locationKey, domain) as? String,
                        screenshotLocation: CFPreferencesCopyAppValue(screenshotLocationKey, domain) as? String,
                        recordingLocation: CFPreferencesCopyAppValue(recordingLocationKey, domain) as? String,
                        showsThumbnail: CFPreferencesCopyAppValue(thumbnailKey, domain) as? Bool)
    }

    /// Writes through cfprefsd, so the screenshot service sees it at once.
    /// A nil value removes the key and returns it to the macOS default.
    private static func set(_ key: CFString, _ value: Any?) {
        CFPreferencesSetAppValue(key, value as CFPropertyList?, domain)
        CFPreferencesAppSynchronize(domain)
    }
}
