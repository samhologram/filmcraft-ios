import SwiftUI
import CoreGraphics
@preconcurrency import FilmCraftKit

/// Program frames and transport. Frames render off the main actor; requests coalesce (latest wins), so playback
/// drops frames instead of falling behind and scrubbing always ends on the frame under the playhead.
extension EditorModel {
    /// The playback engine (display link + audio), created on first use.
    var playback: PlaybackEngine {
        if let engine = playbackEngine { return engine }
        let engine = PlaybackEngine(model: self)
        playbackEngine = engine
        return engine
    }

    // MARK: Transport

    func togglePlay() {
        if isPlaying {
            playback.stop()
        } else {
            playback.play()
        }
    }

    /// Moves the playhead (engine + UI) and renders the frame there. While playing, playback restarts from `ticks`.
    func seek(_ ticks: Int64) {
        let clamped = min(max(0, ticks), max(0, state.duration))
        handle.setPlayhead(at: clamped)
        refreshLight()
        if isPlaying {
            playback.restart(at: clamped)
        } else {
            requestFrame(at: clamped)
        }
    }

    /// Steps `delta` frames (negative = back); stops playback first.
    func stepFrame(_ delta: Int) {
        if isPlaying { playback.stop() }
        let frame = Timecode.frameTicks(state)
        let (offset, overflow) = frame.multipliedReportingOverflow(by: Int64(delta))
        let base = state.playhead
        let (target, overflow2) = base.addingReportingOverflow(overflow ? 0 : offset)
        seek(overflow2 ? base : target)
    }

    func goToStart() { seek(0) }
    func goToEnd() { seek(state.duration) }

    // MARK: Frame rendering

    /// Pixel box for program frames: the viewer in pixels, capped (smaller while playing).
    var renderBox: (width: UInt32, height: UInt32) {
        let cap: CGFloat = isPlaying ? 1280 : 1920
        var width = viewerSize.width * viewerScale
        var height = viewerSize.height * viewerScale
        if !(width.isFinite && height.isFinite && width >= 16 && height >= 16) {
            width = 960
            height = 540
        }
        let scale = min(1, cap / max(width, height, 1))
        return (UInt32(max(16, (width * scale).rounded())), UInt32(max(16, (height * scale).rounded())))
    }

    /// Asks for the program frame at `ticks`. Coalesces with a render in flight.
    func requestFrame(at ticks: Int64) {
        pendingFrameTick = ticks
        guard !frameRenderBusy else { return }
        frameRenderBusy = true
        Task { [weak self] in await self?.drainFrameRequests() }
    }

    private func drainFrameRequests() async {
        while let tick = pendingFrameTick {
            pendingFrameTick = nil
            let box = renderBox
            let handle = self.handle
            let result = await Task.detached(priority: .userInitiated) {
                Self.renderProgramFrame(handle, tick, box.width, box.height)
            }.value
            switch result {
            case .success(let image):
                programFrame = image.image
                framesRendered += 1
                if framesRendered == 1 { Log.playback.info("first program frame rendered") }
                if AppEnvironment.isDemo, !isDemoReady {
                    isDemoReady = true
                    Log.app.info("demo ready")
                }
            case .failure(let message):
                // No sequence, offline media...: the viewer shows black; not worth an alert on every scrub.
                if state.sequenceName == nil { programFrame = nil }
                Log.playback.error("program frame failed: \(message, privacy: .public)")
                if AppEnvironment.isDemo, !isDemoReady {
                    // Tests must not hang: demo is "ready" after the first attempt, whatever its outcome.
                    isDemoReady = true
                    Log.app.info("demo ready (first frame failed)")
                }
            }
        }
        frameRenderBusy = false
    }

    private enum FrameResult: Sendable {
        case success(SendableImage)
        case failure(String)
    }

    nonisolated private static func renderProgramFrame(_ handle: ProjectHandle, _ tick: Int64, _ width: UInt32, _ height: UInt32) -> FrameResult {
        do {
            let rendered = try handle.renderProgram(at: tick, maxW: width, maxH: height)
            guard let image = cgImage(from: rendered) else { return .failure("the frame buffer is malformed") }
            return .success(SendableImage(image: image))
        } catch {
            return .failure(errorText(error))
        }
    }

    // MARK: Images

    /// RGBA8 sRGB (alpha 255) -> CGImage; nil when the buffer does not match its size.
    nonisolated static func cgImage(from rendered: RenderedImage) -> CGImage? {
        let width = Int(rendered.width), height = Int(rendered.height)
        guard width > 0, height > 0, width <= 16384, height <= 16384,
              rendered.rgba.count == width * height * 4,
              let provider = CGDataProvider(data: rendered.rgba as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// A thumbnail of a media item (`edge` pixels on the long side), cached.
    func thumbnail(media id: UInt64, edge: Int) async -> CGImage? {
        let edge = min(max(edge, 16), 1024)
        let key = "\(id)-\(edge)-\(mediaVersion)" as NSString
        if let cached = thumbCache.object(forKey: key) { return cached }
        let handle = self.handle
        let result: SendableImage? = await Task.detached(priority: .utility) {
            guard let rendered = try? handle.mediaThumbnail(mediaId: id, edge: UInt32(edge)),
                  let image = Self.cgImage(from: rendered) else { return nil }
            return SendableImage(image: image)
        }.value
        guard let image = result?.image else { return nil }
        thumbCache.setObject(image, forKey: key)
        return image
    }

    /// Source-monitor frame for a media item (not cached).
    func sourceFrame(media id: UInt64, at ticks: Int64, maxSize: Int) async -> CGImage? {
        let handle = self.handle
        let edge = UInt32(min(max(maxSize, 16), 2048))
        let result: SendableImage? = await Task.detached(priority: .userInitiated) {
            guard let rendered = try? handle.renderSource(mediaId: id, at: ticks, maxW: edge, maxH: edge),
                  let image = Self.cgImage(from: rendered) else { return nil }
            return SendableImage(image: image)
        }.value
        return result?.image
    }

    /// Audio waveform peaks (0...1 per bucket) of a media item.
    func audioPeaks(media id: UInt64, buckets: Int) async -> [Float] {
        let handle = self.handle
        let count = UInt32(min(max(buckets, 1), 8192))
        return await Task.detached(priority: .utility) {
            (try? handle.audioPeaks(mediaId: id, buckets: count)) ?? []
        }.value
    }
}
