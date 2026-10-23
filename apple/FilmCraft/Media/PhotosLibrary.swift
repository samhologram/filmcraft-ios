import Foundation
@preconcurrency import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// Wraps a value PhotoKit hands out that is only used on one actor at a time.
struct Unchecked<T>: @unchecked Sendable {
    let value: T
}

/// Forwards PhotoKit's (off-main) change callbacks to the main actor.
private final class PhotoChangeForwarder: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private let onChange: @Sendable () -> Void
    init(_ onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    func photoLibraryDidChange(_ changeInstance: PHChange) { onChange() }
}

/// The device's Photos library (PhotoKit) as FilmCraft's media source: authorization, a live fetch of the videos
/// and images of the current album, the album list, thumbnails, and materializing originals into the media cache
/// (`Library/Caches/FilmCraftMedia/PH-<b64url(localIdentifier)>.<ext>`) so the engine can read them by path.
@MainActor @Observable
final class PhotosLibrary {
    private(set) var authorization: PHAuthorizationStatus
    /// Videos and images of the current source (the whole library, or `currentAlbum`), newest first.
    private(set) var assets: [PHAsset] = []
    /// Smart albums (Videos, Favorites, Recents) followed by the person's albums.
    private(set) var albums: [PHAssetCollection] = []
    /// nil = the whole library.
    private(set) var currentAlbum: PHAssetCollection?
    /// Bumps whenever the fetch changed, so views re-read `assets`.
    private(set) var revision = 0
    private(set) var loaded = false

    @ObservationIgnored private let imageManager = PHCachingImageManager()
    @ObservationIgnored private var forwarder: PhotoChangeForwarder?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    var isAuthorized: Bool { authorization == .authorized || authorization == .limited }
    var isLimited: Bool { authorization == .limited }
    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    init() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        imageManager.allowsCachingHighQualityImages = false
        Log.photos.info("Photos authorization: \(Self.describe(self.authorization), privacy: .public)")
        if isAuthorized { start() }
    }

    nonisolated static func describe(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorized: "authorized"
        case .limited: "limited"
        @unknown default: "unknown"
        }
    }

    // MARK: Authorization

    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        Log.photos.info("Photos authorization: \(Self.describe(self.authorization), privacy: .public)")
        if isAuthorized { start() }
    }

    /// Re-reads the status (after the person came back from Settings).
    func refreshStatus() {
        let new = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard new != authorization else { return }
        authorization = new
        Log.photos.info("Photos authorization: \(Self.describe(new), privacy: .public)")
        if isAuthorized { start() }
    }

    func presentLimitedPicker() {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let next = top?.presentedViewController { top = next }
        guard let top else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
    }

    private func start() {
        if forwarder == nil {
            let f = PhotoChangeForwarder { [weak self] in
                Task { @MainActor in self?.scheduleReload() }
            }
            forwarder = f
            PHPhotoLibrary.shared().register(f)
        }
        reload()
    }

    // MARK: Fetching

    nonisolated private static func fetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                        PHAssetMediaType.video.rawValue, PHAssetMediaType.image.rawValue)
        return options
    }

    /// Coalesces bursts of library changes into one refetch.
    private func scheduleReload() {
        guard reloadTask == nil else { return }
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.reloadTask = nil
            self?.reload()
        }
    }

    private func reload() {
        guard isAuthorized else { return }
        albums = Self.loadAlbums()
        if let current = currentAlbum, !albums.contains(where: { $0.localIdentifier == current.localIdentifier }) {
            currentAlbum = nil
        }
        applyCurrent()
        loaded = true
    }

    private func applyCurrent() {
        let options = Self.fetchOptions()
        let result: PHFetchResult<PHAsset>
        if let album = currentAlbum {
            result = PHAsset.fetchAssets(in: album, options: options)
        } else {
            result = PHAsset.fetchAssets(with: options)
        }
        var list: [PHAsset] = []
        list.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in list.append(asset) }
        assets = list
        revision += 1
        Log.photos.info("Photos fetch: \(list.count, privacy: .public) assets")
    }

    private static func loadAlbums() -> [PHAssetCollection] {
        var out: [PHAssetCollection] = []
        for subtype in [PHAssetCollectionSubtype.smartAlbumVideos, .smartAlbumFavorites, .smartAlbumRecentlyAdded] {
            PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil)
                .enumerateObjects { collection, _, _ in out.append(collection) }
        }
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            .enumerateObjects { collection, _, _ in out.append(collection) }
        return out
    }

    /// Selects an album (nil = the whole library).
    func select(album: PHAssetCollection?) {
        guard album?.localIdentifier != currentAlbum?.localIdentifier else { return }
        currentAlbum = album
        applyCurrent()
    }

    func asset(withIdentifier id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    // MARK: Thumbnails

    /// A thumbnail of `asset`, `edge` pixels on the long side; nil when unavailable.
    func thumbnail(for asset: PHAsset, edge: CGFloat) async -> UIImage? {
        let size = CGSize(width: edge, height: edge)
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false  // scrolling must not download iCloud originals
        let result = await Self.request(Unchecked(value: imageManager), Unchecked(value: asset), size, options)
        return result.value
    }

    nonisolated private static func request(_ manager: Unchecked<PHCachingImageManager>, _ asset: Unchecked<PHAsset>, _ size: CGSize, _ options: PHImageRequestOptions) async -> Unchecked<UIImage?> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Unchecked<UIImage?>, Never>) in
            manager.value.requestImage(for: asset.value, targetSize: size, contentMode: .aspectFill, options: options) { image, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true, image != nil { return }
                continuation.resume(returning: Unchecked(value: image))
            }
        }
    }

    // MARK: Materializing originals

    /// The media-cache file name prefix for Photos originals.
    nonisolated static let cachePrefix = "PH-"

    /// "ABC/L0/001" -> base64url without padding.
    nonisolated static func encodeIdentifier(_ id: String) -> String {
        Data(id.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated static func decodeIdentifier(_ encoded: String) -> String? {
        var text = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text.append("=") }
        guard let data = Data(base64Encoded: text), let id = String(data: data, encoding: .utf8), !id.isEmpty else { return nil }
        return id
    }

    /// The Photos local identifier encoded in a media-cache file name ("PH-<b64url>.<ext>"), if it is one.
    nonisolated static func localIdentifier(fromCacheName name: String) -> String? {
        let base = (name as NSString).deletingPathExtension
        guard base.hasPrefix(cachePrefix) else { return nil }
        return decodeIdentifier(String(base.dropFirst(cachePrefix.count)))
    }

    /// Writes the asset's original resource into the media cache (reused when present) and returns its path.
    func materialize(_ localIdentifier: String) async throws -> URL {
        let asset = asset(withIdentifier: localIdentifier)
        if let existing = Self.existingCacheFile(for: localIdentifier) {
            // Reuse unless the item was edited in Photos after the file was cached.
            let cached = (try? FileManager.default.attributesOfItem(atPath: existing.path)[.modificationDate] as? Date) ?? .distantFuture
            if asset == nil || (asset?.modificationDate ?? .distantPast) <= cached { return existing }
            try? FileManager.default.removeItem(at: existing)
        }
        guard let asset else {
            throw Self.error("The item is no longer in your Photos library.")
        }
        let resources = PHAssetResource.assetResources(for: asset)
        let wanted: [PHAssetResourceType] = asset.mediaType == .video ? [.video, .fullSizeVideo] : [.photo, .fullSizePhoto]
        guard let resource = wanted.compactMap({ type in resources.first { $0.type == type } }).first ?? resources.first else {
            throw Self.error("Photos has no original file for this item.")
        }
        var ext = (resource.originalFilename as NSString).pathExtension
        if ext.isEmpty { ext = UTType(resource.uniformTypeIdentifier)?.preferredFilenameExtension ?? (asset.mediaType == .video ? "mov" : "jpg") }
        AppEnvironment.ensureDirectory(AppEnvironment.mediaCacheDirectory)
        let destination = AppEnvironment.mediaCacheDirectory
            .appendingPathComponent(Self.cachePrefix + Self.encodeIdentifier(localIdentifier))
            .appendingPathExtension(ext.lowercased())
        Log.media.info("materializing \(destination.lastPathComponent, privacy: .public)")
        try await Self.write(Unchecked(value: resource), to: destination)
        Log.media.info("materialized \(destination.lastPathComponent, privacy: .public)")
        return destination
    }

    /// A non-empty cache file already holding this identifier's original, if any.
    nonisolated private static func existingCacheFile(for localIdentifier: String) -> URL? {
        let stem = cachePrefix + encodeIdentifier(localIdentifier)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: AppEnvironment.mediaCacheDirectory.path)) ?? []
        for name in names where (name as NSString).deletingPathExtension == stem {
            let url = AppEnvironment.mediaCacheDirectory.appendingPathComponent(name)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            if size > 0 { return url }
        }
        return nil
    }

    nonisolated private static func write(_ resource: Unchecked<PHAssetResource>, to destination: URL) async throws {
        let partial = destination.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true  // iCloud originals download on demand
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(for: resource.value, toFile: partial, options: options) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    nonisolated static func error(_ message: String) -> NSError {
        NSError(domain: "FilmCraft", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
