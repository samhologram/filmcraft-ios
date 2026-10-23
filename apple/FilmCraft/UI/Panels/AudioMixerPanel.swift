import SwiftUI
@preconcurrency import FilmCraftKit

/// The Audio panel: a strip per track (mute, solo, lock) and the mixer commands from the catalog below.
struct AudioMixerPanel: View {
    let model: EditorModel

    private var audioTracks: [TrackInfo] { model.timeline.tracks.filter { $0.kind == "audio" }.sorted { $0.index < $1.index } }

    var body: some View {
        VStack(spacing: 0) {
            if !audioTracks.isEmpty {
                List {
                    Section("Tracks") {
                        ForEach(audioTracks, id: \.id) { track in
                            HStack(spacing: 10) {
                                Text(verbatim: track.name).lineLimit(1)
                                Spacer()
                                toggle("speaker.slash.fill", "speaker.wave.2.fill", on: track.muted, label: "Mute \(track.name)", id: "mixerMute_\(track.id)") {
                                    model.run("timeline.setTrack", ["track": track.id, "muted": !track.muted])
                                }
                                toggle("s.circle.fill", "s.circle", on: track.solo, label: "Solo \(track.name)", id: "mixerSolo_\(track.id)") {
                                    model.run("timeline.setTrack", ["track": track.id, "solo": !track.solo])
                                }
                                toggle("lock.fill", "lock.open", on: track.locked, label: "Lock \(track.name)", id: "mixerLock_\(track.id)") {
                                    model.run("timeline.setTrack", ["track": track.id, "locked": !track.locked])
                                }
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("mixerTrack_\(track.id)")
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .frame(maxHeight: min(CGFloat(audioTracks.count) * 52 + 70, 280))
            }
            GenericPanel(model: model, panelID: "panel.audioTrackMixer")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("audioMixer")
    }

    private func toggle(_ onSymbol: String, _ offSymbol: String, on: Bool, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: on ? onSymbol : offSymbol)
                .frame(width: 32, height: 28)
                .foregroundStyle(on ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}
