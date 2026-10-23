import SwiftUI
@preconcurrency import FilmCraftKit

/// Export the sequence as H.264 + AAC MP4 with resolution and quality options, to Photos (`export.photos`) or Files
/// (`export.files`), with a progress bar (`export.progress`) and Cancel.
struct ExportSheet: View {
    let model: EditorModel

    @Environment(\.dismiss) private var dismiss
    @State private var resolution = 0
    @State private var quality = 75.0
    @State private var movingFile: URL?
    @State private var showMover = false

    private struct Resolution {
        let title: String
        /// Length of the short side in pixels; nil keeps the sequence size.
        let shortSide: Int?
    }

    private static let resolutions: [Resolution] = [
        Resolution(title: String(localized: "Sequence size"), shortSide: nil),
        Resolution(title: "2160p", shortSide: 2160),
        Resolution(title: "1080p", shortSide: 1080),
        Resolution(title: "720p", shortSide: 720),
        Resolution(title: "480p", shortSide: 480),
    ]

    private var hasSequence: Bool { model.state.sequenceName != nil && model.state.duration > 0 }

    /// Pixel size for the chosen resolution, keeping the sequence's aspect ratio (even numbers, as the encoder needs).
    private func size(for index: Int) -> (width: Int, height: Int)? {
        guard Self.resolutions.indices.contains(index), let short = Self.resolutions[index].shortSide else { return nil }
        let w = Double(model.state.width), h = Double(model.state.height)
        guard w > 0, h > 0 else { return nil }
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        if w >= h { return (even(Double(short) * w / h), even(Double(short))) }
        return (even(Double(short)), even(Double(short) * h / w))
    }

    private var options: ExportOptions {
        var o = ExportOptions()
        o.quality = Int(quality)
        if let s = size(for: resolution) { o.width = s.width; o.height = s.height }
        return o
    }

    private var fileName: String {
        let raw = model.state.projectName.isEmpty ? "FilmCraft" : model.state.projectName
        let cleaned = raw.map { "/:\\?%*|\"<>".contains($0) ? "-" : String($0) }.joined()
        return cleaned + ".mp4"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Video") {
                    Picker("Resolution", selection: $resolution) {
                        ForEach(Self.resolutions.indices, id: \.self) { i in
                            Text(verbatim: Self.resolutions[i].title).tag(i)
                        }
                    }
                    .accessibilityIdentifier("exportResolution")
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Quality")
                            Spacer()
                            Text(verbatim: "\(Int(quality))").foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: $quality, in: 10...100, step: 5)
                            .accessibilityLabel("Quality")
                            .accessibilityIdentifier("exportQuality")
                    }
                } footer: {
                    Text(verbatim: summary)
                }
                .disabled(model.isExporting)

                if model.isExporting {
                    Section("Exporting") {
                        ProgressView(value: progress)
                            .accessibilityIdentifier("export.progress")
                        HStack {
                            Text(verbatim: "\(Int((progress * 100).rounded()))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel", role: .cancel) { model.cancelExport() }
                                .accessibilityIdentifier("exportCancel")
                        }
                    }
                } else {
                    Section {
                        Button {
                            Task { await model.export(to: .photos, options: options) }
                        } label: {
                            Label("Save to Photos", systemImage: "photo.badge.plus")
                        }
                        .disabled(!hasSequence)
                        .accessibilityIdentifier("export.photos")
                        Button {
                            Task { await exportToFiles() }
                        } label: {
                            Label("Save to Files\u{2026}", systemImage: "folder.badge.plus")
                        }
                        .disabled(!hasSequence)
                        .accessibilityIdentifier("export.files")
                    } footer: {
                        if !hasSequence { Text("The sequence is empty. Add clips to the timeline first.") }
                    }
                }

                if let message = model.exportMessage, !model.isExporting {
                    Section {
                        Label { Text(verbatim: message) } icon: { Image(systemName: "info.circle") }
                            .accessibilityIdentifier("exportMessage")
                    }
                }
                if movingFile != nil, !model.isExporting {
                    Section {
                        Button {
                            showMover = true
                        } label: {
                            Label("Choose a Location\u{2026}", systemImage: "folder")
                        }
                        .accessibilityIdentifier("exportChooseLocation")
                    } footer: {
                        Text("The movie is ready. Choose where in Files to keep it.")
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("exportSheet")
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { close() }
                        .accessibilityIdentifier("exportDone")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(model.isExporting)
        .fileMover(isPresented: $showMover, file: movingFile) { result in
            switch result {
            case .success(let url):
                model.exportMessage = "Saved to \(url.lastPathComponent)"
            case .failure(let error):
                // Dismissing the picker is not a failure: keep the movie so "Choose a Location" stays available.
                if (error as? CocoaError)?.code == .userCancelled { return }
                model.lastError = errorText(error)
            }
            discardTemporaryExport()
        }
    }

    /// 0...1, never NaN.
    private var progress: Double {
        guard let p = model.exportProgress, p.isFinite else { return 0 }
        return min(1, max(0, p))
    }

    private var summary: String {
        if let s = size(for: resolution) {
            return "\(s.width) \u{D7} \(s.height), H.264 + AAC"
        }
        return "\(model.state.width) \u{D7} \(model.state.height), H.264 + AAC"
    }

    private func close() {
        // A rendered movie that was never moved to Files is not kept.
        if !showMover { discardTemporaryExport() }
        model.showExport = false
        dismiss()
    }

    /// Removes the temporary render folder (and forgets the file).
    private func discardTemporaryExport() {
        if let file = movingFile {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        movingFile = nil
    }

    /// Renders into a temporary file, then lets the person move it anywhere in Files.
    private func exportToFiles() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FilmCraftExport-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            model.lastError = errorText(error)
            return
        }
        let target = folder.appendingPathComponent(fileName)
        await model.export(to: .files(target), options: options)
        if FileManager.default.fileExists(atPath: target.path) {
            movingFile = target
            showMover = true
        } else {
            // Failed or cancelled: nothing to keep.
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
