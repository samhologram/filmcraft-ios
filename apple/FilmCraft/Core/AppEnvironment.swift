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

    /// Persistent app-owned media, in FilmCraft's iCloud Documents container when available.
    /// A copy made while offline stays in local Documents; existing projects may reference either location.
    nonisolated static var documentsMediaDirectory: URL {
        let fm = FileManager.default
        let base = fm.url(forUbiquityContainerIdentifier: "iCloud.ca.hologram.filmcraft")?
            .appendingPathComponent("Documents", isDirectory: true)
            ?? localDocumentsDirectory
        return base.appendingPathComponent("Media", isDirectory: true)
    }

    nonisolated static var localDocumentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    nonisolated static var existingMediaDirectories: [URL] {
        let local = localDocumentsDirectory.appendingPathComponent("Media", isDirectory: true)
        let preferred = documentsMediaDirectory
        return preferred.standardizedFileURL == local.standardizedFileURL ? [local] : [preferred, local]
    }

    /// Preserve an independent source copy. Reuse identical bytes; never replace the original or an existing copy.
    nonisolated static func copyIntoOwnedMedia(_ source: URL, preferredName: String? = nil) throws -> URL {
        let fm = FileManager.default
        var folder = documentsMediaDirectory
        do { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch {
            folder = localDocumentsDirectory.appendingPathComponent("Media", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        if existingMediaDirectories.contains(where: {
            source.deletingLastPathComponent().standardizedFileURL == $0.standardizedFileURL
        }) { return source }
        let requestedName = URL(fileURLWithPath: preferredName ?? source.lastPathComponent).lastPathComponent
        let named = URL(fileURLWithPath: requestedName)
        let base = named.deletingPathExtension().lastPathComponent
        let ext = named.pathExtension.isEmpty ? source.pathExtension : named.pathExtension
        for existingFolder in existingMediaDirectories where existingFolder.standardizedFileURL != folder.standardizedFileURL {
            let names = (try? fm.contentsOfDirectory(atPath: existingFolder.path)) ?? []
            for name in names where (name as NSString).pathExtension == ext {
                let stem = (name as NSString).deletingPathExtension
                guard stem == base || stem.hasPrefix(base + " ") else { continue }
                let existing = existingFolder.appendingPathComponent(name)
                if fm.contentsEqual(atPath: source.path, andPath: existing.path) { return existing }
            }
        }
        for index in 0..<1000 {
            let name = index == 0 ? base : "\(base) \(index + 1)"
            let destination = folder.appendingPathComponent(name).appendingPathExtension(ext)
            if fm.fileExists(atPath: destination.path) {
                if fm.contentsEqual(atPath: source.path, andPath: destination.path) { return destination }
                continue
            }
            try fm.copyItem(at: source, to: destination)
            return destination
        }
        throw CocoaError(.fileWriteFileExists)
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
