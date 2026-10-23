import SwiftUI
import UIKit

/// Entry point. A `DocumentGroup` cannot create a document by itself on iOS (`newDocument` / `openDocument` are
/// macOS-only), so with `-FilmCraftDemo` the app runs a `WindowGroup` that owns a fresh demo document and lands
/// straight in the editor (UI tests and screenshots). Otherwise the normal document browser launches.
/// The two are separate `App` types because the scene set is chosen before any scene exists.
@main
enum FilmCraftLauncher {
    @MainActor static func main() {
        AppEnvironment.prepareLaunch()
        if AppEnvironment.isDemo {
            DemoApp.main()
        } else {
            FilmCraftApp.main()
        }
    }
}

struct FilmCraftApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { FilmCraftDocument() }) { file in
            EditorScene(model: file.document.model)
        }
        .commands { EditorCommands() }

        DocumentGroupLaunchScene("FilmCraft") {
            NewDocumentButton("New Project")
        } background: {
            Color(.systemBackground)
        } overlayAccessoryView: { geometry in
            LaunchIcon(geometry: geometry)
        }
    }
}

/// `-FilmCraftDemo`: one window with a new demo document.
struct DemoApp: App {
    /// One demo document per launch (a `@State` initializer would build a new demo project on every view init).
    @MainActor static let document = FilmCraftDocument()

    var body: some Scene {
        WindowGroup {
            DemoWindow()
        }
        .commands { EditorCommands() }
    }
}

private struct DemoWindow: View {
    var body: some View {
        EditorScene(model: DemoApp.document.model)
    }
}

/// The editor of one open document: the UI root plus the hooks that tie the model to its scene.
struct EditorScene: View {
    let model: EditorModel
    @Environment(\.undoManager) private var undoManager
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        EditorRootView(model: model)
            .onAppear { model.undoManager = undoManager }
            .onChange(of: undoManager) { _, manager in model.undoManager = manager }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active, model.isPlaying { model.playback.stop() }
                if phase == .active { model.photos.refreshStatus() }
            }
            .task { await model.bootstrap() }
    }
}

/// App icon above the title of the document browser's launch scene.
private struct LaunchIcon: View {
    let geometry: DocumentLaunchGeometryProxy

    var body: some View {
        let size: CGFloat = 72
        Group {
            if let icon = AppIcon.image {
                Image(uiImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: "film.stack").resizable().scaledToFit().padding(14).foregroundStyle(.tint)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .position(x: geometry.titleViewFrame.midX, y: max(size / 2, geometry.titleViewFrame.minY - size / 2 - 12))
        .accessibilityHidden(true)
    }
}

enum AppIcon {
    /// The primary app icon from the bundle's `CFBundleIcons`, if the asset catalog provides one.
    static var image: UIImage? {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String], let name = files.last else { return nil }
        return UIImage(named: name)
    }
}
