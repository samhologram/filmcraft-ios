import XCTest
import UIKit

/// One visited item of a coverage tour.
struct TourItem {
    let name: String
    let reached: Bool
    /// Cause class of a miss: off-screen, missing-identifier, engine-refused, no-effect, disabled, CRASH, ...
    let cause: String
    let detail: String
}

/// Shared driver of the coverage tours (tools, panels, commands). Every item is visited through the real UI;
/// only a crash fails a test. Everything else is recorded in the `<prefix>-<tour>-summary` attachment, where a
/// miss ("NOT-REACHED") stays visible as a bug to fix, never as a pass.
///
/// The item lists come from the running app (nothing is embedded): tools from the tool menu / strip, panels from
/// the tabs, the More menu and the overflow menu, commands from scrolling the command palette. The source of
/// truth behind those lists is the engine catalog (`apple/scripts/dump-catalog.sh engine|ui|menus`).
///
/// Environment (pass as `TEST_RUNNER_<NAME>=...` to xcodebuild): `TOUR_LIMIT=n` visits only the first n items,
/// `TOUR_ONLY=a,b` only those ids (tool.razor, panel.effects, or a command id without the `command.` prefix).
@MainActor
class TourTestCase: FilmCraftUITestCase {
    var items: [TourItem] = []
    var landscape = false
    var tourName = ""
    var summaryAttached = false
    var extraSummaryLines: [String] = []
    var crashItems: [String] = []
    var relaunches: [String] = []

    var limit: Int? { ProcessInfo.processInfo.environment["TOUR_LIMIT"].flatMap { Int($0) } }
    var only: Set<String>? {
        guard let v = ProcessInfo.processInfo.environment["TOUR_ONLY"], !v.isEmpty else { return nil }
        return Set(v.split(separator: ",").map { String($0) })
    }

    // MARK: Setup

    func startTour(name: String, landscape: Bool) {
        self.landscape = landscape
        tourName = name
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        launchDemo(dark: false)
        continueAfterFailure = true
        prefix = "\(isPad ? "ipad" : "iphone")-\(landscape ? "landscape" : "portrait")-\(name)"
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        pause(1.5)
        if !element("viewer").exists { XCTFail("viewer is missing at the start of the \(name) tour") }
        if !element("timeline").exists { XCTFail("timeline is missing at the start of the \(name) tour") }
    }

    // MARK: Recording

    func record(_ name: String, reached: Bool, cause: String = "", _ detail: String = "") {
        items.append(TourItem(name: name, reached: reached, cause: cause, detail: detail))
        let line = "\(reached ? "REACHED" : "NOT-REACHED") \(name) [\(cause)] \(detail)"
        NSLog("TOUR %@", line)
        // Best-effort mirror on the host: a crash can end the run before the summary attachment exists.
        let path = "/tmp/fctour-\(prefix).log"
        if let data = (line + "\n").data(using: .utf8) {
            if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(data); try? h.close() }
            else { FileManager.default.createFile(atPath: path, contents: data) }
        }
    }

    /// Writes the `<prefix>-<tour>-summary` attachment. The attachment name ends with `-summary`, which is what
    /// `scripts/run-ui-tests.sh` prints.
    func attachSummary() {
        guard !summaryAttached else { return }
        summaryAttached = true
        let reached = items.filter(\.reached).count
        let missed = items.filter { !$0.reached }
        var causes: [String: Int] = [:]
        for m in missed { causes[m.cause, default: 0] += 1 }
        var lines = ["\(prefix) \(tourName) tour summary",
                     "items: \(items.count)  reached: \(reached)  not-reached: \(missed.count)",
                     "not-reached by cause: " + (causes.isEmpty ? "none" : causes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")),
                     ""]
        if !crashItems.isEmpty { lines += ["CRASHES at: " + crashItems.joined(separator: ", "), ""] }
        lines += items.map { i in
            i.reached ? "REACHED      \(i.name)  \(i.detail)" : "NOT-REACHED  \(i.name)  [\(i.cause)] \(i.detail)"
        }
        if !extraSummaryLines.isEmpty { lines += ["", "extra:"] + extraSummaryLines }
        lines += ["", "notes:"] + (notes.isEmpty ? ["none"] : notes)
        let text = lines.joined(separator: "\n")
        try? text.write(toFile: "/tmp/fctour-\(prefix)-summary.txt", atomically: true, encoding: .utf8)
        let attachment = XCTAttachment(string: text)
        attachment.name = "\(prefix)-\(tourName)-summary"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: Crash handling

    /// True while the app is alive. A backgrounded app (a command opened Safari) is brought back. When the app
    /// is gone, the item is recorded as CRASH, the test fails (the tour goes on so later items are still
    /// covered) and the app is relaunched on a fresh demo project; returns false.
    func alive(_ item: String) -> Bool {
        if ensureForeground(), app.windows.firstMatch.exists { return true }
        crashItems.append(item)
        record(item, reached: false, cause: "CRASH", "app state \(app.state.rawValue) after this item; relaunched")
        XCTFail("CRASH (app not running in the foreground) at \(item)")
        relaunch()
        return false
    }

    /// Fresh launch on a new demo project (after a crash, or when the UI is stuck beyond recovery).
    func relaunch() {
        let saved = prefix
        app.terminate()
        launchDemo(dark: false)
        continueAfterFailure = true
        prefix = saved
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        pause(1.5)
    }

    /// The timeline lost its clips (a command replaced the project): start over on a fresh demo.
    func ensureProjectValid(after item: String) {
        if clipExists { return }
        pause(1.5)
        if clipExists { return }
        relaunches.append(item)
        extraSummaryLines.append("RELAUNCH after \(item): the timeline showed no clip.* (project replaced or emptied)")
        relaunch()
    }


    /// Catalog items (from `catalogDump`) against what the UI scraping found, both ways, into the summary.
    func crossCheck(kind: String, catalog: [String], scraped: [String]) {
        let missingInUI = catalog.filter { !scraped.contains($0) }
        let extraInUI = scraped.filter { !catalog.contains($0) }
        extraSummaryLines.append("\(kind): catalog \(catalog.count), UI scraping found \(scraped.count)")
        if !missingInUI.isEmpty { extraSummaryLines.append("\(kind) in the catalog but not found in the UI: \(missingInUI.joined(separator: ", "))") }
        if !extraInUI.isEmpty { extraSummaryLines.append("\(kind) in the UI but not in the catalog: \(extraInUI.joined(separator: ", "))") }
    }

    // MARK: Menus and strips

    /// Closes an open menu or popover.
    func dismissMenu() {
        let region = app.otherElements["PopoverDismissRegion"]
        if region.exists, region.isHittable { region.tap(); pause(0.5); return }
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).tap()
        pause(0.5)
    }

    /// The layout the tools live in: the iPad toolbar menu (`menu.tools`), else the iPhone / narrow strip.
    var hasToolMenu: Bool { element("menu.tools").exists }

    // MARK: Command palette

    /// Runs one palette command by searching for its id. Returns "ran", "disabled: <label>", "missing",
    /// "off-screen" or "palette-unreachable".
    func runPaletteCommand(_ id: String) -> String {
        if !openPalette() {
            dismissStrays()
            pause(1)
            if !openPalette() {
                note("\(id): palette unreachable; relaunching the app on a fresh project")
                relaunches.append("\(id) (app state \(app.state.rawValue))")
                extraSummaryLines.append("RELAUNCH before \(id): the palette could not be opened (app state \(app.state.rawValue))")
                relaunch()
                guard openPalette() else { return "palette-unreachable" }
            }
        }
        let search = app.searchFields.firstMatch
        if search.waitForExistence(timeout: 3) {
            search.tap()
            search.typeText(id)
            pause(0.6)
            let key = app.keyboards.buttons["Search"].firstMatch
            if key.exists, key.isHittable { key.tap() }
            pause(0.4)
        }
        let palette = element("palette")
        var row: XCUIElement?
        for attempt in 0..<4 {
            let q = palette.buttons.matching(identifier: "command.\(id)")
            for e in q.allElementsBoundByIndex where canTap(e) { row = e; break }
            if row != nil { break }
            if attempt < 3, palette.exists {
                let from = palette.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                let to = palette.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
                pause(0.4)
            }
        }
        guard let row else {
            let found = palette.buttons.matching(identifier: "command.\(id)").firstMatch.exists
            dismissStrays()
            return found ? "off-screen" : "missing"
        }
        if !row.isEnabled {
            let label = row.label.replacingOccurrences(of: "\n", with: " ")
            dismissStrays()
            return "disabled: \(label)"
        }
        row.tap()
        // The palette closes, waits 450 ms, then runs the command (or presents its parameter sheet).
        pause(1.8)
        return "ran"
    }
}
