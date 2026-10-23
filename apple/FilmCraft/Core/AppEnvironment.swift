import Foundation
import OSLog
@preconcurrency import FilmCraftKit

/// Launch arguments, shared directories and loggers. UI tests read the logs (`ca.hologram.filmcraft`).
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    /// `-FilmCraftDemo`: a new untitled document built from the engine's procedural demo project.
    nonisolated static let isDemo = ProcessInfo.processInfo.arguments.contains("-FilmCraftDemo")
    /// `-FilmCraftResetState`: clear UserDefaults and caches at launch (as after a reinstall).
    nonisolated static let resetState = ProcessInfo.processInfo.arguments.contains("-FilmCraftResetState")

    /// The Photos library, shared by every window.
    let photos = PhotosLibrary()

    private init() {}

    // MARK: Directories

    /// `Library/Caches/FilmCraftMedia`: Photos originals (`PH-<b64url(localIdentifier)>.<ext>`).
    nonisolated static var mediaCacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("FilmCraftMedia", isDirectory: true)
    }

    /// `Documents/Media` (visible in the Files app): media copied from Files.
    nonisolated static var documentsMediaDirectory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Media", isDirectory: true)
    }

    nonisolated static func ensureDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Runs once, before the first scene: honours `-FilmCraftResetState`.
    static func prepareLaunch() {
        if resetState {
            if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
            try? FileManager.default.removeItem(at: mediaCacheDirectory)
            // Documents/Media holds the only copies of media added from Files: never deleted here.
            Log.app.info("state reset")
        }
        ensureDirectory(mediaCacheDirectory)
        // The cache can be rebuilt from Photos: keep it out of backups.
        var url = mediaCacheDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

/// Loggers (subsystem `ca.hologram.filmcraft`).
enum Log {
    static let subsystem = "ca.hologram.filmcraft"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let document = Logger(subsystem: subsystem, category: "document")
    static let command = Logger(subsystem: subsystem, category: "command")
    static let playback = Logger(subsystem: subsystem, category: "playback")
    static let media = Logger(subsystem: subsystem, category: "media")
    static let photos = Logger(subsystem: subsystem, category: "photos")
    static let export = Logger(subsystem: subsystem, category: "export")
}
