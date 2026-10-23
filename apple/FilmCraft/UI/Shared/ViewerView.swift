import SwiftUI
@preconcurrency import FilmCraftKit

/// The Program monitor: the latest rendered program frame, aspect-fit on black (`viewer`). It publishes its size to
/// the model so renders match the screen.
struct ViewerView: View {
    let model: EditorModel

    @Environment(\.displayScale) private var displayScale

    private var aspect: CGFloat {
        let w = CGFloat(model.state.width), h = CGFloat(model.state.height)
        return w > 0 && h > 0 ? w / h : 16.0 / 9.0
    }

    var body: some View {
        // Black letterbox: the viewer shows video pixels, which are judged against black in light and dark mode alike.
        Color.black
            .overlay {
                ZStack {
                    Color.black
                    if let frame = model.programFrame {
                        Image(decorative: frame, scale: 1)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "film")
                            .font(.largeTitle)
                            // Placeholder glyph on the always-black letterbox: fixed light colour.
                            .foregroundStyle(.white.opacity(0.35))
                            .accessibilityHidden(true)
                    }
                }
                .aspectRatio(aspect, contentMode: .fit)
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                    model.viewerSize = size
                    model.viewerScale = displayScale
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Program monitor")
            .accessibilityIdentifier("viewer")
    }
}
