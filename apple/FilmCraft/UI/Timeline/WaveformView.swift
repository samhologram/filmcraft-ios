import SwiftUI
@preconcurrency import FilmCraftKit

/// Peak cache: one array per media (`audio_peaks`), shared by every clip of that media.
@MainActor
enum WaveformCache {
    private static let cache = NSCache<NSString, NSArray>()
    nonisolated static let buckets: UInt32 = 800

    static func peaks(model: EditorModel, mediaID: UInt64) async -> [Float]? {
        let key = "\(mediaID)-\(model.mediaVersion)" as NSString
        if let hit = cache.object(forKey: key) as? [Float] { return hit }
        // The bridge object is thread-safe (the engine locks internally) but not declared Sendable in Swift.
        let handle = UIUnchecked(model.handle)
        let buckets = Self.buckets
        let result: [Float]? = await Task.detached(priority: .utility) {
            try? handle.value.audioPeaks(mediaId: mediaID, buckets: buckets)
        }.value
        if let result { cache.setObject(result as NSArray, forKey: key) }
        return result
    }
}

/// The audio clip's waveform: the slice of the media's peaks the clip plays, drawn over the visible part only.
struct WaveformView: View {
    let model: EditorModel
    let clip: ClipInfo
    let mediaID: UInt64
    let x0: CGFloat
    let x1: CGFloat
    let visibleX0: CGFloat
    let visibleX1: CGFloat

    @State private var peaks: [Float] = []

    private var mediaDuration: Int64 { model.media.first { $0.id == mediaID }?.duration ?? 0 }

    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty, x1 > x0, mediaDuration > 0 else { return }
            let total = Double(mediaDuration)
            let clipLength = max(1, Double(clip.end) - Double(clip.start))
            let widthTotal = Double(x1 - x0)
            let midY = size.height / 2
            let step: CGFloat = 2
            var x: CGFloat = 0
            var path = Path()
            while x < size.width {
                // lane x -> fraction through the clip -> source time -> peak bucket
                let laneX = Double(visibleX0 + x)
                let fraction = min(1, max(0, (laneX - Double(x0)) / widthTotal))
                let source = Double(clip.sourceIn) + fraction * clipLength
                let position = (source / total) * Double(peaks.count)
                let index = position.isFinite ? Int(max(0, min(Double(peaks.count - 1), position))) : 0
                let amp = CGFloat(min(1, max(0, peaks[index])))
                let h = max(1, amp * size.height * 0.46)
                path.addRect(CGRect(x: x, y: midY - h, width: step - 0.5, height: h * 2))
                x += step
            }
            // Waveform drawn over the clip tint: fixed light content colour, independent of appearance.
            context.fill(path, with: .color(.white.opacity(0.75)))
        }
        .task(id: "\(mediaID)-\(model.mediaVersion)") {
            if let p = await WaveformCache.peaks(model: model, mediaID: mediaID) { peaks = p }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
