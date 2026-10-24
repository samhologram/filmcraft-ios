import XCTest

/// A movie editor must be able to cut a clip and recover the original edit, on either device.
@MainActor
final class UserStoryUITests: FilmCraftUITestCase {
    func testSplitClipUndoRedoPortrait() {
        XCUIDevice.shared.orientation = .portrait
        launchDemo(dark: false)
        defer {
            attachText(app.debugDescription, name: "split-story-hierarchy")
            flushNotes("split-story-notes")
        }
        XCTAssertTrue(element("timeline").waitForExistence(timeout: 10))
        XCTAssertNotNil(selectFirstClip(), "A seeded clip must be selectable")
        XCTAssertNotNil(hit("transport.stepForward"), "The editor needs frame stepping to choose a cut")
        stepForward(12)
        let before = Set(clipIDs)
        XCTAssertFalse(before.isEmpty)
        XCTAssertTrue(element("command.sequence.addEdit").isEnabled, "Split must be enabled inside the selected clip")
        XCTAssertTrue(tap("command.sequence.addEdit"))
        let split = NSPredicate { _, _ in Set(self.clipIDs).count > before.count }
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: split, evaluatedWith: nil)], timeout: 5), .completed,
                       "Split must add a real timeline clip")
        let after = Set(clipIDs)
        XCTAssertFalse(app.alerts.firstMatch.exists, "Split must not leave an engine error")
        XCTAssertTrue(tap("command.edit.undo"))
        let restored = NSPredicate { _, _ in Set(self.clipIDs) == before }
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: restored, evaluatedWith: nil)], timeout: 5), .completed,
                       "Undo must restore the exact original clip identities")
        XCTAssertTrue(tap("command.edit.redo"))
        let redone = NSPredicate { _, _ in Set(self.clipIDs) == after }
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: redone, evaluatedWith: nil)], timeout: 5), .completed,
                       "Redo must restore the cut")
        note("Split + undo + redo: 3 edit taps; fixture positioning: select clip + 12 frame steps")
    }
}
