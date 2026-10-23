import XCTest

/// Core scenario: launch the demo in dark and light, wait for `demoReady`, look at the editor's anatomy, play,
/// split a clip and undo, open every primary panel, the palette and the export sheet.
/// A missing element goes into the `-notes` attachment (read it: a green run can be hollow); only `demoReady`,
/// `viewer`, `timeline` and "at least one clip" are hard failures.
@MainActor
final class FilmCraftUITests: FilmCraftUITestCase {
    func testDemoDark() throws { try scenario(dark: true) }
    func testDemoLight() throws { try scenario(dark: false) }

    private func scenario(dark: Bool) throws {
        launchDemo(dark: dark)
        defer { flushNotes() }

        // Hard requirements.
        XCTAssertTrue(element("viewer").waitForExistence(timeout: 20), "viewer is missing")
        XCTAssertTrue(element("timeline").waitForExistence(timeout: 20), "timeline is missing")
        XCTAssertTrue(waitForClip(timeout: 30), "the demo timeline shows no clip.* element")
        note("layout: \(isPad ? "iPad" : "iPhone"), panel column \(element("inspector").exists ? "present" : "absent"), clips \(clipIDs.count)")

        playPauseStep()
        splitAndUndoStep()
        panelsStep()
        paletteStep()
        exportStep()

        XCTAssertTrue(app.state == .runningForeground, "the app is not running any more")
    }

    private func waitForClip(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if clipExists { return true }
            pause(1)
        }
        return false
    }

    // MARK: Steps

    private func playPauseStep() {
        guard let play = hit("transport.play") else { note("transport.play is not hittable"); return }
        let beforeLabel = play.label
        let before = playheadValue
        play.tap()
        pause(2.5)
        let during = element("transport.play").label
        let after = playheadValue
        if during == beforeLabel { note("transport.play label did not change while playing ('\(beforeLabel)')") }
        if before.isEmpty { note("playhead exposes no timecode value, the advance cannot be checked") }
        else if before == after { note("playhead did not advance while playing (\(before) -> \(after))") }
        else { note("playhead advanced \(before) -> \(after)") }
        if let pauseButton = hit("transport.play") { pauseButton.tap() }
        pause(0.6)
        if element("transport.play").label != beforeLabel { note("transport.play label did not return to '\(beforeLabel)' after pausing") }
        let timecode = element("timecode")
        if timecode.exists {
            let digits = "\(timecode.label) \((timecode.value as? String) ?? "")"
            if digits.range(of: #"\d\d:\d\d:\d\d:\d\d"#, options: .regularExpression) == nil {
                note("timecode element exposes no HH:MM:SS:FF text (label/value: '\(digits)'): add an accessibilityValue")
            }
        } else {
            note("timecode: not found")
        }
    }

    private func splitAndUndoStep() {
        guard selectFirstClip() != nil else { return }
        stepForward(12)
        let before = clipIDs.count
        guard let split = hit("command.sequence.addEdit") else { note("command.sequence.addEdit is not hittable"); return }
        guard split.isEnabled else { note("command.sequence.addEdit is disabled with a clip selected"); return }
        split.tap()
        pause(1.2)
        let alerts = dismissStrays()
        for a in alerts { note("split: alert: \(a)") }
        let after = clipIDs.count
        if after <= before { note("split at playhead did not add a clip (\(before) -> \(after))") }
        else { note("split at playhead: clips \(before) -> \(after)") }
        let undo = element("command.edit.undo")
        guard undo.exists, undo.isEnabled else { note("command.edit.undo is not enabled after the split"); return }
        undoAll(max: 1)
        pause(0.8)
        let restored = clipIDs.count
        if restored != before { note("undo after the split left \(restored) clips, expected \(before)") }
    }

    private func panelsStep() {
        for id in Self.primaryPanels {
            let result = openPanel(id)
            note("\(id): \(result.ok ? "OPENED" : "NOT REACHED") \(result.detail)")
            closePanelIfOpen()
        }
    }

    private func paletteStep() {
        guard openPalette() else { note("palette: NOT REACHED"); return }
        let rows = identifiers(prefix: "command.").count
        note("palette: opened, \(rows) command rows visible")
        if rows == 0 { note("palette shows no command.* rows") }
        dismissStrays()
        if element("palette").exists { note("palette did not close") }
    }

    private func exportStep() {
        guard let export = hit("export") else { note("export: not hittable"); return }
        export.tap()
        if element("exportSheet").waitForExistence(timeout: 8), element("export.photos").exists {
            note("export sheet: opened (export.photos \(element("export.photos").isEnabled ? "enabled" : "disabled"), export.files present: \(element("export.files").exists))")
        } else {
            note("exportSheet / export.photos never appeared")
        }
        dismissStrays()
    }
}
