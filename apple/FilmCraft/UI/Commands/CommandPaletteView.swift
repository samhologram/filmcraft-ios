import SwiftUI
@preconcurrency import FilmCraftKit

/// Searchable list of every engine and UI command (`palette`, rows `command.<id>`). Disabled commands are greyed
/// with the engine's reason; choosing one closes the palette and runs it (or opens its parameter sheet).
struct CommandPaletteView: View {
    let model: EditorModel
    /// Called with the chosen command id; the host invokes it after the palette has finished dismissing.
    var onChoose: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private struct PaletteGroup: Identifiable {
        let title: String
        let rows: [CommandEntry]
        var id: String { title }
    }

    private var tokens: [String] {
        query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private var results: [CommandEntry] {
        let terms = tokens
        guard !terms.isEmpty else { return [] }
        var scored: [(entry: CommandEntry, score: Int)] = []
        for e in UICommands.entries {
            let label = e.label.lowercased()
            let path = e.menu.joined(separator: " ").lowercased()
            let id = e.id.lowercased()
            var score = 0
            var matched = true
            for t in terms {
                if label.hasPrefix(t) { score += 40 }
                else if label.contains(" " + t) { score += 30 }
                else if label.contains(t) { score += 20 }
                else if path.contains(t) { score += 10 }
                else if id.contains(t) { score += 5 }
                else { matched = false; break }
            }
            if matched { scored.append((e, score)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.entry.label < $1.entry.label }
        return scored.prefix(200).map(\.entry)
    }

    private var groups: [PaletteGroup] {
        var order: [String] = []
        var buckets: [String: [CommandEntry]] = [:]
        for e in UICommands.entries {
            let title = e.menu.first ?? "Other Commands"
            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(e)
        }
        let menuOrder = UICommands.layout.map(\.title)
        let known = menuOrder.filter { buckets[$0] != nil }
        let rest = order.filter { !menuOrder.contains($0) }
        return (known + rest).map { PaletteGroup(title: $0, rows: buckets[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                if tokens.isEmpty {
                    ForEach(groups) { group in
                        Section(group.title) {
                            ForEach(group.rows) { row in PaletteRow(model: model, entry: row) { choose(row) } }
                        }
                    }
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ForEach(results) { row in PaletteRow(model: model, entry: row) { choose(row) } }
                }
            }
            .listStyle(.plain)
            .accessibilityIdentifier("palette")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search commands"))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationTitle("Command Palette")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { close() }
                        .accessibilityIdentifier("paletteDone")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func close() {
        model.showCommandPalette = false
        dismiss()
    }

    /// Close the palette; the host runs the command from the sheet's `onDismiss` (presenting its parameter sheet
    /// straight away would collide with the dismissal, and a timer would be racy).
    private func choose(_ entry: CommandEntry) {
        onChoose(entry.id)
        close()
    }
}

private struct PaletteRow: View {
    let model: EditorModel
    let entry: CommandEntry
    let action: () -> Void

    private var reason: String? {
        if let r = UICommands.unsupportedReason(entry.id) { return r }
        return entry.isUI ? nil : model.handle.disabledReason(id: entry.id)
    }

    var body: some View {
        let why = reason
        Button(action: action) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: entry.label)
                        .foregroundStyle(why == nil ? Color.primary : Color.secondary)
                    Text(verbatim: entry.menu.isEmpty ? entry.id : entry.menu.joined(separator: " \u{203A} "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let why {
                        Text(verbatim: why)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 8)
                if let shortcut = entry.shortcut {
                    Text(verbatim: CommandCatalog.display(shortcut))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(why != nil)
        .accessibilityIdentifier("command.\(entry.id)")
    }
}
