# Known issues (FilmCraft iOS)

Historical findings and current validation status.

## From the first iPad simulator run (iPad Pro 11-inch (M5), build d7786081)
- UI `testDemoDark` / `testDemoLight`: pass (≈ 39 s each), no crash.
- Unit 26/27: `EditorModelTests.runRegistersOneUndoStepPerCommand()` failed because it expected undo to restore
  an old `historyId`. The bridge mints a fresh change token on undo/redo. The test now compares serialized project
  state after each UndoManager step and still checks undo/redo availability. The current iPad run passed all
  7 `EditorModelTests`; the original 26/27 failure is historical.
- **No `-notes` attachments were found** in the UI run: the demo tests must always attach notes (even "nothing
  missing"), otherwise a green run can be hollow. Check `UITestSupport.swift` attachment lifetime
  (`.keepAlways`) and that `run-ui-tests.sh` exports attachments from the right test ids.

## Current focused UI status (2026-10-24)
- The first three iPad user-story cases failed before their full assertions: the wide dock menu existed but was not
  hittable, portrait More was absent, and Split could not find toolbar Undo. `DemoWindow` now has the missing
  `NavigationStack`; this historical result does not measure the current toolbar.
- Against commit `a267d3c7`, Split/Undo/Redo **passed** on iPad with an observed selected clip and playhead inside it.
  Both panel stories executed but failed because the test could not reach `panel.projectNotes` in the long native
  Panels menu after bounded scrolling. The dock and sheet assertions after that selection remain unverified.
- The rightmost panels toggle, New from Media launch picker, persistent media-copy path, and ownership regression
  compile in a generic simulator bundle; focused runtime tests and actual iCloud availability remain unverified.
- The 24 panels routed through `GenericPanel` still need dedicated content and action tests; panel reachability alone
  is not feature completion.
- Full-screen viewer mode and its dedicated exit control are not implemented in the current FilmCraft Swift UI;
  the panel visibility toolbar button does not change that gap.
