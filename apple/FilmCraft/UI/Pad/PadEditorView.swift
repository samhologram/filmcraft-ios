import SwiftUI
@preconcurrency import FilmCraftKit

/// iPad layout: three zones. Top-leading the panels (Media, Effects, Effect Controls…), top-trailing the viewer with
/// the edit bar and transport, and the multitrack timeline across the full width at the bottom. The divider between
/// top and bottom drags. Below ~900 pt the panel column goes away and panels open as sheets (`EditorRootView`).
struct PadEditorView: View {
    @Bindable var model: EditorModel
    let showsPanelColumn: Bool

    @AppStorage("padTopFraction") private var topFraction = 0.55
    @State private var dragStart: Double?

    private let minTop: CGFloat = 190
    private let minTimeline: CGFloat = 170
    private let dividerHeight: CGFloat = 20

    var body: some View {
        GeometryReader { geo in
            let available = max(0, geo.size.height - dividerHeight)
            let top = topHeight(available: available)
            VStack(spacing: 0) {
                topZone(width: geo.size.width)
                    .frame(height: top)
                divider(available: available)
                MultitrackTimelineView(model: model)
                    .frame(maxHeight: .infinity)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .toolbar { toolbar }
    }

    /// The top zone's height: the saved fraction, kept inside what both zones need.
    private func topHeight(available: CGFloat) -> CGFloat {
        let wanted = available * CGFloat(min(0.8, max(0.2, topFraction)))
        let upper = max(minTop, available - minTimeline)
        return min(max(minTop, wanted), upper)
    }

    // MARK: Zones

    private func topZone(width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if showsPanelColumn {
                panelColumn
                    .frame(width: min(max(300, width * 0.38), 520))
            }
            viewerColumn
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private var panelColumn: some View {
        PanelDockView(model: model)
    }

    private var viewerColumn: some View {
        VStack(spacing: 6) {
            ViewerView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            EditBar(model: model, includesUndo: false)
            TransportBar(model: model)
        }
    }

    // MARK: Divider

    private func divider(available: CGFloat) -> some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 44, height: 5)
        }
        .frame(height: dividerHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(coordinateSpace: .global)
                .onChanged { value in
                    guard available > 0 else { return }
                    let start = dragStart ?? topFraction
                    dragStart = start
                    topFraction = min(0.8, max(0.2, start + Double(value.translation.height / available)))
                }
                .onEnded { _ in dragStart = nil }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Resize timeline")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: topFraction = min(0.8, topFraction + 0.05)
            case .decrement: topFraction = max(0.2, topFraction - 0.05)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("zoneDivider")
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            UndoRedoButtons(model: model)
            ToolbarToolMenu(model: model)
            PaletteButton(model: model)
            ShareButton(model: model)
            OverflowMenu(model: model, includesPanels: !showsPanelColumn)
        }
    }
}
