# Review A: FilmCraft/UI/{Timeline,Shared,Pad,Phone}

Read-only review. No Swift edited, nothing built, no simulator booted. Paths are relative to `apple/`.
Ordered most severe first. Crash items are on the never-crash rule (AGENTS.md §0).

## Findings

1. `FilmCraft/UI/Timeline/WaveformView.swift:15` — `Task.detached` reads `WaveformCache.buckets`, a `@MainActor` static, from a nonisolated closure. Under Swift 6 strict concurrency this is an isolation error (likely build break). — Hoist to a local before the closure, or declare `nonisolated static let buckets: UInt32 = 800` at `:8`.

2. `FilmCraft/UI/Timeline/WaveformView.swift:51` — `Int((source / total) * Double(peaks.count))` traps when the value exceeds the Int range or is non-finite. `clip.sourceIn` is an arbitrary i64 from the project file and `total` can be a few ticks, so a hostile project crashes the app. — Compute the Double, check `isFinite`, clamp to `0...Double(peaks.count - 1)`, then convert.

3. `FilmCraft/UI/Timeline/WaveformView.swift:40` — `clip.end - clip.start` is an unchecked Int64 subtraction and traps on overflow. — Use `subtractingReportingOverflow`, or subtract in Double: `max(1, Double(clip.end) - Double(clip.start))`.

4. `FilmCraft/UI/Timeline/TimelineView.swift:84` — `model.state.playhead + TickMath.clampTicks(...)` is an unchecked Int64 add and traps near `Int64.max`. Line 239 already uses `&+`. — Use `&+` (`seek()` clamps to the duration) or clamp in Double.

5. `FilmCraft/UI/Timeline/TimelineView.swift:281` — same unchecked `playhead + clampTicks(...)` add on the razor path. — Same fix as item 4.

6. `FilmCraft/UI/Timeline/TimelineView.swift:177-178` — `clip.start - playhead` and `clip.end - playhead` are unchecked Int64 subtractions before the Double division. — Subtract in Double: `(Double(clip.start) - Double(playhead)) / tpp`.

7. `FilmCraft/UI/Timeline/TimelineRuler.swift:64` — `marker.at - model.state.playhead` is an unchecked Int64 subtraction. — Subtract in Double, as in item 6.

8. `FilmCraft/UI/Shared/ExportSheet.swift:84` — `Int(((model.exportProgress ?? 0) * 100).rounded())` traps on NaN or infinity. Line 81 clamps; this line does not. — Clamp first: `let pct = min(1, max(0, model.exportProgress ?? 0)) * 100`, then `Int(pct.rounded())`.

9. `FilmCraft/UI/Shared/UIHelpers.swift:164` — `Int(min(seconds, 359_999).rounded(.down))` converts before `max(0, …)`, so a large negative finite `seconds` traps. Today's ruler keeps the playhead non-negative, so this is hygiene, not a live crash. — `Int(max(0, min(seconds, 359_999)).rounded(.down))`.

10. `FilmCraft/UI/Shared/TopBarControls.swift:78` — `palette.open` is not the §5 id (`palette`). It is also a dotted `x.y` form that is not a command, which §5 forbids. UI tests written from §5 will not find it. — Use `palette`, or add a §5 entry if the rename is intended.

11. `FilmCraft/UI/Shared/ExportSheet.swift:133` and `FilmCraft/UI/Shared/TopBarControls.swift:64` — the sheet's Form and the toolbar `ShareButton` both use identifier `export`. The toolbar button stays in the accessibility tree behind the sheet, so `export` is ambiguous in UI tests. — Give the sheet root a distinct id (e.g. `exportSheet`), keep `export` on the button, and record it in §5.

12. `FilmCraft/UI/Shared/EditBar.swift:118`; `FilmCraft/UI/Shared/TopBarControls.swift:49`, `:123`, `:130` — `menu.tools`, `menu.panels` and `menu.more` are dotted non-command ids not listed in §5. — Rename to non-dotted ids (`toolsMenu`, `panelsMenu`, `moreMenu`) or add them to §5.

13. `FilmCraft/UI/Timeline/ClipView.swift:87` and `:144-145` — the clip uses `.accessibilityElement(children: .combine)`, which flattens the trim handles into the clip. The `trimHandle_…` ids and the "Trim start" / "Trim end" labels are not reachable as separate elements, so XCUITest cannot target them. — Use `children: .contain` with the clip's label, value and actions on a child, or expose trim as named accessibility actions on the clip.

14. `FilmCraft/UI/Shared/TopBarControls.swift:92` — `AddMediaButton` opens the media browser (the `file.import` command via `runIOSOverride`) but uses id `addMedia`, which §5 does not list. A toolbar surface for a command should carry `command.file.import`. `FilmCraft/UI/Timeline/TimelineView.swift:202` `timelineAddMedia` is also unspecified. — Add both to §5 and use `command.file.import` on the toolbar button, or document the exception.

15. `FilmCraft/UI/Shared/EditorRootView.swift:162-202` (keys at `:181-187`, buttons at `:193-196`) — unmodified single keys (Space, J/K/L, arrows, every tool letter) are hidden keyboard-shortcut buttons on the root. With a hardware keyboard they can fire while the palette search field, a CommandSheet text field or the media search is focused, and swallow typed characters. Not verified on a simulator. — Skip unmodified shortcuts while a sheet is presented (`showCommandPalette`, `pendingCommand`, `showMediaBrowser`, `showExport`), or drop modifier-less keys from the root.

16. `FilmCraft/UI/Shared/EditorRootView.swift:132` — a fixed 450 ms `Task.sleep` waits for the panel sheet to dismiss before presenting the next sheet. On a slow device the next sheet collides with the dismissal; on a fast one it waits needlessly. — Drive the follow-up presentation from the panel sheet's `onDismiss` (store a pending closure there) instead of a timer.

17. `FilmCraft/UI/Shared/ExportSheet.swift:171` — each export creates `FilmCraftExport-<uuid>` in the temp directory and never removes it, on success, cancel or failure. Rendered movies accumulate. — Remove the folder in the `fileMover` completion and when the export fails or is cancelled.

18. `FilmCraft/UI/Shared/ExportSheet.swift:151-153` — on a `fileMover` failure `movingFile` stays set, so "Choose a Location…" reappears for a file that may be gone. The error also goes to the `lastError` alert. — Clear `movingFile` in both branches and remove the temp folder.

19. `FilmCraft/UI/Phone/PhoneEditorView.swift:11` — `viewerHeight` has a 150 pt floor, and the transport, edit bar and tool strip have fixed heights. On short landscape or narrow split-view windows the timeline gets no height. Not verified on a simulator. — Derive the viewer height from the space left after the fixed rows, or give the timeline a minimum height.

20. `FilmCraft/UI/Pad/PadEditorView.swift:26` and `FilmCraft/UI/Phone/PhoneEditorView.swift:18` — `TimelineView` shadows SwiftUI's public `TimelineView`. It compiles (module types win), but any future SwiftUI `TimelineView` use in this module silently binds to the editor view. — Rename to `EditTimelineView` or `MultitrackTimelineView`.

21. `FilmCraft/UI/Timeline/WaveformView.swift:13-15` — `handle` (a `ProjectHandle` from the `@preconcurrency` bridge module, not Sendable under Swift 6) is captured by a `Task.detached` closure. The diagnostic is probably downgraded by `@preconcurrency`, but if it is not, follow the `SendableImage` pattern from `Core/EditorModel.swift:7`. — Wrap it, or fold into the fix for item 1.

22. `FilmCraft/UI/Timeline/ClipView.swift:67-68`, `:75`, `:131`, `:134` — hard-coded `.white`, `.black` stroke, shadow and handle colours with no justifying comment. The comment at `:40` covers only the clip tints. — Add a comment that these are content colours on the clip tint, or use semantic colours.

23. `FilmCraft/UI/Timeline/WaveformView.swift:57` — `.white.opacity(0.75)` waveform fill with no comment. — Same as item 22.

24. `FilmCraft/UI/Shared/ViewerView.swift:29` — `.white.opacity(0.35)` placeholder glyph. The comment at `:17` covers only the black letterbox. — Add a comment.

25. Identifiers not listed in CONTRACT §5 (not wrong, but UI tests cannot rely on them): `FilmCraft/UI/Shared/ExportSheet.swift:63` `exportResolution`, `:72` `exportQuality`, `:89` `exportCancel`, `:116` `exportMessage`, `:126` `exportChooseLocation`, `:139` `exportDone`; `FilmCraft/UI/Shared/EditorRootView.swift:79` `mediaAdding`, `:153` `errorOK`; `FilmCraft/UI/Timeline/TimelineRuler.swift:109`, `:113`, `:118`, `:123` `trackMute_` / `trackSolo_` / `trackVisible_` / `trackLock_`; `FilmCraft/UI/Timeline/ClipView.swift:145` `trimHandle_`; `FilmCraft/UI/Pad/PadEditorView.swift:111` `zoneDivider`. — Add them to §5 (non-dotted form is fine).

## Notes (not findings)

- Model API: every `EditorModel`, `ProjectState`, `ClipInfo`, `TrackInfo`, `MarkerInfo`, `ToolInfo`, `PanelInfo`, `ExportOptions`, `ExportDestination` and `CommandCatalog` member called from the in-scope files exists with matching labels and types (`run` returns `Bool` with `@discardableResult`; `undo`/`redo` return Void; `thumbnail(media:edge:)`, `audioPeaks(mediaId:buckets:)`, `execute(id:paramsJson:)`, `seek(_:)` and `stepFrame(_:)` match). The view initialisers in the Panels and Commands files match too. No mismatches found.
- Bindings: `FilmCraftKit/Sources/FilmCraftKit/` contains only `Exports.swift`, so the generated `filmcraft_apple.swift` is absent. Names were checked against CONTRACT §3 and their use in `Core/` and `Media/`.
- SwiftUI APIs were checked against the installed iPhoneOS SDK interfaces (`KeyboardShortcut.key` and `.modifiers` are public; `glass`, `glassProminent`, `fileMover`, `PointerStyle.rowResize`/`columnResize`, `Text.foregroundStyle` returning `Text`, `GraphicsContext.draw(_:at:anchor:)` for `Text` all exist).
- Force unwraps, `try!`, `as!`, `fatalError`, macOS-only APIs, `[Any]` literals and ambiguous `.infinity` in scope: none found. Array subscripts in scope are guarded.
- SF Symbols were NOT validated. No simulator runtime is installed on this machine (`/Library/Developer/CoreSimulator/Profiles/Runtimes` is missing, `Volumes` is empty, and the Xcode SDK has no `name_availability.plist`). Run the plist check on a machine with the iOS 26 runtime.
- Outside scope but relevant to CONTRACT §3: `apple/bridge/ui-commands.txt` contains only its header comment and no ids, so `scripts/check-command-ids.sh` cannot verify anything against it.

## Resolution (UI agent)

1 fixed (`nonisolated static let buckets`, local copy). 2 fixed (finite check + clamp before `Int`). 3 fixed (Double subtraction). 4 fixed (`&+`). 5 fixed (`&+`). 6 fixed (Double subtraction). 7 fixed (Double subtraction). 8 fixed (`progress` helper, NaN-safe). 9 fixed (`max(0, …)` before `Int`).
10 fixed: toolbar button is now `paletteOpen`; `palette` stays on the palette list. 11 fixed: sheet root is `exportSheet`, toolbar button keeps `export`. 12 rejected: `menu.tools`, `menu.panels`, `menu.more` sit under the reserved `menu.` prefix of the new §5 rule.
13 fixed: clip body is the combined `clip.<id>` element; trim handles are separate siblings `clip.<id>.trimStart` / `clip.<id>.trimEnd` (replaces `trimHandle_<id>_in|out`). 14 rejected: `addMedia` / `timelineAddMedia` are undotted widget ids, allowed by §5 (they open the browser, they are not `file.import` itself).
15 fixed: shortcut buttons are disabled while the palette, command sheet, export or media sheet is up, and while any UITextField/UITextView is editing (begin/end editing notifications). Not verified on device. 16 fixed: panel sheet `onDismiss` runs the queued presentation (no timer); the palette hands its choice to the root, which invokes it from the palette sheet's `onDismiss`.
17 fixed (temp folder removed after move, on failure/cancel and on Done). 18 fixed (`movingFile` cleared on both branches; picker dismissal keeps the file). 19 fixed: viewer height shrinks first, timeline has `minHeight` 150, short landscape windows use a side-by-side layout. 20 fixed: renamed `MultitrackTimelineView`.
21 fixed (`UIUnchecked<ProjectHandle>` in UIHelpers). 22, 23, 24 fixed (comments added). 25 accepted as undotted widget ids; additional new ids are listed in the report.
