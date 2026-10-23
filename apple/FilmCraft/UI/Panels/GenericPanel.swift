import SwiftUI
@preconcurrency import FilmCraftKit

/// A panel without bespoke UI: the commands that belong to it, taken from the generated catalog (never empty).
/// Each row runs the command (or opens its parameter sheet) from `command.<id>`.
struct GenericPanel: View {
    let model: EditorModel
    let panelID: String

    /// Engine command-id prefixes (and exact ids) that make up each desktop panel.
    private static let prefixes: [String: [String]] = [
        "panel.lumetriColor": ["lumetri.", "color.", "sequence.colorSettings", "clip.interpretFootage"],
        "panel.lumetriScopes": ["scopes."],
        "panel.essentialGraphics": ["graphics."],
        "panel.essentialSound": ["essentialSound."],
        "panel.audioClipMixer": ["clipMixer.", "clip.audio"],
        "panel.audioTrackMixer": ["mixer."],
        "panel.audioMeters": ["mixer.", "audio."],
        "panel.markers": ["markers."],
        "panel.history": ["history.", "edit.undo", "edit.redo"],
        "panel.textToSpeech": ["tts.", "narration."],
        "panel.text": ["captions."],
        "panel.mediaBrowser": ["mediaBrowser.", "media."],
        "panel.libraries": ["libraries.", "graphics.template."],
        "panel.info": ["metadata.", "project.inspect", "sequence.inspect"],
        "panel.metadata": ["metadata."],
        "panel.properties": ["clip.", "sequence.inspect"],
        "panel.events": ["events."],
        "panel.progress": ["jobs.", "perf."],
        "panel.source": ["source."],
        "panel.referenceMonitor": ["view.compare."],
        "panel.timecode": ["playhead."],
        "panel.projectNotes": ["project."],
    ]

    private struct Row: Identifiable {
        let entry: CommandEntry
        var id: String { entry.id }
    }

    private var rows: [Row] {
        let wanted = Self.prefixes[panelID] ?? []
        var out: [CommandEntry] = []
        if !wanted.isEmpty {
            out = UICommands.entries.filter { e in
                !e.isUI && UICommands.unsupportedReason(e.id) == nil && wanted.contains { e.id.hasPrefix($0) || e.id == $0 }
            }
        }
        if out.isEmpty {
            // Fall back to commands whose label shares a word with the panel's title.
            let words = PanelUI.title(panelID).lowercased().split(separator: " ").map(String.init).filter { $0.count > 2 }
            out = UICommands.entries.filter { e in
                !e.isUI && UICommands.unsupportedReason(e.id) == nil
                    && (words.contains { e.label.lowercased().contains($0) } || e.menu.contains { m in words.contains { m.lowercased().contains($0) } })
            }
        }
        if out.isEmpty {
            // Last resort: the desktop's Edit menu, so the panel is never empty.
            out = UICommands.entries.filter { !$0.isUI && $0.menu.first == "Edit" && UICommands.unsupportedReason($0.id) == nil }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }.prefix(300).map(Row.init)
    }

    var body: some View {
        let list = rows
        let title = PanelUI.title(panelID)
        List {
            Section {
                ForEach(list) { row in
                    CommandRow(model: model, entry: row.entry)
                }
            } header: {
                Text(verbatim: title)
            } footer: {
                Text("Commands for this panel. Parameters open in a form.")
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("panelCommands")
    }
}

/// A row for one catalog command: label, menu path, the engine's reason when it is disabled.
struct CommandRow: View {
    let model: EditorModel
    let entry: CommandEntry

    var body: some View {
        let enabled = UICommands.isEnabled(entry, model: model)
        Button {
            UICommands.invoke(entry.id, model: model)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: entry.label)
                        .foregroundStyle(enabled ? Color.primary : Color.secondary)
                        .lineLimit(2)
                    if !entry.menu.isEmpty {
                        Text(verbatim: entry.menu.joined(separator: " \u{203A} "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let sc = entry.shortcut {
                    Text(verbatim: CommandCatalog.display(sc)).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(!enabled)
        .accessibilityIdentifier("command.\(entry.id)")
    }
}
