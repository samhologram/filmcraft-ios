import Foundation
@preconcurrency import FilmCraftKit

/// Adding media (Photos or Files), relinking after open, and the engine commands used to place it.
///
/// Engine commands used (from `crates/engine/src/commands.rs`):
/// - `file.import` via `ProjectHandle.importFiles(paths:)` -> new media ids,
/// - `timeline.place` `{"items":[mediaId...], "time": <playhead ticks>, "insert": true}`: the items are placed back
///   to back at the playhead (insert edit) on the targeted tracks, as one undo step.
extension EditorModel {
    // MARK: Opening

    /// Runs once when the scene appears: relinks offline media (cache, Documents/Media, Photos), renders the first frame.
    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        Log.document.info("document opened: \(self.state.projectName, privacy: .public), \(self.media.count, privacy: .public) media")
        await relinkOfflineMedia()
        requestFrame(at: state.playhead)
    }

    /// Relinks offline media whose file names exist in the media cache or `Documents/Media`. Automatic on open and
    /// never registered on the UndoManager (the document must not open dirty). Photos re-materialization needs
    /// the person's Photos permission, so it only runs through `relinkFromPhotos()` when access is already granted
    /// (or when the person asks, e.g. from an "offline media" affordance).
    func relinkOfflineMedia() async {
        guard media.contains(where: \.offline) else { return }
        let handle = self.handle
        let cache = AppEnvironment.mediaCacheDirectory.path
        let stillOffline: [UInt64] = await Task.detached(priority: .userInitiated) {
            for folder in AppEnvironment.existingMediaDirectories {
                _ = handle.relinkMissing(resolverDir: folder.path)
            }
            return handle.relinkMissing(resolverDir: cache)
        }.value
        refresh()
        mediaVersion += 1
        if photos.isAuthorized, !stillOffline.isEmpty { await relinkFromPhotos(requestAccess: false) }
        Log.media.info("relink done: \(self.media.filter(\.offline).count, privacy: .public) still offline")
    }

    /// For still-offline `PH-…` media: decode the Photos identifier, re-materialize the original, relink again.
    func relinkFromPhotos(requestAccess: Bool = true) async {
        var identifiers: [String] = []
        for item in media where item.offline {
            let name = (item.path as NSString).lastPathComponent
            let fallback = (item.name as NSString).lastPathComponent
            if let id = PhotosLibrary.localIdentifier(fromCacheName: name) ?? PhotosLibrary.localIdentifier(fromCacheName: fallback) {
                identifiers.append(id)
            }
        }
        guard !identifiers.isEmpty else { return }
        if requestAccess, photos.authorization == .notDetermined { await photos.requestAccess() }
        guard photos.isAuthorized else { return }
        for id in identifiers {
            do { _ = try await photos.materialize(id) } catch {
                Log.media.error("re-materialize failed: \(errorText(error), privacy: .public)")
            }
        }
        let handle = self.handle
        let cache = AppEnvironment.mediaCacheDirectory.path
        _ = await Task.detached(priority: .userInitiated) { handle.relinkMissing(resolverDir: cache) }.value
        refresh()
        mediaVersion += 1
    }

    // MARK: Photos

    /// Materializes the Photos items, imports them and (optionally) inserts them at the playhead.
    func addFromPhotos(_ localIdentifiers: [String], insertAtPlayhead: Bool) async {
        guard !localIdentifiers.isEmpty else { return }
        isAddingMedia = true
        defer { isAddingMedia = false }
        var paths: [String] = []
        var failures: [String] = []
        for id in localIdentifiers {
            do {
                let cached = try await photos.materialize(id)
                let owned = try await Task.detached(priority: .userInitiated) {
                    try AppEnvironment.copyIntoOwnedMedia(cached)
                }.value
                paths.append(owned.path)
            } catch {
                failures.append(errorText(error))
                Log.media.error("materialize failed: \(errorText(error), privacy: .public)")
            }
        }
        if !failures.isEmpty { lastError = Array(Set(failures)).sorted().joined(separator: "\n") }
        await importAndPlace(paths, insertAtPlayhead: insertAtPlayhead)
    }

    // MARK: Files

    /// Copies Files-app items into FilmCraft's persistent Media folder (security scoped), then imports and places them.
    func addFiles(_ urls: [URL], insertAtPlayhead: Bool) async {
        guard !urls.isEmpty else { return }
        isAddingMedia = true
        defer { isAddingMedia = false }
        let copied: [String] = await Task.detached(priority: .userInitiated) {
            var paths: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let copy = try? AppEnvironment.copyIntoOwnedMedia(url) { paths.append(copy.path) }
            }
            return paths
        }.value
        if copied.count < urls.count { lastError = "Some files could not be copied into FilmCraft's Media folder." }
        await importAndPlace(copied, insertAtPlayhead: insertAtPlayhead)
    }

    // MARK: Import + place

    /// `file.import` for `paths`, then `timeline.place` at the playhead, as one undo step.
    private func importAndPlace(_ paths: [String], insertAtPlayhead: Bool) async {
        guard !paths.isEmpty else { return }
        // An open drag owns the engine's single interaction: adding media must not close it.
        guard !isDragging else {
            lastError = "Finish the current edit before adding media."
            return
        }
        // Partial failure: if the import succeeds but the placement fails, the media stays in the Project panel
        // (imported, not placed) and the error is shown.
        let historyBefore = state.historyId
        let handle = self.handle
        let playhead = state.playhead
        let hasSequence = state.sequenceName != nil
        let outcome: Result<[UInt64], Error> = await Task.detached(priority: .userInitiated) {
            do {
                try handle.beginInteraction(label: "Add Media")
                let ids: [UInt64]
                do {
                    ids = try handle.importFiles(paths: paths)
                    if insertAtPlayhead, hasSequence, !ids.isEmpty {
                        let json = EditorModel.encode(["items": ids, "time": playhead, "insert": true]) ?? "{}"
                        _ = try handle.execute(id: "timeline.place", paramsJson: json)
                    }
                } catch {
                    try? handle.endInteraction()
                    throw error
                }
                try handle.endInteraction()
                return .success(ids)
            } catch {
                return .failure(error)
            }
        }.value
        mediaVersion += 1
        refresh()
        if state.historyId != historyBefore { registerUndoStep(label: state.undoLabel) }
        requestFrame(at: state.playhead)
        switch outcome {
        case .success(let ids):
            Log.media.info("added \(ids.count, privacy: .public) media (insert: \(insertAtPlayhead, privacy: .public))")
        case .failure(let error):
            lastError = errorText(error)
            Log.media.error("add failed: \(errorText(error), privacy: .public)")
        }
    }
}
