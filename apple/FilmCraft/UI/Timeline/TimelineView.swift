import SwiftUI
@preconcurrency import FilmCraftKit

/// The multitrack timeline. A fixed playhead sits in the middle of the lanes and the tracks scroll under it: dragging
/// scrubs, pinching zooms. Tap selects a clip, double-tap opens Effect Controls, a selected clip drags to move and its
/// handles trim. Everything that changes the project is an engine command.
struct MultitrackTimelineView: View {
    let model: EditorModel

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var scrubStart: Int64?
    @State private var scrubIsHorizontal: Bool?
    @State private var pinchStart: Double?
    @State private var moving: MoveState?
    @State private var trimming: TrimState?

    private struct MoveState {
        let clip: UInt64
        var translation: CGSize
    }

    private struct TrimState {
        let clip: UInt64
        let edge: TrimEdge
        var dx: CGFloat
    }

    private var compact: Bool { horizontalSizeClass == .compact }
    private var headerWidth: CGFloat { compact ? 56 : 88 }
    private var videoRow: CGFloat { compact ? 40 : 52 }
    private var audioRow: CGFloat { compact ? 34 : 42 }
    private let rulerHeight: CGFloat = 22
    private let markerHeight: CGFloat = 18

    private var tracks: [TrackInfo] {
        let all = model.timeline.tracks
        let video = all.filter { $0.kind != "audio" }.sorted { $0.index > $1.index }
        let audio = all.filter { $0.kind == "audio" }.sorted { $0.index < $1.index }
        return video + audio
    }

    private func rowHeight(_ track: TrackInfo) -> CGFloat { track.kind == "audio" ? audioRow : videoRow }

    private var ticksPerPixel: Double { TickMath.ticksPerPixel(model.pixelsPerSecond) }

    var body: some View {
        GeometryReader { geo in
            let laneWidth = max(0, geo.size.width - headerWidth)
            VStack(spacing: 0) {
                topRows(laneWidth: laneWidth)
                if tracks.isEmpty {
                    emptyState
                } else {
                    ViewThatFits(in: .vertical) {
                        trackRows(laneWidth: laneWidth)
                        ScrollView(.vertical) { trackRows(laneWidth: laneWidth) }
                            .scrollIndicators(.visible)
                    }
                }
                Spacer(minLength: 0)
            }
            .overlay(alignment: .topLeading) { playheadLine(laneWidth: laneWidth, height: geo.size.height) }
            .contentShape(Rectangle())
            .simultaneousGesture(pinchGesture)
            .onChange(of: laneWidth, initial: true) { _, new in model.timelineViewportWidth = Double(new) }
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline")
    }

    // MARK: Ruler, markers

    private func topRows(laneWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                zoomCorner
                    .frame(width: headerWidth, height: rulerHeight)
                TimelineRuler(playhead: model.state.playhead, pixelsPerSecond: model.pixelsPerSecond, width: laneWidth, height: rulerHeight)
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { value in
                        model.seek(model.state.playhead &+ TickMath.clampTicks(Double(value.location.x - laneWidth / 2) * ticksPerPixel))
                    })
                    .simultaneousGesture(scrubGesture)
            }
            HStack(spacing: 0) {
                Color.clear.frame(width: headerWidth, height: markerHeight)
                MarkerRow(model: model, width: laneWidth, height: markerHeight, ticksPerPixel: ticksPerPixel)
                    .simultaneousGesture(scrubGesture)
            }
        }
        .background(.bar)
    }

    private var zoomCorner: some View {
        HStack(spacing: 0) {
            cornerButton("minus.magnifyingglass", "Zoom Out", "command.view.zoomOut") { model.pixelsPerSecond /= 1.4 }
            cornerButton("plus.magnifyingglass", "Zoom In", "command.view.zoomIn") { model.pixelsPerSecond *= 1.4 }
            if !compact {
                cornerButton("arrow.left.and.right", "Zoom to Sequence", "command.view.zoomToSequence") { model.zoomToSequence() }
            }
        }
    }

    private func cornerButton(_ symbol: String, _ label: LocalizedStringKey, _ id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: compact ? 26 : 28, height: rulerHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    // MARK: Tracks

    private func trackRows(laneWidth: CGFloat) -> some View {
        VStack(spacing: 1) {
            ForEach(tracks, id: \.id) { track in
                HStack(spacing: 0) {
                    TrackHeader(model: model, track: track, width: headerWidth, height: rowHeight(track), compact: compact)
                    lane(track, laneWidth: laneWidth)
                }
            }
        }
    }

    private func lane(_ track: TrackInfo, laneWidth: CGFloat) -> some View {
        let height = rowHeight(track)
        let playhead = model.state.playhead
        let tpp = ticksPerPixel
        let selected = Set(model.state.selectedClips)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.quaternary.opacity(0.4))
            ForEach(track.clips, id: \.id) { clip in
                let (x0, x1) = edges(of: clip, playhead: playhead, tpp: tpp, laneWidth: laneWidth)
                if x1 >= -60, x0 <= laneWidth + 60 {
                    let isMoving = moving?.clip == clip.id
                    ClipView(
                        model: model, clip: clip, x0: x0, x1: x1, laneWidth: laneWidth, height: height - 4,
                        selected: selected.contains(clip.id),
                        canDrag: !track.locked && canDragWith(tool: model.activeTool),
                        actions: actions(for: clip, laneWidth: laneWidth)
                    )
                    .offset(y: 2)
                    .offset(isMoving ? (moving?.translation ?? .zero) : .zero)
                    .zIndex(isMoving ? 10 : 0)
                }
            }
        }
        .coordinateSpace(name: "lane")
        .frame(width: laneWidth, height: height, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        // On the lane itself (the clips' ancestor), so a drag that starts on a clip scrubs too.
        .gesture(SpatialTapGesture().onEnded { _ in model.run("edit.deselectAll") })
        .simultaneousGesture(scrubGesture)
        .opacity(track.hidden ? 0.45 : 1)
    }

    private func canDragWith(tool: String) -> Bool {
        switch tool {
        case "tool.razor", "tool.hand", "tool.zoom", "tool.type", "tool.verticalType", "tool.pen", "tool.rectangle", "tool.ellipse": return false
        default: return true
        }
    }

    /// Edges of `clip` in lane coordinates, including a live trim in progress.
    private func edges(of clip: ClipInfo, playhead: Int64, tpp: Double, laneWidth: CGFloat) -> (CGFloat, CGFloat) {
        let centre = Double(laneWidth) / 2
        // Subtract in Double: the ticks come from a project file and may be near the Int64 limits.
        var x0 = centre + (Double(clip.start) - Double(playhead)) / tpp
        var x1 = centre + (Double(clip.end) - Double(playhead)) / tpp
        if let trim = trimming, trim.clip == clip.id {
            let dx = Double(trim.dx)
            switch trim.edge {
            case .in: x0 = min(x0 + dx, x1 - 8)
            case .out: x1 = max(x1 + dx, x0 + 8)
            }
        }
        return (CGFloat(x0), CGFloat(x1))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack").font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
            Text("Add clips from Photos or Files to start editing.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                model.showMediaBrowser = true
            } label: {
                Label("Add Media", systemImage: "plus").lineLimit(1)
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("timelineAddMedia")
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func playheadLine(laneWidth: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .top) {
            // Red playhead: the universal NLE convention, and it must stand out over any clip colour.
            Rectangle()
                .fill(Color.red)
                .frame(width: 2, height: height)
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.red)
                .offset(y: -1)
        }
        .frame(width: 14, height: height, alignment: .top)
        .offset(x: headerWidth + laneWidth / 2 - 7)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playhead")
        .accessibilityValue(Timecode.string(model.state.playhead, model.state))
        .accessibilityIdentifier("playhead")
    }

    // MARK: Scrub and zoom

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if scrubStart == nil {
                    scrubStart = model.state.playhead
                    scrubIsHorizontal = abs(value.translation.width) >= abs(value.translation.height)
                }
                guard scrubIsHorizontal == true, let start = scrubStart, moving == nil, trimming == nil else { return }
                let delta = TickMath.clampTicks(-Double(value.translation.width) * ticksPerPixel)
                model.seek(start &+ delta)
            }
            .onEnded { _ in
                scrubStart = nil
                scrubIsHorizontal = nil
            }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchStart ?? model.pixelsPerSecond
                pinchStart = base
                model.pixelsPerSecond = base * Double(value.magnification)
            }
            .onEnded { _ in pinchStart = nil }
    }

    // MARK: Clip actions

    private func actions(for clip: ClipInfo, laneWidth: CGFloat) -> ClipActions {
        ClipActions(
            tap: { x in tap(clip, x: x, laneWidth: laneWidth) },
            doubleTap: {
                model.selectClip(clip.id, extend: false)
                uiOpenPanel("panel.effectControls", model: model)
            },
            moveChanged: { moving = MoveState(clip: clip.id, translation: $0) },
            moveEnded: { translation in
                moving = nil
                commitMove(clip, translation: translation)
            },
            trimChanged: { edge, dx in trimming = TrimState(clip: clip.id, edge: edge, dx: dx) },
            trimEnded: { edge, dx in
                trimming = nil
                commitTrim(clip, edge: edge, dx: dx)
            }
        )
    }

    private func tap(_ clip: ClipInfo, x: CGFloat, laneWidth: CGFloat) {
        if model.activeTool == "tool.razor" {
            let at = model.state.playhead &+ TickMath.clampTicks(Double(x - laneWidth / 2) * ticksPerPixel)
            guard at > clip.start, at < clip.end else { return }
            model.run("timeline.razor", ["clip": clip.id, "time": TickMath.snapToFrame(at, state: model.state)])
            return
        }
        model.selectClip(clip.id, extend: false)
    }

    private func commitTrim(_ clip: ClipInfo, edge: TrimEdge, dx: CGFloat) {
        let delta = TickMath.snapToFrame(TickMath.clampTicks(Double(dx) * ticksPerPixel), state: model.state)
        guard delta != 0 else { return }
        let mode = model.activeTool == "tool.ripple" ? "ripple" : "regular"
        model.run("timeline.trim", ["clip": clip.id, "edge": edge.rawValue, "mode": mode, "delta": delta])
    }

    private func commitMove(_ clip: ClipInfo, translation: CGSize) {
        let delta = TickMath.snapToFrame(TickMath.clampTicks(Double(translation.width) * ticksPerPixel), state: model.state)
        switch model.activeTool {
        case "tool.slip":
            guard delta != 0 else { return }
            // Dragging the strip right shows earlier footage.
            model.run("timeline.slip", ["clip": clip.id, "delta": -delta])
        case "tool.slide":
            guard delta != 0 else { return }
            model.run("timeline.slide", ["clip": clip.id, "delta": delta])
        default:
            let target = targetTrack(for: clip, dy: translation.height)
            guard delta != 0 || target != clip.trackId else { return }
            let start = max(0, clip.start &+ delta)
            let move: [String: Any] = ["clip": clip.id, "track": target, "time": start]
            model.run("timeline.move", ["moves": [move]])
        }
    }

    /// The track of the same kind under the clip after a vertical drag of `dy` points (the clip's own track when none).
    private func targetTrack(for clip: ClipInfo, dy: CGFloat) -> UInt64 {
        var y: CGFloat = 0
        var frames: [(id: UInt64, kind: String, mid: CGFloat)] = []
        for t in tracks {
            let h = rowHeight(t)
            frames.append((t.id, t.kind == "audio" ? "audio" : "video", y + h / 2))
            y += h + 1
        }
        guard let own = frames.first(where: { $0.id == clip.trackId }) else { return clip.trackId }
        let probe = own.mid + dy
        let candidates = frames.filter { $0.kind == own.kind }
        guard let best = candidates.min(by: { abs($0.mid - probe) < abs($1.mid - probe) }) else { return clip.trackId }
        return best.id
    }
}
