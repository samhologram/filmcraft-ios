import AVFoundation
import QuartzCore
import os
@preconcurrency import FilmCraftKit

// MARK: - Audio ring buffer

/// A fixed-capacity stereo ring buffer of interleaved Float32 frames, guarded by an unfair lock.
/// A background task fills it from the engine mix; the realtime audio callback only copies out of it (it never
/// calls into Rust and never allocates).
final class AudioRing: @unchecked Sendable {
    private let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var readPos = 0
    private var count = 0  // frames

    init(capacityFrames: Int) {
        capacity = max(256, capacityFrames)
        storage = UnsafeMutablePointer<Float>.allocate(capacity: capacity * 2)
        storage.initialize(repeating: 0, count: capacity * 2)
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        storage.deallocate()
        lock.deallocate()
    }

    var availableFrames: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return count
    }

    var freeFrames: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return capacity - count
    }

    func reset() {
        os_unfair_lock_lock(lock)
        readPos = 0
        count = 0
        os_unfair_lock_unlock(lock)
    }

    /// Appends interleaved `channels`-channel samples (mono is duplicated, extra channels dropped). Returns the
    /// number of frames stored (fewer than offered when the ring is full).
    @discardableResult
    func write(_ samples: [Float], channels: Int) -> Int {
        guard channels >= 1, !samples.isEmpty else { return 0 }
        let offered = samples.count / channels
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let frames = min(offered, capacity - count)
        var writePos = (readPos + count) % capacity
        for frame in 0..<frames {
            let left = samples[frame * channels]
            let right = channels >= 2 ? samples[frame * channels + 1] : left
            storage[writePos * 2] = left
            storage[writePos * 2 + 1] = right
            writePos += 1
            if writePos == capacity { writePos = 0 }
        }
        count += frames
        return frames
    }

    /// Copies up to `frames` frames into the two channel buffers, zero-filling any shortfall (underrun).
    /// Realtime-safe: no allocation, no Swift runtime calls beyond the lock.
    func read(left: UnsafeMutablePointer<Float>?, right: UnsafeMutablePointer<Float>?, frames: Int) {
        os_unfair_lock_lock(lock)
        let available = min(frames, count)
        var pos = readPos
        for frame in 0..<available {
            left?[frame] = storage[pos * 2]
            right?[frame] = storage[pos * 2 + 1]
            pos += 1
            if pos == capacity { pos = 0 }
        }
        readPos = pos
        count -= available
        os_unfair_lock_unlock(lock)
        if available < frames {
            for frame in available..<frames {
                left?[frame] = 0
                right?[frame] = 0
            }
        }
    }
}

// MARK: - Display link proxy

/// CADisplayLink retains its target: this proxy holds the engine weakly so stopping is never forgotten.
@MainActor
private final class DisplayLinkProxy: NSObject {
    weak var engine: PlaybackEngine?
    @objc func tick(_ link: CADisplayLink) { engine?.tick() }
}

// MARK: - Playback engine

/// Playback: a CADisplayLink advances the playhead at the sequence frame rate against the wall clock (frames render
/// off the main actor and are dropped when behind); audio is mixed by the engine on a background task into a ring
/// buffer that an `AVAudioSourceNode` drains on the audio thread.
@MainActor
final class PlaybackEngine {
    nonisolated static let sampleRate: Double = 48_000

    private weak var model: EditorModel?
    private var link: CADisplayLink?
    private let proxy = DisplayLinkProxy()
    private var audioEngine: AVAudioEngine?
    private var ring: AudioRing?
    private var fillTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?

    private var startTick: Int64 = 0
    private var requestedAt: CFTimeInterval = 0
    private var clockStart: CFTimeInterval?
    private var audioWanted = true
    private var lastTick: Int64 = -1
    /// Playback stops when the playhead reaches this tick (in-to-out playback); nil = end of sequence.
    var stopTick: Int64?

    init(model: EditorModel) {
        self.model = model
        proxy.engine = self
    }

    // MARK: Start / stop

    func play() {
        guard let model, !model.isPlaying else { return }
        let state = model.state
        guard state.duration > 0 else { return }
        var from = state.playhead
        if from >= (stopTick ?? state.duration) - Timecode.frameTicks(state) { from = stopTick == nil ? 0 : (state.inPoint ?? 0) }
        begin(at: from)
        Log.playback.info("play from \(from, privacy: .public)")
    }

    /// Restarts from `ticks` while playing (a seek during playback).
    func restart(at ticks: Int64) {
        guard let model, model.isPlaying else { return }
        // Keep the audio engine and ring (no gaps, no session churn): only the clock, link and fill task restart.
        link?.invalidate()
        link = nil
        fillTask?.cancel()
        fillTask = nil
        ring?.reset()
        begin(at: ticks)
    }

    func stop() {
        guard let model else { return }
        let was = model.isPlaying
        teardown()
        stopTick = nil
        model.isPlaying = false
        model.refreshLight()
        model.requestFrame(at: model.state.playhead)
        if was { Log.playback.info("stop at \(model.state.playhead, privacy: .public)") }
    }

    private func begin(at ticks: Int64) {
        guard let model else { return }
        startTick = ticks
        clockStart = nil
        requestedAt = CACurrentMediaTime()
        model.handle.setPlayhead(at: ticks)
        model.isPlaying = true
        startAudio(from: ticks)
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        let fps = Float(Timecode.fps(model.state))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(24, fps), maximum: max(30, min(120, fps)), preferred: fps)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func teardown() {
        link?.invalidate()
        link = nil
        fillTask?.cancel()
        fillTask = nil
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        if let engine = audioEngine {
            engine.stop()
            audioEngine = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        ring?.reset()
        ring = nil
        clockStart = nil
    }

    // MARK: Display link

    fileprivate func tick() {
        guard let model, model.isPlaying else {
            teardown()  // the model is gone (or stopped elsewhere): never leave the link or audio running
            return
        }
        let now = CACurrentMediaTime()
        // Wait until the first audio is buffered (or give up after half a second), so sound and picture start together.
        if clockStart == nil {
            let ready = ring.map { $0.availableFrames >= 2048 } ?? true
            guard ready || now - requestedAt > 0.5 else { return }
            clockStart = now
        }
        guard let clockStart else { return }
        let state = model.state
        let elapsed = Timecode.ticks(seconds: now - clockStart)
        let (sum, overflow) = startTick.addingReportingOverflow(elapsed)
        let end = min(state.duration, stopTick ?? state.duration)
        var target = overflow ? end : sum
        let reachedEnd = target >= end
        if reachedEnd { target = end }
        // Land on frame boundaries.
        let frame = Timecode.frameTicks(state)
        if !reachedEnd, frame > 0 { target -= target % frame }
        if target != lastTick || reachedEnd {  // assign `state` only when the frame changed (limits view invalidation)
            lastTick = target
            model.handle.setPlayhead(at: target)
            model.refreshLight()
            model.requestFrame(at: target)
        }
        if reachedEnd { stop() }
    }

    // MARK: Audio

    private func startAudio(from ticks: Int64) {
        guard audioWanted, let model else { return }
        if let ring, audioEngine != nil {  // restart: reuse the running engine
            startFill(model.handle, ring, ticks)
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            Log.playback.error("audio session: \(errorText(error), privacy: .public)")
            return
        }
        let ring = AudioRing(capacityFrames: Int(Self.sampleRate))  // one second
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 2, interleaved: false) else { return }
        let node = Self.makeSourceNode(ring: ring, format: format)
        let engine = AVAudioEngine()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            Log.playback.error("audio engine: \(errorText(error), privacy: .public)")
            return
        }
        self.ring = ring
        audioEngine = engine
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                == AVAudioSession.InterruptionType.began.rawValue
            guard began else { return }
            Task { @MainActor in self?.stop() }
        }
        startFill(model.handle, ring, ticks)
    }

    private func startFill(_ handle: ProjectHandle, _ ring: AudioRing, _ ticks: Int64) {
        fillTask = Task.detached(priority: .userInitiated) {
            await Self.fill(handle: handle, ring: ring, from: ticks)
        }
    }

    /// Built in a nonisolated context so the render block is not main-actor isolated (it runs on the audio thread).
    nonisolated private static func makeSourceNode(ring: AudioRing, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let left = buffers.count > 0 ? buffers[0].mData?.assumingMemoryBound(to: Float.self) : nil
            let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : left
            ring.read(left: left, right: right, frames: Int(frameCount))
            return noErr
        }
    }

    /// Pulls `mix_audio` blocks from the engine into the ring until cancelled.
    nonisolated private static func fill(handle: ProjectHandle, ring: AudioRing, from start: Int64) async {
        let chunk: UInt32 = 2048
        let rate = UInt32(sampleRate)
        let tps = Double(Timecode.ticksPerSecond)
        var framesMixed: Int64 = 0
        while !Task.isCancelled {
            guard ring.freeFrames >= Int(chunk) else {
                try? await Task.sleep(for: .milliseconds(15))
                continue
            }
            let offset = Int64(Double(framesMixed) / sampleRate * tps)
            let (tick, overflow) = start.addingReportingOverflow(offset)
            var samples: [Float] = []
            var channels = 2
            if !overflow, let block = try? handle.mixAudio(from: tick, frames: chunk, sampleRate: rate) {
                channels = max(1, Int(block.channels))
                samples = block.samples
            }
            if samples.count < Int(chunk) * channels {  // short block or error: pad with silence so time keeps moving
                samples.append(contentsOf: [Float](repeating: 0, count: Int(chunk) * channels - samples.count))
            }
            ring.write(samples, channels: channels)
            framesMixed += Int64(chunk)
        }
    }
}
