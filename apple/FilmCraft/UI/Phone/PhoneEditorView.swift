import SwiftUI
@preconcurrency import FilmCraftKit

/// iPhone layout (and iPad windows narrower than 700 pt): the viewer on top, the timeline below it and a bottom
/// strip of tools and panels. Panels open as sheets (`EditorRootView`) whose detents keep the viewer visible.
struct PhoneEditorView: View {
    @Bindable var model: EditorModel

    /// Heights of the fixed rows (transport, edit bar, tool strip, spacing) and the least the timeline may get.
    private let fixedRows: CGFloat = 200
    private let minTimeline: CGFloat = 150

    var body: some View {
        GeometryReader { geo in
            let preferred = min(max(150, geo.size.height * 0.34), 360)
            // The viewer gives way first: the timeline never shrinks below `minTimeline`.
            let viewerHeight = max(0, min(preferred, geo.size.height - fixedRows - minTimeline))
            if geo.size.width > geo.size.height, viewerHeight < 100 {
                landscape
            } else {
                VStack(spacing: 6) {
                    if viewerHeight >= 100 {
                        ViewerView(model: model)
                            .frame(height: viewerHeight)
                            .padding(.horizontal, 8)
                    }
                    TransportBar(model: model)
                    EditBar(model: model, includesUndo: true, includesTools: false)
                    MultitrackTimelineView(model: model)
                        .frame(minHeight: minTimeline, maxHeight: .infinity)
                        .padding(.horizontal, 6)
                    ToolStrip(model: model)
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                PanelVisibilityButton(model: model, usesDock: false)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                AddMediaButton(model: model)
                PaletteButton(model: model)
                ShareButton(model: model)
                OverflowMenu(model: model)
            }
        }
    }
}

extension PhoneEditorView {
    /// Short landscape windows: viewer and transport on the left, edit bar and timeline on the right.
    fileprivate var landscape: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: 6) {
                    ViewerView(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    TransportBar(model: model)
                }
                .frame(maxWidth: 320)
                VStack(spacing: 6) {
                    EditBar(model: model, includesUndo: true, includesTools: false)
                    MultitrackTimelineView(model: model)
                        .frame(minHeight: 120, maxHeight: .infinity)
                }
            }
            .padding(.horizontal, 8)
            ToolStrip(model: model)
        }
    }
}

/// Horizontally scrolling strip: panels (`panel.<id>`), then every timeline tool (`tool.<id>`). Scrolling is the last
/// resort of the degradation order, so nothing can fall off a narrow screen.
struct ToolStrip: View {
    let model: EditorModel

    var body: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(PanelUI.primary, id: \.self) { id in
                        let selected = model.inspectorVisible && model.activePanel == id
                        Button {
                            uiOpenPanel(id, model: model, toggle: true)
                        } label: {
                            stripLabel(PanelUI.symbol(id), PanelUI.title(id))
                        }
                        .glassToggle(selected)
                        .accessibilityLabel(PanelUI.title(id))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier(id)
                    }
                    MorePanelsMenu(model: model, compact: true)
                    Divider().frame(height: 36)
                    ForEach(CommandCatalog.shared.tools, id: \.id) { tool in
                        let selected = model.activeTool == tool.id
                        Button {
                            model.runUI(tool.id)
                        } label: {
                            stripLabel(ToolUI.symbol(tool.id), ToolUI.title(tool.id))
                        }
                        .glassToggle(selected)
                        .accessibilityLabel(ToolUI.title(tool.id))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier(tool.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .scrollIndicators(.hidden)
        .background(.bar)
    }

    private func stripLabel(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol).font(.title3)
            Text(verbatim: title).font(.caption2).lineLimit(1)
        }
        .frame(minWidth: 58)
    }
}
