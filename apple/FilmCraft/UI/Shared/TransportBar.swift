import SwiftUI
@preconcurrency import FilmCraftKit

/// Go to start, frame step, play/pause, frame step, go to end, and the timecode readout (`transport.*`, `timecode`).
struct TransportBar: View {
    let model: EditorModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(showDuration: true, showEnds: true)
            row(showDuration: false, showEnds: true)
            row(showDuration: false, showEnds: false)
        }
        .frame(maxWidth: .infinity)
    }

    private func row(showDuration: Bool, showEnds: Bool) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: Timecode.string(model.state.playhead, model.state))
                .font(.system(.body, design: .monospaced).weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .accessibilityLabel("Timecode")
                .accessibilityValue(Timecode.string(model.state.playhead, model.state))
                .accessibilityIdentifier("timecode")
            if showDuration {
                Text(verbatim: "/ " + Timecode.string(model.state.duration, model.state))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 4)
            GlassEffectContainer(spacing: 4) {
                HStack(spacing: 4) {
                    if showEnds { button("backward.end.fill", "Go to Start", "transport.start") { model.seek(0) } }
                    button("backward.frame.fill", "Step Back", "transport.stepBack") { model.stepFrame(-1) }
                    button(model.isPlaying ? "pause.fill" : "play.fill", model.isPlaying ? "Pause" : "Play", "transport.play") { model.togglePlay() }
                    button("forward.frame.fill", "Step Forward", "transport.stepForward") { model.stepFrame(1) }
                    if showEnds { button("forward.end.fill", "Go to End", "transport.end") { model.seek(model.state.duration) } }
                }
            }
        }
        .padding(.horizontal, 8)
    }

    private func button(_ symbol: String, _ label: LocalizedStringKey, _ id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body)
                .frame(width: 32, height: 28)
        }
        .buttonStyle(.glass)
        .disabled(model.state.sequenceName == nil)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}
