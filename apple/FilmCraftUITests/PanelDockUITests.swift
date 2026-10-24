import XCTest

/// Focused regression for the wide iPad dock. The full panel tour checks each panel's content separately.
@MainActor
final class PanelDockUITests: FilmCraftUITestCase {
    func testToolbarSidebarRestoresSelectedPanel() {

        continueAfterFailure = false
        defer {
            let evidence = XCTAttachment(string: app.debugDescription)
            evidence.name = "sidebar-toggle-hierarchy"; evidence.lifetime = .keepAlways; add(evidence)
        }
        func waitState(_ message: String, _ check: @escaping () -> Bool) {
            let predicate = NSPredicate { _, _ in check() }
            XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: nil)], timeout: 8), .completed, message)
        }

        if isPad { XCUIDevice.shared.orientation = .landscapeLeft }
        defer { XCUIDevice.shared.orientation = .portrait }
        launchDemo(dark: false)
        let wide = app.windows.firstMatch.frame.width >= 900
        func openNotes() {
            if !wide { XCTAssertTrue(tap("menu.more"), "Compact panel menu requires More") }
            XCTAssertTrue(tap("menu.panels"))
            XCTAssertTrue(tapMenuItemScrolling("panel.projectNotes"))
        }
        func shown() -> Bool {
            if wide { return element("panel.projectNotes.header").isHittable && hit("panel.projectNotes") != nil }
            let tab = element("panel.projectNotes")
            return element("panelClose").isHittable && tab.isSelected && tab.isHittable
        }
        openNotes()
        waitState("Project Notes must be foreground and reachable", shown)
        XCTAssertTrue(tap("toggleInspector"), "Toolbar must hide panels")
        waitState("Project Notes must no longer be interactive", { !shown() })
        XCTAssertTrue(tap("toggleInspector"), "Toolbar must restore panels")
        waitState("Restoring must preserve selected Project Notes", shown)
        XCTAssertTrue(tap("toggleInspector"))
        waitState("Panels must hide before menu reopen", { !shown() })
        if wide { XCTAssertTrue(tap("toggleInspector"), "Wide Add menu lives inside the dock") }
        openNotes()
        waitState("Reopening must reveal Project Notes", shown)
        // FilmCraft has no fullscreen action; no fullscreen pass is claimed by this test.
    }

    func testPanelCanBeAddedReopenedCollapsedAndHidden() throws {
        guard isPad else { throw XCTSkip("The dock is shown only in the wide iPad layout") }
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        launchDemo(dark: false)
        defer {
            attachText(app.debugDescription, name: "wide-panel-hierarchy")
            flushNotes("panel-dock-notes")
        }
        XCTAssertGreaterThanOrEqual(app.windows.firstMatch.frame.width, 900,
                                    "This story requires the wide iPad window; portrait exercises the sheet story")

        XCTAssertTrue(tap("menu.panels"), "The dock add menu must remain accessible")
        XCTAssertTrue(tapMenuItemScrolling("panel.projectNotes"), "A panel near the end of the catalog must be addable")
        XCTAssertTrue(element("panel.projectNotes.header").waitForExistence(timeout: 5))
        XCTAssertTrue(hit("panel.projectNotes") != nil, "Opening a panel must reveal its selected tab")

        // A second show of the selected panel must select/expand it, never toggle it off.
        XCTAssertTrue(tap("menu.panels"))
        XCTAssertTrue(tapMenuItemScrolling("panel.projectNotes"))
        XCTAssertTrue(element("panel.projectNotes.header").exists)
        XCTAssertTrue(hit("panel.projectNotes") != nil)

        let collapse = prefixQuery("panel.group.").allElementsBoundByIndex.first {
            $0.identifier.hasSuffix(".collapse") && canTap($0)
        }
        XCTAssertNotNil(collapse, "The selected group needs an accessible collapse control")
        collapse?.tap()
        XCTAssertFalse(element("panel.projectNotes.header").exists, "Collapsed content must be hidden")
        XCTAssertTrue(tap("menu.panels"))
        XCTAssertTrue(tapMenuItemScrolling("panel.projectNotes"))
        XCTAssertTrue(element("panel.projectNotes.header").waitForExistence(timeout: 5), "Reopening expands the group")

        XCTAssertTrue(tap("panel.panel.projectNotes.hide"), "Hide belongs in the panel header")
        XCTAssertFalse(element("panel.projectNotes.header").exists)
        XCTAssertTrue(tap("menu.panels"))
        XCTAssertTrue(tapMenuItemScrolling("panel.projectNotes"), "A hidden panel can be added again")
        XCTAssertTrue(element("panel.projectNotes.header").waitForExistence(timeout: 5))

        XCTAssertTrue(tap("menu.panels"))
        XCTAssertTrue(tap("panel.project"))
        XCTAssertTrue(element("media.import").waitForExistence(timeout: 5), "Import remains in the Media panel header")
    }

    /// On iPhone and a portrait 11-inch iPad, users open secondary panels without a dock.
    func testPortraitPanelSheetKeepsOpenedAndReopenedTabVisible() {
        XCUIDevice.shared.orientation = .portrait
        launchDemo(dark: true)
        defer {
            attachText(app.debugDescription, name: "portrait-panel-hierarchy")
            flushNotes("portrait-panel-notes")
        }
        XCTAssertLessThan(app.windows.firstMatch.frame.width, 900,
                          "Run on the shared iPhone or portrait 11-inch iPad; this is the narrow sheet story")

        func openNotes() {
            XCTAssertTrue(tap("menu.more"), "More must remain reachable without the wide dock")
            XCTAssertTrue(tap("menu.panels"), "More must expose Panels")
            XCTAssertTrue(tapMenuItemScrolling("panel.projectNotes"), "Secondary panels must be reachable from Panels")
            XCTAssertTrue(element("panelClose").waitForExistence(timeout: 5), "The panel must open as a sheet")
            let tab = app.buttons.matching(identifier: "panel.projectNotes").firstMatch
            let visible = NSPredicate { _, _ in tab.exists && tab.isSelected && self.canTap(tab) }
            XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: visible, evaluatedWith: nil)], timeout: 5), .completed,
                           "Opening a secondary panel must select and scroll its sheet tab into view")
            XCTAssertTrue(element(Self.contentID(forPanel: "panel.projectNotes")).exists,
                          "An opened tab must expose its panel content")
        }

        openNotes()
        XCTAssertTrue(tap("panelClose"), "The sheet must be dismissible")
        XCTAssertTrue(element("viewer").waitForExistence(timeout: 5), "Closing the panel must return to the movie")
        openNotes()
        XCTAssertTrue(tap("panelClose"))
        XCTAssertTrue(element("timeline").exists, "Panel navigation must preserve the editing context")
        note("Secondary panel: 3 taps to open via More > Panels; 1 tap to dismiss; repeated successfully")
    }
}
