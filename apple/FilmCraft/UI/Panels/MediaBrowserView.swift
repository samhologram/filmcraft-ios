import SwiftUI
import UIKit
import Photos
import UniformTypeIdentifiers
@preconcurrency import FilmCraftKit

/// Sheet wrapper (`showMediaBrowser`): the browser with a Done button.
struct MediaBrowserSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            MediaBrowserView(model: model)
                .navigationTitle("Add Media")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            model.showMediaBrowser = false
                            dismiss()
                        }
                        .accessibilityIdentifier("mediaBrowserDone")
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// The Media panel: the Photos library directly (albums, videos and photos; "+" inserts at the playhead), the
/// project's media, and a Files import. Nothing is "imported" first for Photos items.
struct MediaBrowserView: View {
    let model: EditorModel

    private enum Source { case photos, project }

    @State private var source: Source = .photos
    @State private var importing = false

    var body: some View {
        VStack(spacing: 0) {
            header
            switch source {
            case .photos: PhotosBrowserView(model: model)
            case .project: ProjectMediaList(model: model)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mediaBrowser")
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.movie, .audiovisualContent, .audio, .image],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await model.addFiles(urls, insertAtPlayhead: false) }
                source = .project
            case .failure(let error):
                model.lastError = errorText(error)
            }
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            headerRow(labels: true)
            headerRow(labels: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func headerRow(labels: Bool) -> some View {
        HStack(spacing: 8) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    sourceButton(.photos, "Photos", "photo.on.rectangle", id: "import.photos", labels: labels)
                    sourceButton(.project, "Project", "film.stack", id: "mediaProjectTab", labels: labels)
                }
            }
            Spacer(minLength: 4)
            Button {
                importing = true
            } label: {
                if labels {
                    Label("Files", systemImage: "folder.badge.plus").lineLimit(1)
                } else {
                    Image(systemName: "folder.badge.plus")
                }
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Import from Files")
            .accessibilityIdentifier("import.files")
        }
    }

    private func sourceButton(_ s: Source, _ title: LocalizedStringKey, _ symbol: String, id: String, labels: Bool) -> some View {
        Button {
            source = s
        } label: {
            if labels {
                Label(title, systemImage: symbol).lineLimit(1)
            } else {
                Image(systemName: symbol)
            }
        }
        .glassToggle(source == s)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(source == s ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}

// MARK: Photos

struct PhotosBrowserView: View {
    let model: EditorModel

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    /// The previewed asset by identifier: an index would point at another asset after the library changes.
    @State private var previewID: String?
    @State private var requestingAccess = false

    private var previewIndex: Int? {
        guard let id = previewID else { return nil }
        return photos.assets.firstIndex { $0.localIdentifier == id }
    }

    private var photos: PhotosLibrary { model.photos }

    var body: some View {
        Group {
            if photos.isDenied {
                ContentUnavailableView {
                    Label("Photos Access Needed", systemImage: "photo.badge.exclamationmark")
                } description: {
                    Text("FilmCraft edits the videos and photos in your Photos library. Allow access in Settings to see them here.")
                } actions: {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("photos.openSettings")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("photos.denied")
            } else if !photos.isAuthorized {
                ProgressView("Requesting access\u{2026}")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task {
                        // Only ask while undetermined, and not again if this task restarts mid-prompt.
                        guard photos.authorization == .notDetermined, !requestingAccess else { return }
                        requestingAccess = true
                        await photos.requestAccess()
                        requestingAccess = false
                    }
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: scenePhase) { _, phase in if phase == .active { photos.refreshStatus() } }
    }

    private var content: some View {
        VStack(spacing: 0) {
            if photos.isLimited { limitedBanner }
            albumRow
            if let index = previewIndex, photos.assets.indices.contains(index) {
                PhotoPreview(model: model, index: index, asset: photos.assets[index]) { previewID = nil }
            }
            if photos.assets.isEmpty {
                ContentUnavailableView("No Media", systemImage: "photo",
                                       description: Text("There are no videos or photos in this album."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92, maximum: 150), spacing: 3)], spacing: 3) {
                        ForEach(0..<photos.assets.count, id: \.self) { index in
                            AssetCell(model: model, index: index, selected: photos.assets.indices.contains(index) && photos.assets[index].localIdentifier == previewID) {
                                guard photos.assets.indices.contains(index) else { return }
                                let id = photos.assets[index].localIdentifier
                                previewID = (previewID == id) ? nil : id
                            }
                        }
                    }
                    .padding(3)
                }
                .accessibilityIdentifier("assetGrid")
            }
        }
    }

    private var limitedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary).accessibilityHidden(true)
            Text("FilmCraft can only see the items you selected.")
                .font(.footnote)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("Manage") { photos.presentLimitedPicker() }
                .buttonStyle(.glass)
                .controlSize(.small)
                .accessibilityIdentifier("photos.manage")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("photos.limited")
    }

    private var albumRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                albumChip(title: String(localized: "Library"), selected: photos.currentAlbum == nil, id: "album.all") {
                    photos.select(album: nil)
                    previewID = nil
                }
                ForEach(Array(photos.albums.enumerated()), id: \.offset) { index, album in
                    albumChip(title: album.localizedTitle ?? String(localized: "Album"),
                              selected: photos.currentAlbum?.localIdentifier == album.localIdentifier,
                              id: "album.\(index)") {
                        photos.select(album: album)
                        previewID = nil
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }

    private func albumChip(title: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title).font(.subheadline).lineLimit(1).padding(.horizontal, 6)
        }
        .glassToggle(selected)
        .controlSize(.small)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}

/// One thumbnail: tap previews, the "+" inserts at the playhead.
private struct AssetCell: View {
    let model: EditorModel
    let index: Int
    let selected: Bool
    let onTap: () -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    private var photos: PhotosLibrary { model.photos }
    private var asset: PHAsset? { photos.assets.indices.contains(index) ? photos.assets[index] : nil }

    var body: some View {
        ZStack {
            Button(action: onTap) {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        ZStack {
                            Color(uiColor: .secondarySystemFill)
                            if let image { Image(uiImage: image).resizable().scaledToFill() }
                        }
                    }
                    .clipped()
                    .overlay {
                        if selected { RoundedRectangle(cornerRadius: 2).stroke(Color.accentColor, lineWidth: 3) }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("asset.\(index)")
            // Siblings of the thumbnail button, so the "+" stays its own control.
            .overlay(alignment: .bottomLeading) { badge.allowsHitTesting(false) }
            .overlay(alignment: .bottomTrailing) { addButton }
        }
        .task(id: "\(photos.revision)-\(index)") {
            guard let asset else { return }
            image = await photos.thumbnail(for: asset, edge: max(96, 120 * displayScale))
        }
    }

    private var label: String {
        guard let asset else { return "Item \(index + 1)" }
        return asset.mediaType == .video ? "Video \(index + 1), \(uiClock(asset.duration))" : "Photo \(index + 1)"
    }

    @ViewBuilder
    private var badge: some View {
        if let asset, asset.mediaType == .video {
            Text(verbatim: uiClock(asset.duration))
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(4)
        }
    }

    private var addButton: some View {
        Button {
            guard let id = asset?.localIdentifier else { return }
            Task { await model.addFromPhotos([id], insertAtPlayhead: true) }
        } label: {
            Image(systemName: "plus")
                .font(.footnote.weight(.bold))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .padding(4)
        .accessibilityLabel("Add to timeline")
        .accessibilityIdentifier("assetAdd_\(index)")
    }
}

/// The larger preview of the tapped item with an "Add to Timeline" button.
private struct PhotoPreview: View {
    let model: EditorModel
    let index: Int
    let asset: PHAsset
    let close: () -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Color.black
                if let image { Image(uiImage: image).resizable().scaledToFit() }
            }
            .frame(width: 150, height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(asset.mediaType == .video ? "Video" : "Photo").font(.subheadline.weight(.semibold))
                Text(verbatim: asset.mediaType == .video ? "\(uiClock(asset.duration)) \u{B7} \(asset.pixelWidth)\u{D7}\(asset.pixelHeight)" : "\(asset.pixelWidth)\u{D7}\(asset.pixelHeight)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await model.addFromPhotos([asset.localIdentifier], insertAtPlayhead: true) }
                } label: {
                    Label("Add to Timeline", systemImage: "plus").lineLimit(1)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .accessibilityIdentifier("photoPreviewAdd")
            }
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close preview")
            .accessibilityIdentifier("photoPreviewClose")
        }
        .padding(10)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("photoPreview")
        .task(id: asset.localIdentifier) {
            image = await model.photos.thumbnail(for: asset, edge: 400 * displayScale)
        }
    }
}

// MARK: Project media

private struct ProjectMediaList: View {
    let model: EditorModel

    var body: some View {
        if model.media.isEmpty {
            ContentUnavailableView("No Project Media", systemImage: "film.stack",
                                   description: Text("Media you add from Photos or Files appears here."))
                .frame(maxHeight: .infinity)
        } else {
            List(model.media, id: \.id) { item in
                ProjectMediaRow(model: model, item: item)
            }
            .listStyle(.plain)
            .accessibilityIdentifier("projectMediaList")
        }
    }
}

private struct ProjectMediaRow: View {
    let model: EditorModel
    let item: MediaInfo

    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?

    private var symbol: String {
        switch item.kind {
        case "audio": return "waveform"
        case "image": return "photo"
        case "graphic": return "textformat"
        default: return "film"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Color(uiColor: .secondarySystemFill)
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else {
                    Image(systemName: symbol).foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.name).font(.subheadline).lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.caption2)
                    Text(verbatim: item.duration > 0 ? Timecode.string(item.duration, model.state) : item.kind)
                        .font(.caption.monospacedDigit())
                    if item.offline {
                        Label("Offline", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button {
                model.run("timeline.place", ["item": item.id, "time": model.state.playhead, "insert": true])
            } label: {
                Image(systemName: "plus").frame(width: 28, height: 28)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(item.offline || model.state.sequenceName == nil)
            .accessibilityLabel("Insert at playhead")
            .accessibilityIdentifier("mediaAdd_\(item.id)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("media.\(item.id)")
        .task(id: "\(item.id)-\(model.mediaVersion)") {
            image = await model.thumbnail(media: item.id, edge: Int(96 * displayScale))
        }
    }
}
