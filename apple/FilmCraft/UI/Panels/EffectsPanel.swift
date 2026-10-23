import SwiftUI
@preconcurrency import FilmCraftKit

/// The Effects panel: the engine's effect and transition catalog, searchable; tapping a row applies it to the
/// selected clips (transitions to the selected clip's edge or the edit at the playhead).
struct EffectsPanel: View {
    let model: EditorModel

    @State private var query = ""
    @State private var kind = "Video"
    @State private var ready = false

    private var kinds: [(id: String, title: LocalizedStringKey)] {[
        ("Video", "Video Effects"), ("Audio", "Audio Effects"),
        ("VideoTransition", "Video Transitions"), ("AudioTransition", "Audio Transitions"),
    ]}

    private var selected: [UInt64] { model.state.selectedClips }

    private struct EffectGroup: Identifiable {
        let title: String
        let rows: [FXDef]
        var id: String { title }
    }

    private var groups: [EffectGroup] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        var order: [String] = []
        var buckets: [String: [FXDef]] = [:]
        for def in FXCatalog.shared.list where def.kind == kind && !def.isIntrinsic {
            if !terms.isEmpty {
                let hay = (def.name + " " + def.category.joined(separator: " ")).lowercased()
                guard terms.allSatisfy({ hay.contains($0) }) else { continue }
            }
            let title = def.category.dropFirst().joined(separator: " \u{203A} ")
            let key = title.isEmpty ? (def.category.first ?? "Other") : title
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(def)
        }
        return order.sorted().map { EffectGroup(title: $0, rows: (buckets[$0] ?? []).sorted { $0.name < $1.name }) }
    }

    private var isTransition: Bool { kind.hasSuffix("Transition") }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Picker("Kind", selection: $kind) {
                    ForEach(kinds, id: \.id) { k in Text(k.title).tag(k.id) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("effectsKind")
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Search effects", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("effectsSearch")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear search")
                    }
                }
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if !isTransition && selected.isEmpty {
                Label("Select a clip to apply an effect.", systemImage: "hand.tap")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !ready || FXCatalog.shared.list.isEmpty {
                ContentUnavailableView("Effects Unavailable", systemImage: "wand.and.stars",
                                       description: Text("The effect catalog could not be read."))
                    .frame(maxHeight: .infinity)
            } else if groups.isEmpty {
                ContentUnavailableView.search(text: query).frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups) { group in
                        Section(group.title) {
                            ForEach(group.rows) { def in
                                Button { apply(def) } label: {
                                    HStack {
                                        Text(verbatim: def.name)
                                            .foregroundStyle((isTransition || !selected.isEmpty) ? Color.primary : Color.secondary)
                                            .lineLimit(1)
                                        Spacer()
                                        Image(systemName: "plus.circle").foregroundStyle(.tint).accessibilityHidden(true)
                                    }
                                }
                                .disabled(!isTransition && selected.isEmpty)
                                .accessibilityIdentifier("effectRow_\(def.id)")
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("effects")
        .task {
            FXCatalog.shared.ensureLoaded(model)
            ready = true
        }
    }

    private func apply(_ def: FXDef) {
        switch def.kind {
        case "VideoTransition", "AudioTransition":
            var params: [String: Any] = ["effect": def.id]
            if let clip = selected.first { params["clip"] = clip }
            model.run(def.kind == "VideoTransition" ? "sequence.applyVideoTransition" : "sequence.applyAudioTransition", params)
        default:
            guard !selected.isEmpty else { return }
            if model.run("effects.apply", ["clips": selected, "effect": def.id]) {
                uiOpenPanel("panel.effectControls", model: model)
            }
        }
    }
}
