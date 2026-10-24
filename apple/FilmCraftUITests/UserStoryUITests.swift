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
        guard let selectedID = selectFirstClip() else { XCTFail("A seeded clip must be selectable"); return }
        let selected = element(selectedID)
        XCTAssertTrue(selected.isSelected, "Tapping the clip must select it before splitting")
        let timeline = element("timeline")
        XCTAssertTrue(element("playhead").exists, "The timeline must expose the actual playhead")
        let clipFrame = selected.frame
        XCTAssertGreaterThan(clipFrame.width, 100, "The selected demo clip needs enough visible duration for a cut")
        let targetX = clipFrame.midX
        XCTAssertGreaterThan(targetX, timeline.frame.minX + 56, "The clip center must lie in the ruler lane")
        XCTAssertLessThan(targetX, timeline.frame.maxX - 12)
        let ruler = timeline.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: targetX - timeline.frame.minX, dy: 11))
        ruler.tap()
        let insideClip = NSPredicate { _, _ in
            let frame = self.element(selectedID).frame
            let x = self.element("playhead").frame.midX
            return self.element(selectedID).isSelected && x > frame.minX + 12 && x < frame.maxX - 12
        }
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: insideClip, evaluatedWith: nil)], timeout: 5), .completed,
                       "Seeking in the ruler must put the playhead strictly inside the selected clip")
        XCTAssertNotNil(hit("transport.stepForward"), "The editor needs frame stepping to choose a cut")
        stepForward(12)
        XCTAssertTrue(insideClip.evaluate(with: nil), "Frame stepping must leave the playhead inside the selected clip")
        note("Split precondition: selected \(selectedID), clip frame \(selected.frame), playhead \(playheadValue)")
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
