import SwiftUI
import UIKit
@preconcurrency import FilmCraftKit

/// UI-only command ids (the desktop's `UI_COMMANDS`): tools, panels, playback, view and mode switches. The engine
/// never sees these; Swift handles them. Also the iOS replacements of desktop commands that need a file path.
extension EditorModel {
    // MARK: iOS overrides of engine commands

    /// Desktop commands whose desktop flow (native file dialogs, project paths) is replaced on iOS.
    /// Returns nil when `id` is not overridden.
    func runIOSOverride(_ id: String) -> Bool? {
        switch id {
        case "file.import":
            showMediaBrowser = true
            return true
        case "file.exportMedia":
            showExport = true
            return true
        default:
            return nil
        }
    }

    // MARK: UI ids

    nonisolated private static let links: [String: String] = [
        "help.discord": "https://discord.gg/artcraft",
        "help.website": "https://getartcraft.com",
        "help.appPage": "https://getartcraft.com/apps/filmcraft",
        "help.github": "https://github.com/storytold/filmcraft",
        "help.reportIssue": "https://github.com/storytold/filmcraft/issues",
    ]

    /// Workspace id -> words that identify its panel in the catalog.
    nonisolated private static let workspacePanels: [String: String] = [
        "window.workspace.color": "lumetri",
        "window.workspace.effects": "effects",
        "window.workspace.audio": "audio",
        "window.workspace.captionsandgraphics": "essentialgraphics",
        "window.workspace.editing": "project",
        "window.workspace.assembly": "project",
    ]

    /// True when `runUI` handles the id (menus hide the other desktop UI commands).
    nonisolated static func implementsUI(_ id: String) -> Bool {
        if id.hasPrefix("tool.") || id.hasPrefix("panel.") || id.hasPrefix("window.panel.") { return true }
        if workspacePanels[id] != nil || id == "window.workspace.allpanels" || id == "window.workspace.reset" { return true }
        if links[id] != nil { return true }
        switch id {
        case "playback.toggle", "playback.forward", "playback.stop", "playback.inToOut",
             "view.zoomIn", "view.zoomOut", "view.zoomToSequence",
             "mode.import", "mode.edit", "mode.export":
            return true
        default:
            return false
        }
    }

    /// Runs a UI-only id. Unknown ids set `lastError`.
    @discardableResult
    func runUI(_ id: String) -> Bool {
        let catalog = CommandCatalog.shared
        if id.hasPrefix("tool.") {
            guard catalog.tool(id) != nil else {
                lastError = "Unknown tool: \(id)"
                return false
            }
            activeTool = id
            Log.command.info("tool: \(id, privacy: .public)")
            return true
        }
        if let panel = catalog.resolvePanel(id) {
            activePanel = panel
            inspectorVisible = true
            Log.command.info("panel: \(panel, privacy: .public)")
            return true
        }
        if id.hasPrefix("panel.") || id.hasPrefix("window.panel.") {
            lastError = "Unknown panel: \(id)"
            return false
        }
        if let url = Self.links[id].flatMap(URL.init(string:)) {
            UIApplication.shared.open(url)
            return true
        }
        if id.hasPrefix("window.workspace.") {
            return applyWorkspace(id)
        }
        switch id {
        case "playback.toggle":
            togglePlay()
        case "playback.forward":
            if !isPlaying { togglePlay() }
        case "playback.stop":
            if isPlaying { togglePlay() }
        case "playback.inToOut":
            playInToOut()
        case "view.zoomIn":
            pixelsPerSecond *= 1.25
        case "view.zoomOut":
            pixelsPerSecond /= 1.25
        case "view.zoomToSequence":
            zoomToSequence()
        case "mode.import":
            showMediaBrowser = true
        case "mode.export":
            showExport = true
        case "mode.edit":
            showMediaBrowser = false
            showExport = false
        default:
            lastError = "\"\(catalog.label(id))\" (\(id)) is not available on this device."
            Log.command.error("unknown UI command: \(id, privacy: .public)")
            return false
        }
        return true
    }

    private func applyWorkspace(_ id: String) -> Bool {
        let catalog = CommandCatalog.shared
        switch id {
        case "window.workspace.allpanels", "window.workspace.reset":
            activePanel = nil
            inspectorVisible = true
            return true
        default:
            guard let word = Self.workspacePanels[id] else {
                lastError = "Unknown workspace: \(id)"
                return false
            }
            activePanel = catalog.panels.first { $0.id.lowercased().contains(word) }?.id
            inspectorVisible = activePanel != nil
            return true
        }
    }

    /// Whether a UI-only id can run right now.
    func uiEnabled(_ id: String) -> Bool {
        switch id {
        case "playback.toggle", "playback.forward", "playback.inToOut": return state.duration > 0
        case "playback.stop": return isPlaying
        case "view.zoomIn", "view.zoomOut", "view.zoomToSequence": return state.sequenceName != nil
        default: return Self.implementsUI(id)
        }
    }

    // MARK: Timeline zoom

    func zoomToSequence() {
        let seconds = Timecode.seconds(state.duration)
        guard seconds > 0, timelineViewportWidth > 0 else { return }
        pixelsPerSecond = timelineViewportWidth * 0.9 / seconds
    }

    /// Plays from the in point to the out point (or the whole sequence when none are set), then stops.
    func playInToOut() {
        let start = state.inPoint ?? 0
        guard state.duration > 0 else { return }
        seek(start)
        playback.stopTick = state.outPoint
        if !isPlaying { togglePlay() }
    }
}
