import SwiftUI
@preconcurrency import FilmCraftKit

/// Undo / redo buttons for toolbars (`command.edit.undo`, `command.edit.redo`).
struct UndoRedoButtons: View {
    let model: EditorModel

    var body: some View {
        // `undoRedoTick` is read so the buttons re-render when the history moves.
        let _ = model.undoRedoTick
        Button {
            model.undo()
        } label: {
            Label("Undo", systemImage: "arrow.uturn.backward")
        }
        .disabled(!model.state.canUndo)
        .accessibilityIdentifier("command.edit.undo")
        Button {
            model.redo()
        } label: {
            Label("Redo", systemImage: "arrow.uturn.forward")
        }
        .disabled(!model.state.canRedo)
        .accessibilityIdentifier("command.edit.redo")
    }
}

/// The tool picker as a toolbar menu (`tool.<id>` items).
struct ToolbarToolMenu: View {
    let model: EditorModel

    var body: some View {
        Menu {
            ForEach(CommandCatalog.shared.tools, id: \.id) { tool in
                Button {
                    model.runUI(tool.id)
                } label: {
                    if model.activeTool == tool.id {
                        Label(ToolUI.title(tool.id), systemImage: "checkmark")
                    } else {
                        Label(ToolUI.title(tool.id), systemImage: ToolUI.symbol(tool.id))
                    }
                }
                .accessibilityIdentifier(tool.id)
                .accessibilityAddTraits(model.activeTool == tool.id ? .isSelected : [])
            }
        } label: {
            Label(ToolUI.title(model.activeTool), systemImage: ToolUI.symbol(model.activeTool))
        }
        .accessibilityIdentifier("menu.tools")
    }
}

/// Share (export) button: opens the export sheet.
struct ShareButton: View {
    let model: EditorModel

    var body: some View {
        Button {
            model.showExport = true
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .disabled(model.state.sequenceName == nil)
        .accessibilityIdentifier("export")
    }
}

/// Opens the command palette.
struct PaletteButton: View {
    let model: EditorModel

    var body: some View {
        Button {
            model.showCommandPalette = true
        } label: {
            Label("Command Palette", systemImage: "magnifyingglass")
        }
        .accessibilityIdentifier("paletteOpen")
    }
}

/// The single toolbar control for the panel dock on a wide iPad and the panel sheet in compact layouts.
struct PanelVisibilityButton: View {
    let model: EditorModel
    let usesDock: Bool

    private var isShowing: Bool {
        usesDock ? model.inspectorVisible : (model.inspectorVisible && model.activePanel != nil)
    }

    var body: some View {
        Button {
            if isShowing {
                model.inspectorVisible = false
            } else if usesDock {
                // The dock restores its scene layout and reveals the selected group when it remounts.
                model.inspectorVisible = true
            } else {
                uiOpenPanel(model.activePanel ?? "panel.project", model: model)
            }
        } label: {
            Label(isShowing ? "Hide Panels" : "Show Panels", systemImage: "sidebar.leading")
        }
        .accessibilityIdentifier("toggleInspector")
    }
}

/// Opens the media browser sheet (Photos and Files).
struct AddMediaButton: View {
    let model: EditorModel

    var body: some View {
        Button {
            model.showMediaBrowser = true
        } label: {
            Label("Add Media", systemImage: "plus.rectangle.on.folder")
        }
        .accessibilityIdentifier("addMedia")
    }
}

/// The "…" overflow menu: the desktop's menus, generated from the catalog.
struct OverflowMenu: View {
    let model: EditorModel
    var includesPanels = false

    var body: some View {
        Menu {
            if includesPanels {
                Menu("Panels") {
                    ForEach(PanelUI.primary, id: \.self) { id in
                        Button {
                            uiOpenPanel(id, model: model)
                        } label: {
                            Label(PanelUI.title(id), systemImage: PanelUI.symbol(id))
                        }
                        .accessibilityIdentifier(id)
                    }
                    Divider()
                    ForEach(PanelUI.morePanels(), id: \.id) { p in
                        Button {
                            uiOpenPanel(p.id, model: model)
                        } label: {
                            Label(p.title, systemImage: PanelUI.symbol(p.id))
                        }
                        .accessibilityIdentifier(p.id)
                    }
                }
                .accessibilityIdentifier("menu.panels")
                Divider()
            }
            DesktopMenus(model: model)
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("menu.more")
    }
}
