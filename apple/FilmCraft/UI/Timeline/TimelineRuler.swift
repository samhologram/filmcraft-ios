import SwiftUI
@preconcurrency import FilmCraftKit

/// The time ruler: ticks and labels for the visible range, under the fixed centre playhead.
struct TimelineRuler: View {
    let playhead: Int64
    let pixelsPerSecond: Double
    let width: CGFloat
    let height: CGFloat

    private static let steps: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600, 7200]

    var body: some View {
        Canvas { context, size in
            let pps = max(0.5, pixelsPerSecond)
            let centre = Double(size.width) / 2
            let phSeconds = Timecode.seconds(playhead)
            let left = phSeconds - centre / pps
            let right = phSeconds + centre / pps
            let step = Self.steps.first { $0 * pps >= 64 } ?? Self.steps[Self.steps.count - 1]
            let minor = step / 5
            var t = (left / minor).rounded(.down) * minor
            var guardCount = 0
            while t <= right, guardCount < 4000 {
                guardCount += 1
                let x = centre + (t - phSeconds) * pps
                let isMajor = abs((t / step).rounded() * step - t) < minor / 10
                if t >= -0.0001 {
                    let tickHeight = isMajor ? size.height * 0.55 : size.height * 0.25
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: size.height))
                    p.addLine(to: CGPoint(x: x, y: size.height - tickHeight))
                    context.stroke(p, with: .color(.secondary.opacity(isMajor ? 0.9 : 0.5)), lineWidth: 1)
                    if isMajor {
                        let text = Text(verbatim: label(t, step: step)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        context.draw(text, at: CGPoint(x: x + 3, y: 2), anchor: .topLeading)
                    }
                }
                t += minor
            }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }

    private func label(_ seconds: Double, step: Double) -> String {
        if step >= 1 { return uiClock(seconds) }
        guard seconds.isFinite else { return "0:00" }
        let whole = max(0, min(seconds, 359_999)).rounded(.down)
        let tenth = Int(max(0, min(9, ((seconds - whole) * 10).rounded())))
        return uiClock(whole) + "." + String(tenth)
    }
}

/// The marker row: a flag per sequence marker (`marker.<id>`); tapping goes to it.
struct MarkerRow: View {
    let model: EditorModel
    let width: CGFloat
    let height: CGFloat
    let ticksPerPixel: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.timeline.markers, id: \.id) { marker in
                let x = width / 2 + CGFloat((Double(marker.at) - Double(model.state.playhead)) / ticksPerPixel)
                if x > -24, x < width + 24 {
                    Button {
                        model.seek(marker.at)
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "flag.fill").font(.caption2)
                            if !marker.name.isEmpty {
                                Text(verbatim: marker.name).font(.caption2).lineLimit(1)
                            }
                        }
                        .foregroundStyle(Color(hex: marker.color) ?? .green)
                        .padding(.horizontal, 2)
                        .frame(height: height)
                    }
                    .buttonStyle(.plain)
                    .offset(x: x - 4)
                    .accessibilityLabel(marker.name.isEmpty ? "Marker" : marker.name)
                    .accessibilityIdentifier("marker.\(marker.id)")
                }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipped()
    }
}

/// A track's header: name and the toggles for visibility / mute / solo / lock (engine `timeline.setTrack`).
struct TrackHeader: View {
    let model: EditorModel
    let track: TrackInfo
    let width: CGFloat
    let height: CGFloat
    let compact: Bool

    private var isAudio: Bool { track.kind == "audio" }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: track.name)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(.secondary)
            HStack(spacing: 0) {
                if isAudio {
                    toggle(on: track.muted, onSymbol: "speaker.slash.fill", offSymbol: "speaker.wave.2.fill", label: "Mute", id: "trackMute_\(track.id)") {
                        model.run("timeline.setTrack", ["track": track.id, "muted": !track.muted])
                    }
                    if !compact {
                        toggle(on: track.solo, onSymbol: "s.circle.fill", offSymbol: "s.circle", label: "Solo", id: "trackSolo_\(track.id)") {
                            model.run("timeline.setTrack", ["track": track.id, "solo": !track.solo])
                        }
                    }
                } else {
                    toggle(on: track.hidden, onSymbol: "eye.slash.fill", offSymbol: "eye.fill", label: "Visibility", id: "trackVisible_\(track.id)") {
                        // `hidden` is the engine's `enabled == false`.
                        model.run("timeline.setTrack", ["track": track.id, "enabled": track.hidden])
                    }
                }
                toggle(on: track.locked, onSymbol: "lock.fill", offSymbol: "lock.open", label: "Lock", id: "trackLock_\(track.id)") {
                    model.run("timeline.setTrack", ["track": track.id, "locked": !track.locked])
                }
            }
        }
        .padding(.horizontal, 4)
        .frame(width: width, height: height, alignment: .leading)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("track.\(track.id)")
    }

    private func toggle(on: Bool, onSymbol: String, offSymbol: String, label: LocalizedStringKey, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: on ? onSymbol : offSymbol)
                .font(.system(size: 11))
                .foregroundStyle(on ? Color.accentColor : Color.secondary)
                .frame(width: compact ? 26 : 24, height: max(20, height * 0.45))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}
