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
- Three iPad user-story cases executed against the first dock bundle and failed before their full assertions:
  the wide dock menu existed but was not hittable, the portrait More menu was absent, and the split story added
  a real clip but could not find toolbar Undo. The demo `WindowGroup` lacked a navigation host for its system toolbar.
  `DemoWindow` now provides a `NavigationStack`; the rebuilt bundle and early text hierarchy attachment await rerun.
- The 24 panels routed through `GenericPanel` still need dedicated content and action tests; panel reachability alone
  is not feature completion.
