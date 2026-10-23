import Foundation
import Testing
import FilmCraftKit

/// Smoke tests of the Rust bridge as the app sees it (hosted in the app's test bundle, no UI).
/// Every test builds its own handle: handles are independent engine sessions, so tests can run in parallel.
@Suite struct BridgeSmokeTests {
    private func clipCount(_ handle: ProjectHandle) -> Int {
        handle.timeline().tracks.reduce(0) { $0 + $1.clips.count }
    }

    // MARK: Catalogs

    @Test func engineVersionIsReported() {
        #expect(engineVersion().hasPrefix("filmcraft-apple"))
        #expect(ticksPerSecond() == 254_016_000_000)
    }

    @Test func commandCatalogsAreLoaded() {
        let engine = commandCatalog()
        #expect(engine.count > 300)
        #expect(engine.contains { $0.id == "edit.undo" })
        #expect(engine.contains { $0.id == "sequence.addEdit" })
        // Ids are unique: menus, the palette and the tours key on them.
        #expect(Set(engine.map(\.id)).count == engine.count)
        let ui = uiCommandCatalog()
        #expect(ui.contains { $0.id == "playback.toggle" })
        #expect(ui.allSatisfy { !$0.id.isEmpty && !$0.label.isEmpty })
    }

    @Test func menuLayoutFollowsTheDesktopOrder() {
        let titles = desktopMenuLayout().map(\.title)
        #expect(titles == ["File", "Edit", "Clip", "Sequence", "Markers", "Graphics and Titles", "View", "Window", "Help"])
        #expect(desktopMenuLayout().allSatisfy { !$0.items.isEmpty })
    }

    @Test func toolsAndPanelsAreLoaded() {
        let tools = timelineTools()
        #expect(tools.count >= 15)
        #expect(tools.contains { $0.id == "tool.selection" })
        #expect(tools.first { $0.id == "tool.razor" }?.shortcut == "C")
        #expect(tools.allSatisfy { $0.id.hasPrefix("tool.") })
        let panels = panelCatalog()
        for id in ["panel.timeline", "panel.program", "panel.project", "panel.effectControls"] {
            #expect(panels.contains { $0.id == id }, "missing \(id)")
        }
        #expect(panels.allSatisfy { $0.id.hasPrefix("panel.") && !$0.title.isEmpty })
    }

    @Test func commandParamsParse() {
        let fields = commandParams(id: "file.exportMedia")
        #expect(fields.contains { $0.key == "path" })
        #expect(fields.allSatisfy { !$0.key.isEmpty })
        #expect(commandParams(id: "nope.nothing").isEmpty)
        #expect(commandParams(id: "").isEmpty)
    }

    @Test func platformSupportAnswersForUnknownIds() {
        // Unknown ids are not excluded (nil) and never crash.
        #expect(commandPlatformSupport(id: "no.such.command") == nil)
        #expect(commandPlatformSupport(id: "") == nil)
    }

    // MARK: Timecode

    @Test func timecodeFormatting() {
        #expect(formatTimecode(ticks: 0, fpsNum: 24, fpsDen: 1) == "00:00:00:00")
        let oneSecond = ticksPerSecond()
        #expect(formatTimecode(ticks: oneSecond, fpsNum: 24, fpsDen: 1) == "00:00:01:00")
        #expect(formatTimecode(ticks: oneSecond * 61, fpsNum: 25, fpsDen: 1) == "00:01:01:00")
        // Degenerate rates and extreme ticks fall back instead of crashing.
        #expect(!formatTimecode(ticks: Int64.min, fpsNum: 0, fpsDen: 0).isEmpty)
        #expect(!formatTimecode(ticks: Int64.max, fpsNum: UInt32.max, fpsDen: UInt32.max).isEmpty)
    }

    // MARK: Demo project

    @Test func newProjectHasASequence() {
        let handle = ProjectHandle.newProject(name: "Test")
        let state = handle.state()
        #expect(state.projectName == "Test")
        #expect(state.sequenceName != nil)
        #expect(!state.canUndo)
    }

    @Test func demoHasMediaAndClips() {
        let handle = ProjectHandle.demo()
        let state = handle.state()
        #expect(state.mediaCount > 0)
        #expect(state.sequenceName != nil)
        #expect(state.duration > 0 && state.width > 0 && state.height > 0 && state.fpsNum > 0)
        #expect(!handle.media().isEmpty)
        #expect(clipCount(handle) > 0)
        #expect(handle.timeline().tracks.contains { !$0.clips.isEmpty })
    }

    // MARK: Commands, history

    @Test func journaledCommandMovesHistoryAndUndoRedoFollow() throws {
        let handle = ProjectHandle.newProject(name: "History")
        let base = handle.state()
        #expect(!base.canUndo && !base.canRedo)
        _ = try handle.execute(id: "file.newBin", paramsJson: #"{"name":"B"}"#)
        let after = handle.state()
        #expect(after.historyId != base.historyId)
        #expect(after.canUndo)
        #expect(try handle.undo() != nil)
        let undone = handle.state()
        #expect(undone.historyId != after.historyId)
        #expect(undone.canRedo)
        #expect(!undone.canUndo)
        #expect(try handle.redo() != nil)
        #expect(handle.state().canUndo)
    }

    @Test func interactionIsOneUndoStep() throws {
        let handle = ProjectHandle.newProject(name: "Drag")
        try handle.beginInteraction(label: "Drag")
        _ = try handle.execute(id: "file.newBin", paramsJson: #"{"name":"A"}"#)
        _ = try handle.execute(id: "file.newBin", paramsJson: #"{"name":"B"}"#)
        try handle.endInteraction()
        #expect(handle.state().undoLabel == "Drag")
        _ = try handle.undo()
        #expect(!handle.state().canUndo, "the whole drag undoes in one step")
    }

    @Test func disabledReasons() {
        let handle = ProjectHandle.newProject(name: "T")
        #expect(handle.disabledReason(id: "edit.cut") != nil, "nothing is selected")
        #expect(handle.disabledReason(id: "no.such") != nil, "unknown ids are reported as disabled")
    }

    // MARK: Rendering and audio

    @Test func renderProgramReturnsWidthHeightFourBytes() throws {
        let handle = ProjectHandle.demo()
        let image = try handle.renderProgram(at: 0, maxW: 320, maxH: 180)
        #expect(image.width > 0 && image.width <= 320)
        #expect(image.height > 0 && image.height <= 180)
        #expect(image.rgba.count == Int(image.width) * Int(image.height) * 4)
    }

    @Test func thumbnailsMatchTheirSize() throws {
        let handle = ProjectHandle.demo()
        let video = try #require(handle.media().first { $0.hasVideo })
        let thumb = try handle.mediaThumbnail(mediaId: video.id, edge: 64)
        #expect(thumb.rgba.count == Int(thumb.width) * Int(thumb.height) * 4)
    }

    @Test func mixAudioReturnsFramesTimesChannels() throws {
        let handle = ProjectHandle.demo()
        for (frames, rate) in [(UInt32(1024), UInt32(48_000)), (1000, 44_100)] {
            let block = try handle.mixAudio(from: 0, frames: frames, sampleRate: rate)
            #expect(block.sampleRate == rate)
            #expect(block.channels >= 1)
            #expect(block.samples.count == Int(frames) * Int(block.channels))
        }
    }

    // MARK: Persistence

    @Test func projectJsonRoundTripsClipCount() throws {
        let handle = ProjectHandle.demo()
        let clips = clipCount(handle)
        #expect(clips > 0)
        let json = try handle.projectJson()
        let reopened = try ProjectHandle.openJson(json: json, pathHint: nil)
        #expect(clipCount(reopened) == clips)
        #expect(!reopened.state().canUndo)
        #expect(!reopened.state().dirty)
    }

    // MARK: Hostile inputs: throw, never crash

    @Test func hostileCommandInputsThrow() {
        let handle = ProjectHandle.newProject(name: "Hostile")
        #expect(throws: (any Error).self) { try handle.execute(id: "no.such.command", paramsJson: "{}") }
        #expect(throws: (any Error).self) { try handle.execute(id: "edit.undo", paramsJson: "{garbage") }
        #expect(throws: (any Error).self) { try handle.execute(id: "timeline.trim", paramsJson: #"{"clip":-5,"delta":"x"}"#) }
        #expect(throws: (any Error).self) { try handle.execute(id: "", paramsJson: "") }
    }

    @Test func hostileProjectJsonThrows() {
        #expect(throws: (any Error).self) { try ProjectHandle.openJson(json: "not json", pathHint: nil) }
        #expect(throws: (any Error).self) { try ProjectHandle.openJson(json: "", pathHint: nil) }
    }

    @Test func hostileSizesAndIdsThrow() {
        let handle = ProjectHandle.demo()
        #expect(throws: (any Error).self) { try handle.mixAudio(from: 0, frames: 0, sampleRate: 48_000) }
        #expect(throws: (any Error).self) { try handle.mixAudio(from: 0, frames: UInt32.max, sampleRate: 48_000) }
        #expect(throws: (any Error).self) { try handle.mixAudio(from: 0, frames: 100, sampleRate: 0) }
        #expect(throws: (any Error).self) { try handle.audioPeaks(mediaId: UInt64.max, buckets: 100) }
        #expect(throws: (any Error).self) { try handle.renderSource(mediaId: UInt64.max, at: -1, maxW: 10, maxH: 10) }
        #expect(throws: (any Error).self) { try handle.mediaThumbnail(mediaId: UInt64.max, edge: UInt32.max) }
        #expect(throws: (any Error).self) { try handle.importFiles(paths: []) }
        #expect(throws: (any Error).self) { try handle.importFiles(paths: ["/nonexistent/file.mp4"]) }
        #expect(throws: (any Error).self) { try handle.startExport(path: "", optionsJson: "{}") }
        #expect(handle.jobStatus(jobId: 999) == nil)
    }

    @Test func hostileNumbersNeverCrash() throws {
        let handle = ProjectHandle.demo()
        handle.setPlayhead(at: Int64.min)
        handle.setPlayhead(at: Int64.max)
        _ = handle.state()
        // Huge render sizes are clamped (an image) or rejected (an error), never a crash or a giant allocation.
        if let image = try? handle.renderProgram(at: Int64.max, maxW: UInt32.max, maxH: UInt32.max) {
            #expect(image.rgba.count == Int(image.width) * Int(image.height) * 4)
            #expect(image.width <= 8192 && image.height <= 8192)
        }
        _ = handle.relinkMissing(resolverDir: "/nonexistent")
        handle.cancelJob(jobId: UInt64.max)
    }
}
