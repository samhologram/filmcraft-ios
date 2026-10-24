import SwiftUI
@preconcurrency import FilmCraftKit

/// The body of a panel by id (no chrome). Panels without bespoke UI show their catalog commands.
struct PanelContentView: View {
    let model: EditorModel
    let panelID: String

    var body: some View {
        switch panelID {
        case "panel.project": MediaBrowserView(model: model)
        case "panel.effects": EffectsPanel(model: model)
        case "panel.effectControls": EffectControlsPanel(model: model)
        case "panel.audioTrackMixer": AudioMixerPanel(model: model)
        default: GenericPanel(model: model, panelID: panelID)
        }
    }
}

/// Horizontally scrolling chips for the primary panels plus a "More" menu with the rest (`panel.<id>`).
struct PanelTabs: View {
    let model: EditorModel

    var body: some View {
        let current = model.activePanel ?? "panel.project"
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) {
                    // A panel opened through Window or More remains a visible, selectable tab in the sheet.
                    ForEach(PanelUI.primary + (PanelUI.primary.contains(current) ? [] : [current]), id: \.self) { id in
                        let selected = current == id
                        Button {
                            uiOpenPanel(id, model: model)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: PanelUI.symbol(id))
                                Text(verbatim: PanelUI.title(id)).lineLimit(1)
                            }
                            .font(.subheadline)
                            .padding(.horizontal, 4)
                            .frame(minHeight: 28)
                        }
                        .glassToggle(selected)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier(id)
                        .id(id)
                    }
                    MorePanelsMenu(model: model)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.activePanel, initial: true) { _, id in
                guard let id else { return }
                withAnimation(.smooth) { reader.scrollTo(id, anchor: .center) }
            }
            .onChange(of: model.panelRevealTick) { _, _ in
                guard let id = model.activePanel else { return }
                withAnimation(.smooth) { reader.scrollTo(id, anchor: .center) }
            }
        }
    }
}

/// Every panel that is not a primary tab.
struct MorePanelsMenu: View {
    let model: EditorModel
    var compact = false

    var body: some View {
        let current = model.activePanel
        Menu {
            ForEach(PanelUI.morePanels(), id: \.id) { p in
                Button {
                    uiOpenPanel(p.id, model: model)
                } label: {
                    if current == p.id {
                        Label(p.title, systemImage: "checkmark")
                    } else {
                        Label(p.title, systemImage: PanelUI.symbol(p.id))
                    }
                }
                .accessibilityIdentifier(p.id)
            }
        } label: {
            if compact {
                Image(systemName: "ellipsis.circle").frame(minWidth: 28, minHeight: 28)
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "ellipsis.circle")
                    Text("More").lineLimit(1)
                }
                .font(.subheadline)
                .padding(.horizontal, 4)
                .frame(minHeight: 28)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .accessibilityLabel("More panels")
        .accessibilityIdentifier("morePanels")
    }
}

/// The panel sheet (iPhone, narrow iPad window): title, close, the panel tabs and the panel itself.
struct PanelSheet: View {
    let model: EditorModel

    var body: some View {
        let id = model.activePanel ?? "panel.project"
        VStack(spacing: 0) {
            HStack {
                Label(PanelUI.title(id), systemImage: PanelUI.symbol(id))
                    .font(.headline)
                    .lineLimit(1)
                    .accessibilityIdentifier("panelTitle")
                Spacer()
                Button {
                    model.inspectorVisible = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close panel")
                .accessibilityIdentifier("panelClose")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            PanelTabs(model: model)
            PanelContentView(model: model, panelID: id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspector")
    }
}
