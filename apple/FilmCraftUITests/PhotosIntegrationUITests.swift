import XCTest
import Photos

/// Photos integration on a seeded simulator. `scripts/run-ui-tests.sh` seeds it with
/// `xcrun simctl addmedia <udid> <video> <jpeg>` and sets the permission state per test with
/// `xcrun simctl privacy <udid> grant|revoke|reset photos ca.hologram.filmcraft`:
///
/// - `testAuthorized*`: access granted, the browser lists `asset.0`, "+" inserts at the playhead.
/// - `testDeniedState`: access revoked, `photos.denied` shows and no asset does.
/// - `testLimitedState`: permission reset (simctl cannot set "limited" directly); the test answers the system
///   prompt with "Select Photos..." and picks one. Skipped with notes when that cannot be driven.
/// - `testExportToPhotos`: access granted; the export finishes with "Saved to Photos" and the library gains one
///   asset.
///
/// Verifying a write-back from the test: (1) the media browser re-fetches live (PHPhotoLibraryChangeObserver), so
/// the number of distinct `asset.<n>` elements before and after is compared; (2) when the UI test runner itself
/// holds Photos access (the script grants it for `ca.hologram.filmcraft.uitests.xctrunner`) PhotoKit is queried
/// directly for the video count; (3) the app logs `export done: Saved to Photos` under subsystem
/// `ca.hologram.filmcraft` (category `export`), which the script prints after the suite.
@MainActor
final class PhotosIntegrationUITests: FilmCraftUITestCase {

    // MARK: Helpers

    private func openBrowser() -> Bool {
        dismissStrays()
        guard let add = hit("addMedia") else { note("addMedia is not hittable"); return false }
        add.tap()
        // `mediaBrowser` also names the Media panel on a wide iPad; the Done button exists only in the sheet.
        return element("mediaBrowserDone").waitForExistence(timeout: 10)
    }

    private func closeBrowser() {
        if let done = hit("mediaBrowserDone") { done.tap(); pause(0.9) }
        dismissStrays()
    }

    private func assetCount() -> Int { identifiers(prefix: "asset.").count }

    /// Videos in the library according to PhotoKit, when this runner process may read Photos; nil otherwise.
    private func photoKitVideoCount() -> Int? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        return PHAsset.fetchAssets(with: .video, options: nil).count
    }

    // MARK: Authorized

    func testAuthorizedBrowseAndInsert() throws {
        launchDemo(dark: false)
        defer { flushNotes() }
        XCTAssertTrue(openBrowser(), "the media browser did not open")
        XCTAssertTrue(element("asset.0").waitForExistence(timeout: 40),
                      "asset.0 is missing: no Photos item listed (was the simulator seeded with simctl addmedia and access granted?)")
        XCTAssertFalse(element("photos.denied").exists, "denied screen shown although access was granted")
        note("assets listed: \(assetCount())")
        if let video = photoKitVideoCount() { note("PhotoKit (runner) videos: \(video)") }

        let clipsBefore = clipIDs.count
        guard let plus = hit("assetAdd_0") else {
            note("assetAdd_0 is not hittable"); XCTFail("insert button of asset.0 not reachable"); return
        }
        plus.tap()
        // Materialize + import + place run in the background; the "Adding media" pill shows meanwhile.
        let deadline = Date().addingTimeInterval(90)
        var alerts: [String] = []
        while Date() < deadline {
            if app.alerts.firstMatch.exists, let text = dismissAlert() { alerts.append(text); break }
            if !element("mediaAdding").exists, clipIDs.count > clipsBefore { break }
            pause(1)
        }
        closeBrowser()
        for a in alerts { note("insert: alert: \(a)") }
        XCTAssertTrue(alerts.isEmpty, "inserting asset.0 raised an alert: \(alerts.joined(separator: " || "))")
        pause(1)
        let clipsAfter = clipIDs.count
        note("clips \(clipsBefore) -> \(clipsAfter)")
        XCTAssertGreaterThan(clipsAfter, clipsBefore, "insert at playhead added no clip to the timeline")
        undoAll(max: 2)
        XCTAssertTrue(app.state == .runningForeground)
    }

    // MARK: Denied

    func testDeniedState() throws {
        launchDemo(dark: false, acceptPhotosPrompt: false)
        defer { flushNotes() }
        XCTAssertTrue(openBrowser(), "the media browser did not open")
        let found = waitForAny(["photos.denied", "asset.0", "photos.limited"], timeout: 40)
        guard found == "photos.denied" else {
            note("not in the denied state (found: \(found ?? "nothing")); the runner revokes access with simctl privacy revoke")
            throw XCTSkip("Photos access is not denied in this run")
        }
        XCTAssertFalse(element("asset.0").exists, "assets shown although access is denied")
        XCTAssertTrue(element("photos.openSettings").exists, "photos.openSettings is missing on the denied screen")
        if !app.staticTexts["Photos Access Needed"].exists { note("'Photos Access Needed' title not found") }
        // The editor itself stays usable.
        closeBrowser()
        XCTAssertTrue(element("timeline").exists)
    }

    // MARK: Limited

    func testLimitedState() throws {
        launchDemo(dark: false, acceptPhotosPrompt: false)
        defer { flushNotes() }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // The prompt can come from the Media panel (wide iPad) or from the browser; open the browser to be sure.
        _ = openBrowser()
        var answered = false
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !answered {
            for label in ["Select Photos\u{2026}", "Select Photos...", "Limit Access\u{2026}", "Limit Access...", "Select Photos"] {
                let b = springboard.alerts.buttons[label].firstMatch
                if b.exists { b.tap(); answered = true; break }
            }
            if !answered { pause(1) }
        }
        pause(3)
        if !element("photos.limited").exists {
            // The limited picker: tap a photo, then Add/Done.
            let candidates: [XCUIElement] = [app.cells.firstMatch, app.images.firstMatch]
            if let pick = candidates.first(where: { $0.waitForExistence(timeout: 5) }), pick.isHittable { pick.tap() }
            else { note("no photo in the limited picker") }
            for label in ["Add", "Done"] {
                let b = app.buttons[label].firstMatch
                if b.waitForExistence(timeout: 2) { b.tap(); break }
            }
        }
        if !element("mediaBrowserDone").exists { _ = openBrowser() }
        let found = waitForAny(["photos.limited", "photos.denied"], timeout: 40)
        guard found == "photos.limited" else {
            note("limited banner not reached (found: \(found ?? "nothing")); simctl cannot grant limited access, prompt answered: \(answered)")
            throw XCTSkip("could not reach the limited Photos state")
        }
        XCTAssertTrue(element("photos.manage").exists, "photos.manage (Manage) is missing in the limited banner")
        XCTAssertTrue(element("asset.0").waitForExistence(timeout: 20), "limited access shows no photos")
    }

    // MARK: Export to Photos

    func testExportToPhotos() throws {
        launchDemo(dark: false)
        defer { flushNotes() }
        // Baseline: assets as the app sees them, videos as PhotoKit sees them.
        XCTAssertTrue(openBrowser(), "the media browser did not open")
        XCTAssertTrue(element("asset.0").waitForExistence(timeout: 40), "asset.0 is missing: Photos not seeded or access not granted")
        pause(1)
        let assetsBefore = assetCount()
        let videosBefore = photoKitVideoCount()
        closeBrowser()
        note("before: assets in the browser \(assetsBefore), PhotoKit videos \(videosBefore.map(String.init) ?? "unavailable (runner has no Photos access)")")

        guard let export = hit("export") else { XCTFail("export button not hittable"); return }
        export.tap()
        XCTAssertTrue(element("exportSheet").waitForExistence(timeout: 10), "exportSheet did not appear")
        XCTAssertTrue(element("export.photos").waitForExistence(timeout: 10), "export.photos missing in the export sheet")
        // Smallest size keeps the simulator export short; best effort.
        if let picker = hit("exportResolution") {
            picker.tap()
            pause(0.6)
            let option = app.buttons["480p"].firstMatch
            if option.exists, option.isHittable { option.tap(); pause(0.4) } else { note("could not choose 480p; exporting at sequence size"); dismissMenuIfOpen() }
        }
        guard let save = hit("export.photos"), save.isEnabled else {
            XCTFail("export.photos is not enabled (empty sequence?)"); return
        }
        save.tap()

        // Wait for the result: "exportMessage" (Saved to Photos / an error) or an alert. A system Photos prompt
        // (add-only access) may appear while saving.
        var message = ""
        var alerts: [String] = []
        var sawProgress = false
        let deadline = Date().addingTimeInterval(420)
        while Date() < deadline {
            if element("export.progress").exists { sawProgress = true }
            allowPhotosPromptIfShown()
            if app.alerts.firstMatch.exists, let text = dismissAlert() { alerts.append(text) }
            let m = element("exportMessage")
            if m.exists, !element("export.progress").exists { message = m.label; break }
            if !alerts.isEmpty { break }
            pause(1)
        }
        note("export: progress seen \(sawProgress), message '\(message)', alerts \(alerts)")
        XCTAssertTrue(alerts.isEmpty, "export raised an alert: \(alerts.joined(separator: " || "))")
        XCTAssertEqual(message, "Saved to Photos", "export did not finish with 'Saved to Photos'")
        if let done = hit("exportDone") { done.tap(); pause(0.9) }

        // Verify the write-back: the library gained an asset.
        pause(2)
        XCTAssertTrue(openBrowser(), "the media browser did not reopen")
        var assetsAfter = assetCount()
        let verifyDeadline = Date().addingTimeInterval(40)
        while assetsAfter <= assetsBefore, Date() < verifyDeadline {
            pause(2)
            assetsAfter = assetCount()
        }
        note("after: assets in the browser \(assetsAfter)")
        XCTAssertGreaterThan(assetsAfter, assetsBefore, "the exported movie did not show up in the Photos library")
        if let before = videosBefore, let after = photoKitVideoCount() {
            note("PhotoKit videos \(before) -> \(after)")
            XCTAssertGreaterThan(after, before, "PhotoKit shows no new video after the export")
        }
        closeBrowser()
    }

    private func dismissMenuIfOpen() {
        let region = app.otherElements["PopoverDismissRegion"]
        if region.exists, region.isHittable { region.tap(); pause(0.4) }
    }
}
