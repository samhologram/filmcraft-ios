import Observation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Pick an image or movie before the system creates a project. Cancel throws; nil would create a blank project.
struct NewFromMediaButton: View {
    @State private var importer = NewMediaImporter()

    var body: some View {
        @Bindable var state = importer
        NewDocumentButton("New from Media", for: FilmCraftDocument.self) { [importer] in
            try await importer.prepare()
        }
        .accessibilityIdentifier("newFromMedia")
        .fullScreenCover(isPresented: $state.showsPicker, onDismiss: {
            importer.resolve(MediaProviderBox(nil))
        }) {
            NewMediaPicker(importer: importer).ignoresSafeArea()
        }
        .alert("Could not create the project", isPresented: $state.failed) {
            Button("OK", role: .cancel) {}
        }
    }
}

private struct MediaProviderBox: @unchecked Sendable {
    let provider: NSItemProvider?
    init(_ provider: NSItemProvider?) { self.provider = provider }
}

@MainActor @Observable
private final class NewMediaImporter: NSObject, PHPickerViewControllerDelegate {
    var showsPicker = false
    var failed = false
    @ObservationIgnored private var continuation: CheckedContinuation<MediaProviderBox, Never>?

    func prepare() async throws -> FilmCraftDocument {
        resolve(MediaProviderBox(nil))
        let selected = await withCheckedContinuation { continuation in
            self.continuation = continuation
            showsPicker = true
        }
        guard let provider = selected.provider else { throw CancellationError() }
        do {
            guard let type = provider.registeredTypeIdentifiers.first(where: {
                guard let value = UTType($0) else { return false }
                return value.conforms(to: .image) || value.conforms(to: .movie)
            }) else { throw CocoaError(.fileReadUnknown) }
            let preferredName = provider.suggestedName
            // The picker owns the temporary URL only for the callback's lifetime. Copy it before resuming.
            let owned: URL = try await withCheckedThrowingContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: type) { temporary, error in
                    guard let temporary else {
                        continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                        return
                    }
                    do { continuation.resume(returning: try AppEnvironment.copyIntoOwnedMedia(temporary, preferredName: preferredName)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
            return try await Task.detached(priority: .userInitiated) {
                try FilmCraftDocument.fromOwnedMedia(owned)
            }.value
        } catch {
            failed = true
            throw CancellationError()
        }
    }

    nonisolated func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        let selected = MediaProviderBox(results.first?.itemProvider)
        Task { @MainActor in
            showsPicker = false
            resolve(selected)
        }
    }

    func resolve(_ selected: MediaProviderBox) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: selected)
    }
}

private struct NewMediaPicker: UIViewControllerRepresentable {
    let importer: NewMediaImporter

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = importer
        return picker
    }

    func updateUIViewController(_ picker: PHPickerViewController, context: Context) {}
}
