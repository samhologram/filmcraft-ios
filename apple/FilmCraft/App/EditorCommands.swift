import SwiftUI

// iPadOS menu bar, generated from the desktop menu layout (`desktopMenuLayout()`), in desktop order:
// File, Edit, Clip, Sequence, Markers, Graphics and Titles, View, Window, Help.
// File / Edit / View / Window / Help extend the system menus; Clip, Sequence, Markers and Graphics and Titles are
// custom menus (the system places custom menus after View, so View precedes them here, unlike the desktop).
// Every item acts on the focused scene's model (`@FocusedValue(\.editorModel)`) and carries `command.<id>` as its
// accessibility identifier.

// MARK: - Layout

/// One entry of a generated menu.
struct LayoutEntry: Identifiable {
    enum Kind {
        case command(String)
        case separator
        case submenu(String, [String])
    }

    let id: Int
    let kind: Kind
}

@MainActor
enum MenuLayout {
    /// Desktop commands that have no meaning in a document app (the system owns open / save / quit).
    private static let hidden: Set<String> = [
        "file.save", "file.saveAs", "file.saveCopy", "file.revert", "file.open", "file.recover", "file.discardRecovery",
        "file.autoSaveNow", "file.newProject", "file.openDemoProject", "file.close", "file.closeProject", "app.quit",
    ]
    private static let last: Set<String> = ["app.quit"]
    /// Shortcuts the system or the document scene already uses.
    private static let reserved: Set<String> = [
        "cmd+n", "cmd+o", "cmd+w", "cmd+q", "cmd+h", "cmd+m", "cmd+p", "cmd+s", "cmd+c", "cmd+x", "cmd+v", "cmd+a",
        "cmd+z", "cmd+shift+z", "cmd+,",
    ]

    /// A command shows in a menu when this platform can run it.
    static func isVisible(_ id: String) -> Bool {
        let catalog = CommandCatalog.shared
        guard catalog.isKnown(id), !hidden.contains(id) else { return false }
        return catalog.isUI(id) ? EditorModel.implementsUI(id) : !catalog.isExcludedOnIOS(id)
    }

    /// Menu entries of the top-level menu `title`, in desktop order, without `skipping` ids.
    static func entries(for title: String, skipping: Set<String> = []) -> [LayoutEntry] {
        let catalog = CommandCatalog.shared
        guard let section = catalog.menus.first(where: { $0.title == title }) else { return [] }
        var items: [LayoutEntry.Kind] = []
        var used = Set<String>(skipping)
        for slot in section.items {
            if slot == "---" {
                items.append(.separator)
            } else if slot.hasPrefix("@") {
                let name = String(slot.dropFirst())
                let path = [title] + name.split(separator: "/").map(String.init)
                let ids = catalog.commandIDs(menuPath: path).filter { isVisible($0) && !skipping.contains($0) && !used.contains($0) }
                if !ids.isEmpty {
                    used.formUnion(ids)
                    items.append(.submenu(path.last ?? name, ids))
                }
            } else if !used.contains(slot), isVisible(slot), !last.contains(slot) {
                used.insert(slot)
                items.append(.command(slot))
            }
        }
        return tidy(items).enumerated().map { LayoutEntry(id: $0.offset, kind: $0.element) }
    }

    /// Drops leading, trailing and doubled separators.
    private static func tidy(_ items: [LayoutEntry.Kind]) -> [LayoutEntry.Kind] {
        var out: [LayoutEntry.Kind] = []
        for item in items {
            if case .separator = item {
                if out.isEmpty { continue }
                if case .separator = out[out.count - 1] { continue }
            }
            out.append(item)
        }
        while let tail = out.last, case .separator = tail { out.removeLast() }
        return out
    }

    /// Keyboard shortcuts by command id: the first command to ask for a combination gets it. Combinations the
    /// system owns, and keys without Command / Control / Option (those are the editor's hidden key commands and
    /// would steal typing), are never taken.
    static let shortcuts: [String: KeyboardShortcut] = {
        var out: [String: KeyboardShortcut] = [:]
        var taken = reserved
        let catalog = CommandCatalog.shared
        var ids: [String] = []
        for section in catalog.menus { ids.append(contentsOf: section.items.filter { !$0.hasPrefix("@") && $0 != "---" }) }
        ids.append(contentsOf: catalog.commands.map(\.id))
        for id in ids where out[id] == nil && isVisible(id) {
            guard let shortcut = catalog.shortcut(id) else { continue }
            guard !shortcut.modifiers.isDisjoint(with: [.command, .control, .option]) else { continue }
            let name = systemName(shortcut)
            if taken.contains(name) { continue }
            taken.insert(name)
            out[id] = shortcut
        }
        return out
    }()

    private static func systemName(_ s: KeyboardShortcut) -> String {
        var name = ""
        if s.modifiers.contains(.command) { name += "cmd+" }
        if s.modifiers.contains(.control) { name += "ctrl+" }
        if s.modifiers.contains(.option) { name += "alt+" }
        if s.modifiers.contains(.shift) { name += "shift+" }
        return name + String(s.key.character)
    }
}

// MARK: - Menu items

/// One catalog command as a menu button.
struct CommandMenuItem: View {
    let model: EditorModel?
    let id: String

    var body: some View {
        let button = Button(CommandCatalog.shared.label(id)) { model?.present(id) }
            .disabled(!(model?.isEnabled(id) ?? false))
            .accessibilityIdentifier("command.\(id)")
        if let shortcut = MenuLayout.shortcuts[id] {
            button.keyboardShortcut(shortcut)
        } else {
            button
        }
    }
}

/// The entries of one generated menu (the content of a `CommandGroup` / `CommandMenu`).
struct MenuEntries: View {
    let model: EditorModel?
    let entries: [LayoutEntry]

    var body: some View {
        ForEach(entries) { entry in
            switch entry.kind {
            case .command(let id):
                CommandMenuItem(model: model, id: id)
            case .separator:
                Divider()
            case .submenu(let name, let ids):
                Menu(name) {
                    ForEach(ids, id: \.self) { CommandMenuItem(model: model, id: $0) }
                }
            }
        }
    }
}

// MARK: - Commands

struct EditorCommands: Commands {
    @FocusedValue(\.editorModel) private var model

    private var undoTitle: String {
        guard let label = model?.state.undoLabel, !label.isEmpty else { return String(localized: "Undo") }
        return String(localized: "Undo") + " " + label
    }

    private var redoTitle: String {
        guard let label = model?.state.redoLabel, !label.isEmpty else { return String(localized: "Redo") }
        return String(localized: "Redo") + " " + label
    }

    // A commands builder takes at most 10 items, so the body is split in groups.
    var body: some Commands {
        fileCommands
        editCommands
        viewCommands
        clipMenu
        sequenceMenu
        markersMenu
        graphicsMenu
        windowAndHelpCommands
    }

    @CommandsBuilder private var fileCommands: some Commands {
        CommandGroup(after: .newItem) {
            MenuEntries(model: model, entries: MenuLayout.entries(for: "File"))
        }
    }

    @CommandsBuilder private var editCommands: some Commands {
        // edit.undo / edit.redo replace the system group; they go through the engine history (UndoManager mirror).
        CommandGroup(replacing: .undoRedo) {
            Button(undoTitle) { model?.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!(model?.state.canUndo ?? false))
                .accessibilityIdentifier("command.edit.undo")
            Button(redoTitle) { model?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!(model?.state.canRedo ?? false))
                .accessibilityIdentifier("command.edit.redo")
        }
        CommandGroup(after: .pasteboard) {
            MenuEntries(model: model, entries: MenuLayout.entries(for: "Edit", skipping: ["edit.undo", "edit.redo"]))
        }
    }

    @CommandsBuilder private var viewCommands: some Commands {
        CommandGroup(after: .toolbar) {
            MenuEntries(model: model, entries: MenuLayout.entries(for: "View"))
        }
    }

    @CommandsBuilder private var clipMenu: some Commands {
        CommandMenu("Clip") { menuBody("Clip") }
    }

    @CommandsBuilder private var sequenceMenu: some Commands {
        CommandMenu("Sequence") { menuBody("Sequence") }
    }

    @CommandsBuilder private var markersMenu: some Commands {
        CommandMenu("Markers") { menuBody("Markers") }
    }

    @CommandsBuilder private var graphicsMenu: some Commands {
        CommandMenu("Graphics and Titles") { menuBody("Graphics and Titles") }
    }

    @CommandsBuilder private var windowAndHelpCommands: some Commands {
        CommandGroup(after: .windowArrangement) {
            MenuEntries(model: model, entries: MenuLayout.entries(for: "Window"))
        }
        CommandGroup(after: .help) {
            MenuEntries(model: model, entries: MenuLayout.entries(for: "Help"))
        }
    }

    @ViewBuilder private func menuBody(_ title: String) -> some View {
        let entries = MenuLayout.entries(for: title)
        if entries.isEmpty {
            Text("No Commands")
        } else {
            MenuEntries(model: model, entries: entries)
        }
    }
}
