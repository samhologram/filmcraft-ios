import Foundation
@preconcurrency import Photos
@preconcurrency import FilmCraftKit

enum ExportDestination {
    case photos
    case files(URL)
}

/// Export settings the sheet edits. `preset` is the engine preset id ("h264"); `quality` is 0...100.
struct ExportOptions {
    var preset: String = "h264"
    var width: Int?
    var height: Int?
    var quality: Int = 75
}

/// Renders the sequence with the engine encoder (H.264 + AAC MP4) to a temp file, then saves it to Photos
/// (add-only authorization) or moves it to a Files destination.
@MainActor
enum ExportService {
    enum Phase: Sendable {
        case rendering(Double)
        case failed(String)
        case cancelled
        case done(URL)
    }

    /// Runs the whole export, reporting progress (0...1, `nil` when finished). `setJob` receives the job id so the
    /// caller can cancel it.
    static func run(
        handle: ProjectHandle, options: ExportOptions,
        setJob: @MainActor (UInt64?) -> Void,
        progress: @MainActor (Double) -> Void
    ) async -> Phase {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FilmCraftExport", isDirectory: true)
        AppEnvironment.ensureDirectory(directory)
        let output = directory.appendingPathComponent("FilmCraft-\(UUID().uuidString.prefix(8)).mp4")
        let optionsJSON = Self.optionsJSON(options)
        let job: UInt64
        do {
            job = try handle.startExport(path: output.path, optionsJson: optionsJSON)
        } catch {
            Log.export.error("export start failed: \(errorText(error), privacy: .public)")
            return .failed(errorText(error))
        }
        setJob(job)
        Log.export.info("export started: job \(job, privacy: .public) \(optionsJSON, privacy: .public)")
        defer { setJob(nil) }
        var lastLogged = -1
        while true {
            await pause(milliseconds: 250)
            guard let status = handle.jobStatus(jobId: job) else { return .failed("The export job disappeared.") }
            let fraction = min(max(status.fraction.isFinite ? status.fraction : 0, 0), 1)
            progress(fraction)
            let percent = Int(fraction * 100) / 10
            if percent != lastLogged {
                lastLogged = percent
                Log.export.info("export progress: \(Int(fraction * 100), privacy: .public)%")
            }
            if status.done {
                if let error = status.error {
                    try? FileManager.default.removeItem(at: output)
                    if Task.isCancelled { return .cancelled }  // cancellation is our own signal, not parsed from the message
                    return .failed(error)
                }
                let path = status.output ?? output.path
                return .done(URL(fileURLWithPath: path))
            }
            if Task.isCancelled {
                handle.cancelJob(jobId: job)
            }
        }
    }

    /// A sleep that keeps ticking when the task is cancelled (the loop must still observe the job finishing).
    private static func pause(milliseconds: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) { continuation.resume() }
        }
    }

    /// Bridge options: {"preset", "width"?, "height"?, "crf", "audio":"aac", "range":"all"}.
    static func optionsJSON(_ options: ExportOptions) -> String {
        var object: [String: Any] = ["preset": options.preset, "audio": "aac", "range": "all"]
        if let width = options.width, width > 0 { object["width"] = width }
        if let height = options.height, height > 0 { object["height"] = height }
        // quality 100 -> crf 15 (near lossless) ... 0 -> crf 35.
        let quality = min(max(options.quality, 0), 100)
        object["crf"] = 35 - Int((Double(quality) * 0.2).rounded())
        return EditorModel.encode(object) ?? "{}"
    }

    // MARK: Destinations

    static func save(_ file: URL, to destination: ExportDestination) async throws -> String {
        switch destination {
        case .photos:
            try await saveToPhotos(file)
            try? FileManager.default.removeItem(at: file)
            return "Saved to Photos"
        case .files(let url):
            // Potentially gigabytes: off the main actor, and the existing destination is replaced only on success.
            let source = file
            try await Task.detached(priority: .utility) { try Self.place(source, at: url) }.value
            return "Saved to \(url.lastPathComponent)"
        }
    }

    nonisolated private static func place(_ file: URL, at url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial")
        do {
            try fm.copyItem(at: file, to: temp)
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: url)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        try? fm.removeItem(at: file)
    }

    private static func saveToPhotos(_ file: URL) async throws {
        var access = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if access == .notDetermined { access = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
        guard access == .authorized || access == .limited else {
            throw PhotosLibrary.error("FilmCraft is not allowed to add to Photos. Allow it in Settings > Privacy & Security > Photos.")
        }
        try await create(file)
    }

    nonisolated private static func create(_ file: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            request.addResource(with: .video, fileURL: file, options: options)
        }
    }
}
