import Foundation

struct CaptureLocations: Equatable {
    let screenshots: URL
    let recordings: URL

    init(screenshots: String?, recordings: String?) {
        func resolve(_ path: String?) -> URL {
            guard let path, !path.isEmpty else { return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop") }
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        }
        self.screenshots = resolve(screenshots)
        self.recordings = resolve(recordings)
    }

    var folders: [URL] { screenshots == recordings ? [screenshots] : [screenshots, recordings] }

    func accepts(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL == (["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) ? recordings : screenshots)
    }
}

