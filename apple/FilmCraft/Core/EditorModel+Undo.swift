import Foundation
@preconcurrency import FilmCraftKit

/// Undo integration.
///
/// The engine owns the real history. The system `UndoManager` only mirrors it: every engine history step
/// registers one entry whose handler asks the engine to undo, and registers the symmetric redo inside it.
/// That makes the three-finger swipe, Cmd-Z, shake-to-undo and the document's dirty state (autosave) work.
extension EditorModel {
    func undo() {
        guard state.canUndo else { return }
        if let manager = undoManager, manager.canUndo {
            manager.undo()  // its handler performs the engine step
        } else {
            stepEngine(undo: true)
        }
    }

    func redo() {
        guard state.canRedo else { return }
        if let manager = undoManager, manager.canRedo {
            manager.redo()
        } else {
            stepEngine(undo: false)
        }
    }

    /// Registers one undo entry for the history step the engine just recorded.
    func registerUndoStep(label: String?) {
        guard let manager = undoManager else { return }
        // One engine step = one undo group (not one per run-loop event), so Cmd-Z never steps back two steps.
        let own = !manager.isUndoing && !manager.isRedoing
        if own {
            manager.groupsByEvent = false
            manager.beginUndoGrouping()
        }
        manager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.managerRequestedUndo() }
        }
        if let label, !label.isEmpty, own { manager.setActionName(label) }
        if own { manager.endUndoGrouping() }
    }

    /// Invoked by the UndoManager while it is undoing: step the engine, file the redo.
    private func managerRequestedUndo() {
        stepEngine(undo: true)
        guard let manager = undoManager else { return }
        manager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.managerRequestedRedo() }
        }
        if let label = state.redoLabel, !label.isEmpty { manager.setActionName(label) }
    }

    private func managerRequestedRedo() {
        stepEngine(undo: false)
        guard let manager = undoManager else { return }
        manager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.managerRequestedUndo() }
        }
        if let label = state.undoLabel, !label.isEmpty { manager.setActionName(label) }
    }

    private func stepEngine(undo: Bool) {
        do {
            let label = try (undo ? handle.undo() : handle.redo())
            Log.command.info("\(undo ? "undo" : "redo", privacy: .public): \(label ?? "-", privacy: .public)")
        } catch {
            lastError = errorText(error)
        }
        undoRedoTick += 1
        refresh()
        requestFrame(at: state.playhead)
    }
}
