import XCTest

/// Selects every timeline tool through the real UI (`tool.<id>`), verifies the selection state, acts with the
/// tool on the first clip, undoes, and restores the selection tool. Only a crash fails; the rest is in the
/// `<prefix>-tools-summary` attachment.
///
/// Tool list: read from the app. iPad (and any window with the toolbar): open `menu.tools` and collect the
/// `tool.*` items. iPhone / narrow windows: collect `tool.*` buttons from the bottom strip while scrolling it.
@MainActor
final class ToolTourUITests: TourTestCase {
    func testToolsPortrait() throws { try tour(landscape: false) }
    func testToolsLandscape() throws {
        guard isPad else { throw XCTSkip("landscape tours run on iPad; the iPhone portrait run covers the strip") }
        try tour(landscape: true)
    }

    // MARK: Enumeration

    private func enumerateTools() -> [String] {
        var ids: [String] = []
        func add(_ found: [String]) { for id in found where !ids.contains(id) { ids.append(id) } }
        if hasToolMenu {
            guard let menu = hit("menu.tools") else { note("enumerate: menu.tools is not hittable"); return [] }
            menu.tap()
            pause(0.8)
            add(identifiers(prefix: "tool."))
            dismissMenu()
        } else {
            // Strip: start from its left end, then scroll left until nothing new shows up.
            for _ in 0..<6 {
                guard let handle = hit(prefix: "panel.") ?? hit(prefix: "tool.") else { break }
                handle.swipeRight(velocity: .fast)
            }
            pause(0.4)
            var stagnant = 0
            for _ in 0..<20 {
                let before = ids.count
                add(identifiers(prefix: "tool."))
                stagnant = ids.count == before ? stagnant + 1 : 0
                if stagnant >= 2 { break }
                guard let handle = hit(prefix: "tool.") else { break }
                handle.swipeLeft(velocity: .slow)
                pause(0.4)
            }
        }
        extraSummaryLines.append("tools enumerated (\(hasToolMenu ? "toolbar menu" : "strip")): \(ids.count): \(ids.joined(separator: ", "))")
        attachText(ids.joined(separator: "\n"), name: "tool-ids")
        return ids
    }

    // MARK: Activation

    /// Selects `id` and verifies the selection. Returns (ok, cause, detail).
    private func activate(_ id: String) -> (Bool, String, String) {
        if hasToolMenu {
            guard let menu = hit("menu.tools") else { return (false, "off-screen", "menu.tools is not hittable") }
            menu.tap()
            pause(0.6)
            guard let item = hit(id) else {
                let present = element(id).exists
                dismissMenu()
                return (false, present ? "off-screen" : "missing-identifier", "tool item not in the opened menu")
            }
            let itemLabel = item.label.replacingOccurrences(of: "\n", with: " ")
            item.tap()
            pause(0.8)
            let menuLabel = element("menu.tools").label
            if !itemLabel.isEmpty, !menuLabel.contains(itemLabel) {
                return (false, "no-effect", "menu.tools label '\(menuLabel)' does not show '\(itemLabel)' after selecting")
            }
            // The active item carries .isSelected: reopen the menu and check.
            var detail = "selected via menu, menu.tools shows '\(menuLabel)'"
            if let again = hit("menu.tools") {
                again.tap()
                pause(0.5)
                detail += element(id).isSelected ? ", item isSelected" : ", item NOT marked isSelected"
                dismissMenu()
            }
            return (true, "", detail)
        }
        guard let button = scrollIntoView(id) else {
            return (false, element(id).exists ? "off-screen" : "missing-identifier", "strip button not tappable")
        }
        button.tap()
        pause(0.6)
        let selected = element(id).isSelected
        if !selected { return (false, "no-effect", "\(id) is not marked selected after tapping") }
        return (true, "", "selected via strip, isSelected true")
    }

    // MARK: Tour

    private func tour(landscape: Bool) throws {
        startTour(name: "tools", landscape: landscape)
        defer { attachSummary() }
        let scraped = enumerateTools()
        var tools = scraped
        if let dump = readCatalogDump(), !dump.tools.isEmpty {
            // The catalog is the list; a tool the UI cannot reach is recorded as NOT-REACHED when visited.
            crossCheck(kind: "tools", catalog: dump.tools, scraped: scraped)
            tools = dump.tools
        } else {
            note("tools: using the UI-scraped list (no catalogDump)")
        }
        if tools.isEmpty { XCTFail("the tour found no tool.* element"); return }
        if let only { tools = tools.filter { only.contains($0) } }
        if let limit { tools = Array(tools.prefix(limit)) }
        for id in tools { visit(id) }
        // Back to the selection tool.
        _ = activate("tool.selection")
    }

    private func visit(_ id: String) {
        var details: [String] = []
        let (ok, cause, detail) = activate(id)
        details.append(detail)
        if !alive(id) { return }
        guard ok else {
            record(id, reached: false, cause: cause, detail)
            _ = dismissStrays()
            return
        }
        // Act: one tap on the first clip with the tool active.
        let before = clipIDs.count
        if let clip = hittableClip() {
            clip.tap()
            pause(1.0)
            details.append("tapped \(clip.identifier): clips \(before) -> \(clipIDs.count)")
        } else {
            details.append("no clip to act on")
        }
        let alerts = dismissStrays()
        for a in alerts { note("\(id): alert: \(a)") }
        if !alive(id) { return }
        let refused = !alerts.isEmpty
        if refused { details.append("ALERTS=" + alerts.joined(separator: " || ")) }
        record(id, reached: !refused, cause: refused ? "engine-refused" : "", details.joined(separator: "; "))
        undoAll(max: 3)
        ensureProjectValid(after: id)
        _ = activate("tool.selection")
    }
}
