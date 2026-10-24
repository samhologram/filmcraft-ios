import XCTest
import UIKit

/// Shared driver of the UI tests. Launches with `-FilmCraftDemo -FilmCraftResetState`, waits for the `demoReady`
/// marker and drives the app through accessibility identifiers only. Nothing here takes screenshots: verification
/// is through accessibility assertions, `-notes` text attachments and the app's logs (the run script prints the
/// `ca.hologram.filmcraft` log after each suite).
///
/// Policy (COOKBOOK section 7): a missing element goes into the notes, not into a failure, except `demoReady`,
/// `viewer` and `timeline` which are hard failures. "Not reached" is a bug in the app or the test, never a pass.
///
/// The identifiers used are the ones in the Swift sources (they win over `docs/CONTRACT.md` section 5):
/// `commandSheetRun/Cancel/Error/Result`, `palette` + `paletteDone`, `panelTitle`/`panelClose`, `errorOK`,
/// `exportDone`, `exportSheet`, `paletteOpen`, `catalogDump`, `mediaBrowser`/`mediaBrowserDone`, `exportMessage`, ...
@MainActor
class FilmCraftUITestCase: XCTestCase {
    var app: XCUIApplication!
    var notes: [String] = []
    var prefix = ""
    var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    static let primaryPanels = ["panel.project", "panel.effects", "panel.effectControls",
                                "panel.lumetriColor", "panel.essentialGraphics", "panel.audioTrackMixer"]

    // MARK: Launch

    /// Launches the demo app (a new untitled document built from the engine's procedural demo project).
    /// `-FilmCraftResetState` clears UserDefaults and caches so runs do not depend on each other.
    func launchDemo(dark: Bool, extraArguments: [String] = [], waitForReady: Bool = true, acceptPhotosPrompt: Bool = true) {
        continueAfterFailure = false
        let mode = dark ? "dark" : "light"
        prefix = "\(isPad ? "ipad" : "iphone")-\(mode)"
        notes = []
        XCUIDevice.shared.appearance = dark ? .dark : .light
        if acceptPhotosPrompt {
            // The prompt can arrive after demoReady. Handle only FilmCraft's Photos request; XCTest's default
            // interruption handler otherwise chooses Don't Allow during the first unrelated toolbar tap.
            addUIInterruptionMonitor(withDescription: "FilmCraft Photos access") { alert in
                guard alert.label.localizedCaseInsensitiveContains("photo") else { return false }
                for title in ["Allow Full Access", "Allow Access to All Photos", "Allow"] {
                    let button = alert.buttons[title].firstMatch
                    if button.exists { button.tap(); return true }
                }
                return false
            }
        }
        app = XCUIApplication()
        var args = ["-FilmCraftDemo", "-FilmCraftResetState", "-FilmCraftUITest", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if dark { args += ["-AppleInterfaceStyle", "Dark"] }
        app.launchArguments = args + extraArguments
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60), "The app did not launch")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 60), "The app has no window")
        if waitForReady { waitForDemoReady(acceptPhotosPrompt: acceptPhotosPrompt) }
        if acceptPhotosPrompt { _ = allowPhotosPromptIfShown() }
    }

    /// Hard failure when the demo never becomes ready (the marker appears after the first program frame).
    func waitForDemoReady(timeout: TimeInterval = 60, acceptPhotosPrompt: Bool = true) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if acceptPhotosPrompt { _ = allowPhotosPromptIfShown() }
            if element("demoReady").exists { return }
            pause(1)
        }
        XCTFail("demoReady did not appear within \(Int(timeout)) s (demo seeding or the first frame never finished)")
    }

    /// Taps "Allow Full Access" on the system Photos prompt when it shows (the wide iPad layout requests access
    /// as soon as the Media panel appears).
    @discardableResult
    func allowPhotosPromptIfShown() -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.exists, alert.label.localizedCaseInsensitiveContains("photo") else { return false }
        for label in ["Allow Full Access", "Allow Access to All Photos", "Allow"] {
            let button = alert.buttons[label].firstMatch
            if button.exists {
                button.tap()
                return true
            }
        }
        return false
    }

    // MARK: Catalog dump

    /// The catalog the app exposes with `-FilmCraftUITest`: a 1x1 `catalogDump` element whose accessibility value is
    /// JSON `{"tools":[ids],"panels":[ids],"commands":[ids]}`. nil (with a note) when missing or malformed.
    func readCatalogDump() -> (tools: [String], panels: [String], commands: [String])? {
        let dump = element("catalogDump")
        guard dump.waitForExistence(timeout: 15) else { note("catalogDump is missing (launch arg -FilmCraftUITest not honoured?)"); return nil }
        guard let text = dump.value as? String, let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            note("catalogDump value is not the expected JSON object")
            return nil
        }
        func list(_ key: String) -> [String] { (object[key] as? [String]) ?? [] }
        let commands = list("commands").map { $0.hasPrefix("command.") ? String($0.dropFirst("command.".count)) : $0 }
        let result = (tools: list("tools"), panels: list("panels"), commands: commands)
        if result.tools.isEmpty || result.panels.isEmpty || result.commands.isEmpty {
            note("catalogDump has an empty list: tools \(result.tools.count), panels \(result.panels.count), commands \(result.commands.count)")
        }
        return result
    }

    // MARK: Elements

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func prefixQuery(_ prefix: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
    }

    func exists(prefix: String) -> Bool { prefixQuery(prefix).firstMatch.exists }

    /// Distinct identifiers that start with `prefix` (SwiftUI can expose one id on several elements).
    func identifiers(prefix: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for e in prefixQuery(prefix).allElementsBoundByIndex where e.exists {
            let id = e.identifier
            if seen.insert(id).inserted { out.append(id) }
        }
        return out
    }

    /// On screen and tappable. The frame is checked first: `isHittable` itself can fail a test for elements
    /// scrolled far out of view.
    func canTap(_ e: XCUIElement) -> Bool {
        guard e.exists else { return false }
        let f = e.frame
        let w = app.windows.firstMatch.frame
        guard !f.isEmpty, w.contains(CGPoint(x: f.midX, y: f.midY)) else { return false }
        return e.isHittable
    }

    /// The first element with `identifier` that can be tapped.
    func hit(_ identifier: String) -> XCUIElement? {
        let q = app.descendants(matching: .any).matching(identifier: identifier)
        for e in q.allElementsBoundByIndex where canTap(e) { return e }
        return nil
    }

    func hit(prefix: String) -> XCUIElement? {
        for e in prefixQuery(prefix).allElementsBoundByIndex where canTap(e) { return e }
        return nil
    }

    func waitForAny(_ identifiers: [String], timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for id in identifiers where element(id).exists { return id }
            pause(0.5)
        }
        return nil
    }

    /// Taps `identifier` when it can be reached; records a note otherwise.
    @discardableResult
    func tap(_ identifier: String, timeout: TimeInterval = 5) -> Bool {
        let e = element(identifier)
        guard e.waitForExistence(timeout: timeout) else { note("\(identifier): not found"); return false }
        guard let target = hit(identifier) else { note("\(identifier): exists but is not hittable (off screen or covered)"); return false }
        target.tap()
        return true
    }

    /// A catalog panel near the bottom of a native Menu can be outside its initial accessibility viewport.
    /// Scroll only the presented menu (or its popover scroll view), with a fixed bound and a real hittability check.
    @discardableResult
    func tapMenuItemScrolling(_ identifier: String) -> Bool {
        if let item = hit(identifier) { item.tap(); return true }
        for _ in 0..<12 {
            let menus = app.menus.allElementsBoundByIndex
            let scroller = menus.last(where: { canTap($0) })
                ?? app.scrollViews.allElementsBoundByIndex.last(where: { canTap($0) })
            guard let scroller else { break }
            scroller.swipeUp(velocity: .slow)
            pause(0.25)
            if let item = hit(identifier) { item.tap(); return true }
        }
        note("\(identifier): not reachable after bounded native-menu scroll")
        return false
    }

    func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: Notes

    func note(_ text: String) {
        notes.append(text)
        NSLog("FilmCraftUITests note: %@", text)
    }

    func flushNotes(_ name: String = "notes") {
        let attachment = XCTAttachment(string: notes.isEmpty ? "no notes" : notes.joined(separator: "\n"))
        attachment.name = "\(prefix)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func attachText(_ text: String, name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = "\(prefix)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: App state

    /// An app that went to the background (a command opened Safari, a system sheet took over) is brought back.
    /// Returns false when the app is not running any more (a crash).
    func ensureForeground() -> Bool {
        switch app.state {
        case .runningForeground:
            return true
        case .runningBackground, .runningBackgroundSuspended:
            app.activate()
            return app.wait(for: .runningForeground, timeout: 15)
        default:
            return false
        }
    }

    // MARK: Timeline and clips

    /// Clip elements only: a clip id is exactly `clip.<digits>`, so `clip.<id>.trimStart/.trimEnd` are excluded.
    var clipQuery: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES %@", #"clip\.[0-9]+"#))
    }
    var clipExists: Bool { clipQuery.firstMatch.exists }
    var clipIDs: [String] {
        var seen = Set<String>()
        return clipQuery.allElementsBoundByIndex.filter(\.exists).map(\.identifier).filter { seen.insert($0).inserted }
    }
    func hittableClip() -> XCUIElement? {
        for e in clipQuery.allElementsBoundByIndex where canTap(e) { return e }
        return nil
    }

    @discardableResult
    func selectFirstClip() -> String? {
        guard let clip = hittableClip() else { note("no hittable clip.* to select"); return nil }
        let id = clip.identifier
        clip.tap()
        pause(0.8)
        return id
    }

    /// The playhead's timecode (the `playhead` element carries it as its accessibility value).
    var playheadValue: String {
        let e = element("playhead")
        guard e.exists else { return "" }
        return (e.value as? String) ?? ""
    }

    /// Steps `count` frames forward through the transport bar.
    func stepForward(_ count: Int) {
        guard let button = hit("transport.stepForward") else { note("transport.stepForward is not hittable"); return }
        for _ in 0..<count { button.tap() }
        pause(0.5)
    }

    func stopPlaybackIfRunning() {
        let play = element("transport.play")
        if play.exists, play.label == "Pause", let b = hit("transport.play") {
            b.tap()
            pause(0.4)
        }
    }

    // MARK: Undo

    func undoAll(max count: Int = 6) {
        for _ in 0..<count {
            let u = element("command.edit.undo")
            guard u.exists, u.isEnabled, let target = hit("command.edit.undo") else { return }
            target.tap()
            pause(0.6)
        }
    }

    // MARK: Alerts, sheets, strays

    /// The full message of an alert on screen, dismissed; nil when none.
    func dismissAlert() -> String? {
        let alert = app.alerts.firstMatch
        guard alert.waitForExistence(timeout: 1) else { return nil }
        let text = ([alert.label] + alert.staticTexts.allElementsBoundByIndex.map(\.label)).joined(separator: " | ")
        if let ok = hit("errorOK") { ok.tap() } else {
            let button = alert.buttons.firstMatch
            if button.exists { button.tap() }
        }
        return text
    }

    /// Dismisses what the last action left open (alerts, parameter sheet, palette, export and media sheets, system
    /// pickers) and returns the full text of every alert met on the way.
    @discardableResult
    func dismissStrays() -> [String] {
        var alerts: [String] = []
        for _ in 0..<6 {
            if app.alerts.firstMatch.exists, let text = dismissAlert() {
                alerts.append(text)
                pause(0.6)
                continue
            }
            var acted = false
            for id in ["commandSheetCancel", "exportDone", "paletteDone", "mediaBrowserDone"] {
                if let b = hit(id) { b.tap(); pause(0.9); acted = true; break }
            }
            if acted { continue }
            // System pickers (file importer / mover) and menus.
            if app.sheets.firstMatch.exists || app.popovers.firstMatch.exists || app.navigationBars.count > 1 {
                let cancel = app.buttons["Cancel"].firstMatch
                if cancel.exists, cancel.isHittable { cancel.tap(); pause(0.9); continue }
            }
            let dismissRegion = app.otherElements["PopoverDismissRegion"]
            if dismissRegion.exists, dismissRegion.isHittable { dismissRegion.tap(); pause(0.6); continue }
            break
        }
        return alerts
    }

    func closePanelIfOpen() {
        guard element("panelTitle").exists else { return }
        if let close = hit("panelClose") {
            close.tap()
            let deadline = Date().addingTimeInterval(5)
            while element("panelTitle").exists, Date() < deadline { pause(0.4) }
            pause(0.6)
        } else {
            note("panelClose is not hittable while a panel sheet is open")
        }
    }

    /// If a parameter sheet is open: fill required text, press Run/Apply, record the engine's message (error or
    /// query result), close it. Returns a description ("" when no sheet) and the refusal text when the engine
    /// or the form refused.
    func resolveSheet() -> (text: String, refused: String?) {
        let run = element("commandSheetRun")
        guard run.waitForExistence(timeout: 2) else { return ("", nil) }
        var text = "sheet"
        if run.exists, !run.isEnabled {
            // Required text fields without defaults: a plain value.
            for field in app.textFields.allElementsBoundByIndex where field.exists && field.isHittable {
                let value = (field.value as? String) ?? ""
                if value.isEmpty || value == field.placeholderValue {
                    field.tap()
                    field.typeText("Tour")
                    text += " filled-text"
                }
            }
            let key = app.keyboards.buttons["return"].firstMatch
            if key.exists { key.tap() } else if app.keyboards.count > 0 { app.keyboards.buttons["Return"].firstMatch.tap() }
            pause(0.4)
        }
        var refused: String?
        if run.exists, run.isEnabled, run.isHittable {
            run.tap()
            text += " run"
            pause(1.5)
            let err = element("commandSheetError")
            if err.exists {
                refused = err.label
                text += " ERROR"
            }
            let result = element("commandSheetResult")
            if result.exists { text += " result=\(String(result.label.prefix(120)).replacingOccurrences(of: "\n", with: " "))" }
        } else if run.exists {
            text += " apply-disabled"
            refused = "parameter sheet Apply stays disabled with defaults"
        }
        if let cancel = hit("commandSheetCancel") { cancel.tap() }
        pause(0.8)
        return (text, refused)
    }

    // MARK: Command palette

    /// Opens the palette from the toolbar button. Returns false (with a note) when it cannot be reached.
    func openPalette() -> Bool {
        dismissStrays()
        if element("palette").exists { return true }
        guard let button = hit("paletteOpen") else {
            note("paletteOpen is not hittable (toolbar overflow on a narrow window?)")
            return false
        }
        button.tap()
        return element("palette").waitForExistence(timeout: 8)
    }

    /// Pulls the palette sheet from its medium detent to the large one so more rows fit.
    func expandPalette() {
        let nav = app.navigationBars["Command Palette"]
        guard nav.exists else { return }
        let from = nav.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = from.withOffset(CGVector(dx: 0, dy: -400))
        from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
        pause(0.8)
    }

    // MARK: Panels

    /// Panel id -> the content identifier the panel shows.
    static func contentID(forPanel id: String) -> String {
        switch id {
        case "panel.project": return "mediaBrowser"
        case "panel.effects": return "effects"
        case "panel.effectControls": return "effectControls"
        case "panel.audioTrackMixer": return "audioMixer"
        default: return "panelCommands"
        }
    }

    /// Scrolls a horizontal strip (the panel tabs, the iPhone tool strip) until `identifier` is tappable. The
    /// scroll handle is any tappable `panel.*` / `tool.*` / `morePanels` element on the same row.
    func scrollIntoView(_ identifier: String) -> XCUIElement? {
        if let e = hit(identifier) { return e }
        let target = element(identifier)
        guard target.exists else { return nil }
        for _ in 0..<10 {
            let y = target.frame.midY
            var handle: XCUIElement?
            for p in ["panel.", "tool.", "morePanels"] {
                for e in prefixQuery(p).allElementsBoundByIndex where canTap(e) && abs(e.frame.midY - y) < 24 && e.identifier != identifier {
                    handle = e
                    break
                }
                if handle != nil { break }
            }
            guard let handle else { return nil }
            if target.frame.midX > app.windows.firstMatch.frame.maxX { handle.swipeLeft(velocity: .slow) } else { handle.swipeRight(velocity: .slow) }
            pause(0.5)
            if let e = hit(identifier) { return e }
        }
        return nil
    }

    /// Opens a panel through the real UI: its tab or strip button, else the "More" panels menu, else the toolbar
    /// overflow menu (narrow iPad windows have no strip). Returns whether the panel's content showed.
    func openPanel(_ id: String) -> (ok: Bool, detail: String) {
        dismissStrays()
        var route = "tab"
        if let tab = scrollIntoView(id) {
            tab.tap()
        } else if let more = scrollIntoView("morePanels") {
            route = "more-menu"
            more.tap()
            pause(0.6)
            guard let item = hit(id) else {
                dismissStrays()
                return (false, "morePanels menu opened but \(id) is not in it")
            }
            item.tap()
        } else if let overflow = hit("menu.more") {
            route = "overflow-menu"
            overflow.tap()
            pause(0.6)
            guard let panels = hit("menu.panels") else {
                dismissStrays()
                return (false, "overflow menu has no menu.panels submenu")
            }
            panels.tap()
            pause(0.6)
            guard let item = hit(id) else {
                dismissStrays()
                return (false, "menu.panels has no \(id)")
            }
            item.tap()
        } else {
            return (false, "no tab, no morePanels and no menu.more reachable")
        }
        pause(1.0)
        let content = Self.contentID(forPanel: id)
        if element(content).waitForExistence(timeout: 6) {
            var detail = "opened via \(route), content \(content)"
            if element("panelTitle").exists { detail += ", title='\(element("panelTitle").label)'" }
            return (true, detail)
        }
        return (false, "tapped via \(route) but content \(content) never appeared")
    }
}
