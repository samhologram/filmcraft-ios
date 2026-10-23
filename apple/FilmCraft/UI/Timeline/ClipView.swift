import SwiftUI
@preconcurrency import FilmCraftKit

/// What a clip reports to the timeline. All positions are in the lane's coordinate space.
struct ClipActions {
    var tap: (CGFloat) -> Void
    var doubleTap: () -> Void
    var moveChanged: (CGSize) -> Void
    var moveEnded: (CGSize) -> Void
    var trimChanged: (TrimEdge, CGFloat) -> Void
    var trimEnded: (TrimEdge, CGFloat) -> Void
}

enum TrimEdge: String, Sendable {
    case `in`, out
}

/// A clip on the timeline: a rounded rectangle with its name, a thumbnail (video) or waveform (audio), and trim handles
/// when selected. Only the part inside the lane is drawn, so a clip thousands of points wide costs the same as a short one.
struct ClipView: View {
    let model: EditorModel
    let clip: ClipInfo
    /// The clip's left and right edges in lane coordinates (may lie far outside the lane).
    let x0: CGFloat
    let x1: CGFloat
    let laneWidth: CGFloat
    let height: CGFloat
    let selected: Bool
    /// Drags move (or slip/slide) the clip: only for tools where that makes sense.
    let canDrag: Bool
    let actions: ClipActions

    private let handleWidth: CGFloat = 18
    private let margin: CGFloat = 40

    private var visibleX0: CGFloat { max(x0, -margin) }
    private var visibleX1: CGFloat { min(x1, laneWidth + margin) }
    private var width: CGFloat { max(0, visibleX1 - visibleX0) }

    // Clip colours are content: the engine's label colour when set, else a colour per clip kind.
    private var tint: Color {
        if let c = Color(hex: clip.color) { return c }
        switch clip.kind {
        case "audio": return .green
        case "graphic", "text": return .purple
        case "adjustment": return .gray
        default: return .blue
        }
    }

    var body: some View {
        if width > 0 {
            content
                .frame(width: width, height: height)
                .offset(x: visibleX0)
        }
    }

    private var content: some View {
        ZStack(alignment: .leading) {
            clipBody
            // Trim handles are siblings of the clip body, not part of its combined element, so they stay reachable.
            if selected { handles }
        }
        .opacity(clip.enabled ? 1 : 0.4)
    }

    private var clipBody: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tint.opacity(selected ? 0.9 : 0.62))
            media
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            // White title with a black shadow and white/black outline: content colours drawn on the clip tint
            // (which is the engine's label colour), so they must not follow the light/dark appearance.
            Text(verbatim: clip.name.isEmpty ? clip.kind.capitalized : clip.name)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 1)
                .lineLimit(1)
                .padding(.horizontal, selected ? handleWidth + 2 : 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 2)
                .allowsHitTesting(false)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(selected ? Color.white : Color.black.opacity(0.35), lineWidth: selected ? 2 : 1)
                .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .hoverEffect(.highlight)
        .gesture(
            SpatialTapGesture(count: 2).onEnded { _ in actions.doubleTap() }
                .exclusively(before: SpatialTapGesture(count: 1, coordinateSpace: .named("lane")).onEnded { actions.tap($0.location.x) })
        )
        .gesture(moveGesture, isEnabled: canDrag && selected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(clip.name.isEmpty ? clip.kind : clip.name)
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "Open Effect Controls") { actions.doubleTap() }
        .accessibilityIdentifier("clip.\(clip.id)")
    }

    @ViewBuilder
    private var media: some View {
        if clip.kind == "audio", let mediaID = clip.mediaId {
            WaveformView(model: model, clip: clip, mediaID: mediaID, x0: x0, x1: x1, visibleX0: visibleX0, visibleX1: visibleX1)
                .opacity(0.85)
        } else if (clip.kind == "video" || clip.kind == "image"), let mediaID = clip.mediaId {
            HStack(spacing: 0) {
                if visibleX0 <= x0 + 1 {
                    ClipThumbnail(model: model, mediaID: mediaID, height: height)
                        .frame(width: min(width, height * 16 / 9))
                        .clipped()
                        .opacity(0.9)
                }
                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)
        }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { actions.moveChanged($0.translation) }
            .onEnded { actions.moveEnded($0.translation) }
    }

    private var handles: some View {
        HStack(spacing: 0) {
            if x0 >= -margin { handle(.in) } else { Spacer().frame(width: 0) }
            Spacer(minLength: 0)
            if x1 <= laneWidth + margin { handle(.out) }
        }
    }

    private func handle(_ edge: TrimEdge) -> some View {
        ZStack {
            // Handle chrome sits on top of any clip tint: fixed white with a dark glyph, in both appearances.
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white)
            Image(systemName: edge == .in ? "chevron.compact.right" : "chevron.compact.left")
                .font(.caption.weight(.bold))
                .foregroundStyle(.black.opacity(0.7))
        }
        .frame(width: handleWidth, height: height)
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { actions.trimChanged(edge, $0.translation.width) }
                .onEnded { actions.trimEnded(edge, $0.translation.width) }
        )
        .accessibilityLabel(edge == .in ? "Trim start" : "Trim end")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("clip.\(clip.id).\(edge == .in ? "trimStart" : "trimEnd")")
    }
}

/// The first frame of the clip's media at the clip's leading edge.
private struct ClipThumbnail: View {
    let model: EditorModel
    let mediaID: UInt64
    let height: CGFloat

    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(mediaID)-\(model.mediaVersion)") {
            image = await model.thumbnail(media: mediaID, edge: Int(max(64, height * 2 * displayScale)))
        }
    }
}
