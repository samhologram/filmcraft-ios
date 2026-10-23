import SwiftUI
import Observation
import UIKit
@preconcurrency import FilmCraftKit

/// An immutable image that may cross actors (a `CGImage` never changes after creation).
struct SendableImage: @unchecked Sendable {
    let image: CGImage
}

/// Editor state of one open project: mirrors the engine (`ProjectHandle`) for SwiftUI, runs commands by id,
/// registers engine history on the scene's `UndoManager`, and owns playback, media and export.
@MainActor @Observable
final class EditorModel {
    /// The thread-safe engine object. Background work (rendering, mixing, import, export) calls it directly.
    @ObservationIgnored let handle: ProjectHandle

    // MARK: Engine mirror (refreshed after every call)
    var state: ProjectState
    var timeline: TimelineSnapshot
    var media: [MediaInfo]

    // MARK: UI state shared by Core and UI
    /// "tool.selection" ... (`ToolInfo.id`).
    var activeTool: String = "tool.selection"
    /// "panel.effectControls" ... (`PanelInfo.id`) shown in the inspector / sheet.
    var activePanel: String?
    var isPlaying = false
    /// Timeline zoom.
    var pixelsPerSecond: Double = 80 { didSet { pixelsPerSecond = Self.clampZoom(pixelsPerSecond) } }
    /// Width of the timeline viewport in points; published by the timeline for `view.zoomToSequence`.
    var timelineViewportWidth: Double = 0
    /// Shown as an alert with the full message.
    var lastError: String?
    /// True after the first program frame rendered (demo mode only; UI tests wait for `demoReady`).
    var isDemoReady = false
    /// A command that needs parameters; the UI shows a `CommandSheet`.
    var pendingCommand: String?
    var showCommandPalette = false
    var showMediaBrowser = false
    var showExport = false
    var inspectorVisible = true { didSet { UserDefaults.standard.set(inspectorVisible, forKey: "inspectorVisible") } }
    /// Latest rendered program frame.
    var programFrame: CGImage?
    /// Bumps on undo/redo so views re-render.
    var undoRedoTick = 0
    @ObservationIgnored weak var undoManager: UndoManager?

    // MARK: Viewer sizing (published by the viewer: points and screen scale)
    var viewerSize: CGSize = .zero
    var viewerScale: CGFloat = 2

    // MARK: Media / export state
    /// True while Photos or Files media is being materialized, imported and placed.
    var isAddingMedia = false
    /// Bumps when media may have changed on disk (relink), keying thumbnail caches.
    var mediaVersion = 0
    /// 0...1 while an export runs; nil when idle.
    var exportProgress: Double?
    /// Short status of the last export ("Saved to Photos", an error message...), nil when none.
    var exportMessage: String?
    var isExporting: Bool { exportProgress != nil }

    // MARK: Internals shared with the extensions
    @ObservationIgnored var dragHistoryStart: UInt64 = 0
    @ObservationIgnored var didBootstrap = false
    @ObservationIgnored private(set) var isDragging = false
    @ObservationIgnored var pendingFrameTick: Int64?
    @ObservationIgnored var frameRenderBusy = false
    @ObservationIgnored var framesRendered = 0
    @ObservationIgnored var playbackEngine: PlaybackEngine?
    @ObservationIgnored var exportJob: UInt64?
    @ObservationIgnored var exportTask: Task<Void, Never>?
    @ObservationIgnored var enabledCache: [String: Bool] = [:]
    @ObservationIgnored var enabledCacheRevision: UInt64 = .max
    @ObservationIgnored let thumbCache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 600
        return cache
    }()
    @ObservationIgnored let photos: PhotosLibrary

    init(handle: ProjectHandle, photos: PhotosLibrary? = nil) {
        self.handle = handle
        self.photos = photos ?? AppEnvironment.shared.photos
        state = handle.state()
        timeline = handle.timeline()
        media = handle.media()
        inspectorVisible = UserDefaults.standard.object(forKey: "inspectorVisible") as? Bool ?? true
    }

    nonisolated static func clampZoom(_ value: Double) -> Double {
        guard value.isFinite else { return 80 }
        return min(max(value, 2), 4000)
    }

    // MARK: Refresh

    /// Re-reads everything the UI shows. Call after every engine call.
    func refresh() {
        state = handle.state()
        timeline = handle.timeline()
        media = handle.media()
    }

    /// Cheap refresh for playback ticks and scrubbing: the project state only.
    func refreshLight() {
        state = handle.state()
    }

    // MARK: Running commands

    /// Executes an engine command and returns its result JSON object; errors go to `lastError`.
    /// Refreshes the mirror and registers undo. Use `run` unless the result is needed.
    @discardableResult
    func execute(_ id: String, _ params: [String: Any] = [:]) -> [String: Any]? {
        guard let json = Self.encode(params) else {
            lastError = "Could not encode the parameters of \(id)."
            return nil
        }
        let historyBefore = state.historyId
        let result: String
        do {
            result = try handle.execute(id: id, paramsJson: json)
        } catch {
            let text = errorText(error)
            Log.command.error("command failed: \(id, privacy: .public): \(text, privacy: .public)")
            lastError = text
            refresh()
            return nil
        }
        Log.command.info("command ran: \(id, privacy: .public)")
        finishMutation(id: id, historyBefore: historyBefore)
        return Self.decodeObject(result) ?? [:]
    }

    /// Runs an engine command (or a UI-only / undo id) by id. Returns false when it failed.
    @discardableResult
    func run(_ id: String, _ params: [String: Any] = [:]) -> Bool {
        switch id {
        case "edit.undo": undo(); return true
        case "edit.redo": redo(); return true
        default: break
        }
        if let overridden = runIOSOverride(id) { return overridden }
        if CommandCatalog.shared.isUI(id) {
            return runUI(id)
        }
        return execute(id, params) != nil
    }

    /// After an engine call: refresh, mirror a new history step on the UndoManager, redraw the program frame.
    func finishMutation(id: String?, historyBefore: UInt64) {
        refresh()
        if let id, CommandCatalog.shared.isQuery(id) { return }
        // During an interaction (beginDrag...endDrag) the single registration happens in endDrag.
        if !isDragging, state.historyId != historyBefore { registerUndoStep(label: state.undoLabel) }
        requestFrame(at: state.playhead)
    }

    func isEnabled(_ id: String) -> Bool {
        // Reading these makes SwiftUI re-evaluate menus and buttons when the project changes.
        _ = undoRedoTick
        let revision = state.revision
        _ = state.canUndo
        if enabledCacheRevision != revision {
            enabledCache.removeAll(keepingCapacity: true)
            enabledCacheRevision = revision
        }
        if let cached = enabledCache[id] { return cached }
        let value = computeEnabled(id)
        enabledCache[id] = value
        return value
    }

    private func computeEnabled(_ id: String) -> Bool {
        switch id {
        case "edit.undo": return state.canUndo
        case "edit.redo": return state.canRedo
        case "file.import": return true
        case "file.exportMedia": return state.sequenceName != nil
        default: break
        }
        let catalog = CommandCatalog.shared
        if catalog.isUI(id) { return uiEnabled(id) }
        return handle.disabledReason(id: id) == nil
    }

    /// Runs the command directly, or asks for its required parameters first (`pendingCommand`).
    func present(_ id: String) {
        if id == "edit.undo" || id == "edit.redo" { _ = run(id); return }
        if runIOSOverride(id) != nil { return }
        let catalog = CommandCatalog.shared
        if catalog.isUI(id) { _ = runUI(id); return }
        if !catalog.requiredParams(id).isEmpty {
            pendingCommand = id
        } else {
            run(id)
        }
    }

    // MARK: Interactive edits (drags)

    /// Opens an interaction: every edit until `endDrag` is one undo step.
    func beginDrag(_ label: String) {
        guard !isDragging, !isAddingMedia else { return }
        dragHistoryStart = handle.state().historyId
        do {
            try handle.beginInteraction(label: label)
            isDragging = true
        } catch {
            lastError = errorText(error)
        }
    }

    func endDrag() {
        guard isDragging else { return }
        isDragging = false
        do {
            try handle.endInteraction()
        } catch {
            lastError = errorText(error)
        }
        refresh()
        if state.historyId != dragHistoryStart { registerUndoStep(label: state.undoLabel) }
        requestFrame(at: state.playhead)
    }

    func selectClip(_ id: UInt64, extend: Bool) {
        run("timeline.select", ["clips": [id], "add": extend])
    }

    // MARK: JSON

    nonisolated static func encode(_ params: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(params),
              let data = try? JSONSerialization.data(withJSONObject: params),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    nonisolated static func decodeObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
