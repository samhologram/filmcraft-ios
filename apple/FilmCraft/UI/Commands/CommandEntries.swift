import SwiftUI
@preconcurrency import FilmCraftKit

/// One command as the UI sees it: an engine command (journaled or query), a desktop UI-only command, a timeline tool
/// or a panel (Window menu).
struct CommandEntry: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let shortcut: String?
    let menu: [String]
    let isUI: Bool
    let isQuery: Bool
    /// The engine's params doc ("" for UI-only commands).
    let doc: String
}

/// Cached, flattened view of `CommandCatalog` (engine + UI-only + tools + panels) for menus and the palette.
@MainActor
enum UICommands {
    static var layout: [MenuSection] { CommandCatalog.shared.menus }

    static let entries: [CommandEntry] = {
        let cat = CommandCatalog.shared
        var out: [CommandEntry] = []
        var seen = Set<String>()
        for c in cat.commands where seen.insert(c.id).inserted {
            out.append(CommandEntry(id: c.id, label: c.label, shortcut: c.shortcut, menu: c.menu,
                                    isUI: false, isQuery: c.isQuery, doc: c.params))
        }
        for c in cat.uiCommands where seen.insert(c.id).inserted {
            out.append(CommandEntry(id: c.id, label: c.label, shortcut: c.shortcut, menu: c.menu,
                                    isUI: true, isQuery: false, doc: ""))
        }
        // Panels live in the Window menu: "window.panel.<Name>" is the id desktop menus use.
        for p in cat.panels {
            let id = windowCommandID(for: p.id)
            guard seen.insert(id).inserted else { continue }
            out.append(CommandEntry(id: id, label: p.title, shortcut: nil, menu: ["Window"], isUI: true, isQuery: false, doc: ""))
        }
        return out
    }()

    static let byID: [String: CommandEntry] = {
        var d: [String: CommandEntry] = [:]
        for e in entries where d[e.id] == nil { d[e.id] = e }
        return d
    }()

    /// "panel.effectControls" -> "window.panel.EffectControls".
    static func windowCommandID(for panelID: String) -> String {
        guard panelID.hasPrefix("panel.") else { return panelID }
        let name = String(panelID.dropFirst(6))
        guard let first = name.first else { return panelID }
        return "window.panel." + first.uppercased() + name.dropFirst()
    }

    /// Commands the platform cannot run (ios-excluded-commands.txt): hidden from menus, greyed in the palette.
    static func unsupportedReason(_ id: String) -> String? {
        CommandCatalog.shared.isExcludedOnIOS(id) ? (commandPlatformSupport(id: id) ?? "Not available on this device.") : nil
    }

    static func label(_ id: String) -> String { byID[id]?.label ?? CommandCatalog.shared.label(id) }

    /// Runs a catalog entry the way a menu item does: panels open in the UI, UI ids via `runUI`, engine ids via
    /// `present` (which opens the parameter sheet when the command needs input; queries always open the sheet so
    /// their result is visible).
    static func invoke(_ id: String, model: EditorModel) {
        let cat = CommandCatalog.shared
        if let panel = cat.resolvePanel(id) {
            uiOpenPanel(panel, model: model)
            return
        }
        if id.hasPrefix("tool.") {
            model.runUI(id)
            return
        }
        if let e = byID[id], e.isUI {
            model.runUI(id)
            return
        }
        if cat.isQuery(id) {
            model.pendingCommand = id
            return
        }
        model.present(id)
    }

    static func isEnabled(_ entry: CommandEntry, model: EditorModel) -> Bool {
        entry.isUI || model.isEnabled(entry.id)
    }
}
