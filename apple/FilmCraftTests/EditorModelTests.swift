import Foundation
import Testing
@preconcurrency import FilmCraftKit
@testable import FilmCraft

/// `EditorModel` mirrors the engine's history on the scene's `UndoManager`: one registration per history step.
/// The manager's automatic per-event grouping is switched off and every action gets its own group, so one
/// `manager.undo()` undoes exactly one registered step.
@MainActor
@Suite struct EditorModelTests {
    private func makeModel() -> (EditorModel, UndoManager) {
        let model = EditorModel(handle: ProjectHandle.newProject(name: "Undo"))
        let manager = UndoManager()
        manager.groupsByEvent = false
        model.undoManager = manager
        return (model, manager)
    }

    private func grouped(_ manager: UndoManager, _ body: () -> Void) {
        manager.beginUndoGrouping()
        body()
        manager.endUndoGrouping()
    }

    @Test func runRegistersOneUndoStepPerCommand() throws {
        let (model, manager) = makeModel()
        #expect(!manager.canUndo)
        let base = model.state.historyId
        let initialProject = try model.handle.projectJson()
        grouped(manager) { model.run("file.newBin", ["name": "A"]) }
        #expect(model.state.historyId != base)
        #expect(manager.canUndo)
        let afterFirst = model.state.historyId
        let firstProject = try model.handle.projectJson()
        grouped(manager) { model.run("file.newBin", ["name": "B"]) }
        #expect(model.state.historyId != afterFirst)
        let secondProject = try model.handle.projectJson()
        #expect(secondProject != firstProject)

        manager.undo()
        #expect(model.state.historyId != afterFirst, "undo is a new history transition")
        #expect(try model.handle.projectJson() == firstProject, "one manager step undoes only the last bin")
        #expect(model.state.canUndo)
        #expect(model.state.canRedo)
        #expect(manager.canRedo)
        #expect(model.lastError == nil)

        manager.undo()
        #expect(try model.handle.projectJson() == initialProject)
        #expect(!model.state.canUndo)
        #expect(model.lastError == nil)

        manager.redo()
        #expect(model.state.canUndo)
        #expect(try model.handle.projectJson() == firstProject, "redo restores the first command")
        manager.redo()
        #expect(try model.handle.projectJson() == secondProject, "the second redo restores the second command")
        #expect(model.lastError == nil)
    }

    @Test func modelUndoAndRedoGoThroughTheManager() {
        let (model, manager) = makeModel()
        grouped(manager) { model.run("file.newBin", ["name": "A"]) }
        #expect(model.state.canUndo)
        model.undo()
        #expect(!model.state.canUndo)
        #expect(model.state.canRedo)
        #expect(manager.canRedo)
        model.redo()
        #expect(model.state.canUndo)
        #expect(model.lastError == nil)
    }

    @Test func undoWithoutManagerStillStepsTheEngine() {
        let model = EditorModel(handle: ProjectHandle.newProject(name: "NoManager"))
        model.run("file.newBin", ["name": "A"])
        #expect(model.state.canUndo)
        model.undo()
        #expect(!model.state.canUndo)
        model.redo()
        #expect(model.state.canUndo)
    }

    @Test func dragIsOneUndoStep() {
        let (model, manager) = makeModel()
        grouped(manager) {
            model.beginDrag("Drag")
            model.run("file.newBin", ["name": "A"])
            model.run("file.newBin", ["name": "B"])
            model.endDrag()
        }
        #expect(model.state.canUndo)
        manager.undo()
        #expect(!model.state.canUndo, "the whole interaction is one undo step")
        #expect(model.lastError == nil)
        #expect(!manager.canUndo)
    }

    @Test func failedCommandRecordsTheFullMessageAndNoStep() {
        let (model, manager) = makeModel()
        let ok = model.run("no.such.command")
        #expect(!ok)
        #expect(model.lastError?.isEmpty == false)
        #expect(!model.state.canUndo)
        #expect(!manager.canUndo)
    }

    @Test func zoomIsClamped() {
        #expect(EditorModel.clampZoom(.nan) == 80)
        #expect(EditorModel.clampZoom(-5) == 2)
        #expect(EditorModel.clampZoom(1e12) == 4000)
    }

    @Test func toolAndPanelStateFollowRunUI() {
        let (model, _) = makeModel()
        #expect(model.runUI("tool.razor"))
        #expect(model.activeTool == "tool.razor")
        #expect(!model.runUI("tool.noSuchTool"))
        #expect(model.lastError?.contains("tool.noSuchTool") == true)
        model.lastError = nil
        #expect(model.runUI("panel.effects"))
        #expect(model.activePanel == "panel.effects")
        #expect(model.inspectorVisible)
    }
}
