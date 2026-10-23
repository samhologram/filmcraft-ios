import SwiftUI
@preconcurrency import FilmCraftKit

/// The edit bar under the viewer: split at the playhead, delete, ripple delete, add marker, undo, redo, and (iPhone)
/// the tool menu. Denser as it gets narrower, then scrolls; nothing falls off screen.
struct EditBar: View {
    let model: EditorModel
    /// iPad shows undo/redo in the toolbar instead (one `command.edit.undo` per screen).
    var includesUndo = true
    var includesTools = false

    private struct Action: Identifiable {
        let id: String
        let label: LocalizedStringKey
        let symbol: String
        let enabled: Bool
        let run: () -> Void
    }

    private var actions: [Action] {
        var list: [Action] = [
            Action(id: "sequence.addEdit", label: "Split", symbol: "scissors",
                   enabled: model.isEnabled("sequence.addEdit") || model.isEnabled("sequence.addEditAllTracks"),
                   run: split),
            Action(id: "edit.clear", label: "Delete", symbol: "trash",
                   enabled: model.isEnabled("edit.clear"), run: { model.run("edit.clear") }),
            Action(id: "edit.rippleDelete", label: "Ripple", symbol: "rectangle.compress.vertical",
                   enabled: model.isEnabled("edit.rippleDelete"), run: { model.run("edit.rippleDelete") }),
            Action(id: "markers.add", label: "Marker", symbol: "flag",
                   enabled: model.isEnabled("markers.add"), run: { model.run("markers.add") }),
        ]
        if includesUndo {
            list.append(Action(id: "edit.undo", label: "Undo", symbol: "arrow.uturn.backward",
                               enabled: model.state.canUndo, run: { model.undo() }))
            list.append(Action(id: "edit.redo", label: "Redo", symbol: "arrow.uturn.forward",
                               enabled: model.state.canRedo, run: { model.redo() }))
        }
        return list
    }

    /// Cut the selected clips under the playhead; with none selected there, cut every track (as a razor across).
    private func split() {
        let selected = Set(model.state.selectedClips)
        let t = model.state.playhead
        let cutsSelection = model.timeline.tracks.contains { track in
            track.clips.contains { selected.contains($0.id) && $0.start < t && t < $0.end }
        }
        model.run(cutsSelection ? "sequence.addEdit" : "sequence.addEditAllTracks")
    }

    var body: some View {
        // `undoRedoTick` is read so the buttons re-render when the history moves.
        let _ = model.undoRedoTick
        ViewThatFits(in: .horizontal) {
            row(labels: true)
            row(labels: false)
            ScrollView(.horizontal) { row(labels: false) }
                .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity)
    }

    private func row(labels: Bool) -> some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                if includesTools { ToolMenu(model: model) }
                ForEach(actions) { a in
                    Button(action: a.run) {
                        if labels {
                            VStack(spacing: 1) {
                                Image(systemName: a.symbol).font(.body)
                                Text(a.label).font(.caption2).lineLimit(1)
                            }
                            .frame(minWidth: 48, minHeight: 36)
                        } else {
                            Image(systemName: a.symbol)
                                .font(.body)
                                .frame(width: 34, height: 32)
                        }
                    }
                    .buttonStyle(.glass)
                    .disabled(!a.enabled)
                    .accessibilityLabel(Text(a.label))
                    .accessibilityIdentifier("command.\(a.id)")
                }
            }
            .padding(.horizontal, 8)
        }
    }
}

/// The tool picker: every tool from `timeline_tools()` (`tool.<id>`), the current one on the button.
struct ToolMenu: View {
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
            Image(systemName: ToolUI.symbol(model.activeTool))
                .font(.body)
                .frame(width: 34, height: 32)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .accessibilityLabel("Tool: \(ToolUI.title(model.activeTool))")
        .accessibilityIdentifier("menu.tools")
    }
}
