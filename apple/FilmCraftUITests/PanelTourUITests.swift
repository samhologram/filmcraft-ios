import XCTest

/// Opens every panel (`panel.<id>`) through the real UI, acts on its first control, undoes, closes. Only a crash
/// fails; the rest is in the `<prefix>-panels-summary` attachment.
///
/// Panel list: read from the app: the tabs / strip (scrolled), the "More" panels menu (`morePanels`) and, on
/// narrow iPad windows, the toolbar overflow menu (`menu.more` > `menu.panels`). Panels the layout always shows
/// (program, timeline) or hides by design (tools) are not in those menus.
@MainActor
final class PanelTourUITests: TourTestCase {
    func testPanelsPortrait() throws { try tour(landscape: false) }
    func testPanelsLandscape() throws {
        guard isPad else { throw XCTSkip("landscape tours run on iPad; the iPhone portrait run covers the strip") }
        try tour(landscape: true)
    }

    // MARK: Enumeration

    private func enumeratePanels() -> [String] {
        var ids: [String] = []
        func add(_ found: [String]) { for id in found where !ids.contains(id) && id != "panel.close" { ids.append(id) } }
        // 1. Tabs / strip: scroll to the left end, then step right until nothing new.
        if let handle = hit(prefix: "panel.") {
            for _ in 0..<4 { handle.swipeRight(velocity: .fast) }
            pause(0.4)
            var stagnant = 0
            for _ in 0..<12 {
                let before = ids.count
                add(identifiers(prefix: "panel."))
                stagnant = ids.count == before ? stagnant + 1 : 0
                if stagnant >= 2 { break }
                guard let h = hit(prefix: "panel.") else { break }
                h.swipeLeft(velocity: .slow)
                pause(0.4)
            }
        }
        // 2. The More menu.
        if let more = scrollIntoView("morePanels") {
            more.tap()
            pause(0.7)
            add(identifiers(prefix: "panel."))
            dismissMenu()
        }
        // 3. Narrow iPad: overflow menu > Panels.
        if ids.isEmpty, let overflow = hit("menu.more") {
            overflow.tap()
            pause(0.6)
            if let panels = hit("menu.panels") {
                panels.tap()
                pause(0.7)
                add(identifiers(prefix: "panel."))
            }
            dismissMenu()
            dismissMenu()
        }
        extraSummaryLines.append("panels enumerated: \(ids.count): \(ids.joined(separator: ", "))")
        attachText(ids.joined(separator: "\n"), name: "panel-ids")
        return ids
    }

    // MARK: Acting

    /// One representative action per panel kind; returns what was done (empty when there was nothing to act on).
    private func act(on id: String) -> String {
        switch Self.contentID(forPanel: id) {
        case "mediaBrowser":
            if let tab = hit("mediaProjectTab") { tab.tap(); pause(0.6) }
            let count = identifiers(prefix: "media.").count
            if let photos = hit("import.photos") { photos.tap(); pause(0.6) }
            return "project media rows: \(count)"
        case "effects":
            var done: [String] = []
            if let search = hit("effectsSearch") {
                search.tap()
                search.typeText("blur")
                pause(0.6)
                done.append("searched 'blur'")
                let key = app.keyboards.buttons["Search"].firstMatch
                if key.exists, key.isHittable { key.tap() } else if app.keyboards.buttons["return"].firstMatch.exists { app.keyboards.buttons["return"].firstMatch.tap() }
            }
            if let row = hit(prefix: "effectRow_") { row.tap(); pause(0.8); done.append("tapped \(row.identifier)") }
            return done.joined(separator: ", ")
        case "effectControls":
            if let toggle = hit(prefix: "fx.toggle.") { toggle.tap(); pause(0.6); return "tapped \(toggle.identifier)" }
            return element("fxClipName").exists ? "clip shown, no effects to toggle" : ""
        case "audioMixer":
            return "mixer strips: \(identifiers(prefix: "mixerTrack_").count)"
        default:
            let list = element("panelCommands")
            for e in list.buttons.allElementsBoundByIndex where e.exists && e.identifier.hasPrefix("command.") && e.isEnabled && canTap(e) {
                let cid = e.identifier
                e.tap()
                pause(1.2)
                return "tapped \(cid)"
            }
            return ""
        }
    }

    // MARK: Tour

    private func tour(landscape: Bool) throws {
        startTour(name: "panels", landscape: landscape)
        defer { attachSummary() }
        let scraped = enumeratePanels()
        var panels = scraped
        if let dump = readCatalogDump(), !dump.panels.isEmpty {
            crossCheck(kind: "panels", catalog: dump.panels, scraped: scraped)
            panels = dump.panels
        } else {
            note("panels: using the UI-scraped list (no catalogDump)")
        }
        if panels.isEmpty { XCTFail("the tour found no panel.* element"); return }
        if let only { panels = panels.filter { only.contains($0) } }
        if let limit { panels = Array(panels.prefix(limit)) }
        for id in panels { visit(id) }
    }

    private func visit(_ id: String) {
        closePanelIfOpen()
        // effectControls shows the selected clip.
        if id == "panel.effectControls" { _ = selectFirstClip() }
        let (ok, detail) = openPanel(id)
        if !alive(id) { return }
        guard ok else {
            record(id, reached: false, cause: detail.contains("not in it") || detail.contains("no tab") ? "missing-identifier" : "panel-did-not-open", detail)
            dismissStrays()
            return
        }
        var details = [detail]
        let action = act(on: id)
        if !action.isEmpty { details.append(action) }
        pause(0.6)
        let sheet = resolveSheet()
        if !sheet.text.isEmpty { details.append(sheet.text) }
        let alerts = dismissStrays()
        var refusals = alerts
        if let r = sheet.refused { refusals.append(r) }
        if !alive(id) { return }
        if !refusals.isEmpty {
            details.append("REFUSED=" + refusals.joined(separator: " || "))
            note("\(id): \(refusals.joined(separator: " || "))")
        }
        let acted = !action.isEmpty
        let cause = !refusals.isEmpty ? "engine-refused" : (acted ? "" : "nothing-to-act-on")
        record(id, reached: acted && refusals.isEmpty, cause: cause, details.joined(separator: "; "))
        undoAll(max: 3)
        closePanelIfOpen()
        ensureProjectValid(after: id)
    }
}
