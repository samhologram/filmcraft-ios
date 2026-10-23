import XCTest

/// Runs every command of the catalog (`catalogDump`: engine and UI-only commands, including the Window-menu panel
/// entries); the palette is scrolled as a cross-check and its differences are reported; each command is then found again by
/// searching its id and run. Parameter sheets are filled with defaults and confirmed, alerts and the engine's
/// messages are recorded in full, state is restored by undo (or a relaunch when a command replaced the project).
/// Only a crash fails; the rest is in the `<prefix>-commands-summary` attachment.
///
/// A full run takes long (several hundred commands): use `TEST_RUNNER_TOUR_LIMIT` / `TEST_RUNNER_TOUR_ONLY`.
@MainActor
final class CommandTourUITests: TourTestCase {
    func testCommandsPortrait() throws { try tour(landscape: false) }
    func testCommandsLandscape() throws {
        guard isPad else { throw XCTSkip("landscape tours run on iPad; the iPhone portrait run covers the narrow layout") }
        try tour(landscape: true)
    }

    private struct Row { let id: String; let enabled: Bool; let label: String }

    private func enumeratePalette() -> [Row] {
        guard openPalette() else { note("enumerate: palette could not be opened"); return [] }
        expandPalette()
        let list = element("palette")
        var rows: [Row] = []
        var seen = Set<String>()
        var stagnant = 0
        for _ in 0..<250 {
            var fresh = 0
            for b in list.buttons.allElementsBoundByIndex where b.exists {
                let ident = b.identifier
                guard ident.hasPrefix("command."), seen.insert(ident).inserted else { continue }
                rows.append(Row(id: String(ident.dropFirst("command.".count)), enabled: b.isEnabled,
                                label: b.label.replacingOccurrences(of: "\n", with: " ")))
                fresh += 1
            }
            stagnant = fresh == 0 ? stagnant + 1 : 0
            if stagnant >= 3 { break }
            let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            let to = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        dismissStrays()
        attachText(rows.map { "\($0.id)\t\($0.enabled ? "enabled" : "DISABLED")\t\($0.label)" }.joined(separator: "\n"), name: "palette-ids")
        return rows
    }

    private func tour(landscape: Bool) throws {
        startTour(name: "commands", landscape: landscape)
        defer { attachSummary() }
        let scrapedRows = enumeratePalette()
        extraSummaryLines.append("palette rows enumerated: \(scrapedRows.count)")
        var rows = scrapedRows
        if let dump = readCatalogDump(), !dump.commands.isEmpty {
            crossCheck(kind: "commands", catalog: dump.commands, scraped: scrapedRows.map(\.id))
            let byID = Dictionary(scrapedRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // Catalog order; a command the palette never listed is still searched (and ends NOT-REACHED: missing).
            rows = dump.commands.map { byID[$0] ?? Row(id: $0, enabled: true, label: "") }
        } else {
            note("commands: using the palette-scraped list (no catalogDump)")
        }
        if rows.isEmpty { XCTFail("the command palette listed no commands"); return }
        if let only { rows = rows.filter { only.contains($0.id) } }
        if let limit { rows = Array(rows.prefix(limit)) }
        var deferred: [Row] = []
        for row in rows where !run(row, final: false) { deferred.append(row) }
        // Second chance for rows that were disabled: earlier commands may have changed the state.
        for row in deferred { _ = run(row, final: true) }
    }

    /// Returns false when the row was disabled and may be retried later.
    private func run(_ row: Row, final: Bool) -> Bool {
        let id = row.id
        let status = runPaletteCommand(id)
        var detail = ""
        var cause = ""
        var reached = false
        if status == "ran" {
            reached = true
            var parts: [String] = []
            let sheet = resolveSheet()
            if !sheet.text.isEmpty { parts.append(sheet.text) }
            var refusals: [String] = []
            if let r = sheet.refused { refusals.append(r) }
            refusals += dismissStrays()
            if !refusals.isEmpty {
                reached = false
                cause = "engine-refused"
                parts.append("MESSAGE=" + refusals.joined(separator: " || "))
                note("\(id): \(refusals.joined(separator: " || "))")
            }
            if app.state != .runningForeground { parts.append("left the app (external URL or system UI); brought back") }
            detail = parts.joined(separator: "; ")
        } else if status.hasPrefix("disabled") {
            if !final { return false }
            cause = "disabled"
            detail = status
        } else {
            cause = status == "missing" ? "missing-identifier" : status
            detail = status
        }
        if !alive(id) { return true }
        record(id, reached: reached, cause: cause, detail)
        recover(after: id)
        return true
    }

    /// Back to a valid document: no stray UI, playback stopped, panel sheet closed, undo what the command did.
    private func recover(after id: String) {
        dismissStrays()
        closePanelIfOpen()
        stopPlaybackIfRunning()
        undoAll(max: 4)
        ensureProjectValid(after: id)
    }
}
