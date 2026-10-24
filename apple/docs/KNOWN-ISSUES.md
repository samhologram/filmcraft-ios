# Known issues (FilmCraft iOS)

Recorded while the port is on hold; fix when work resumes.

## From the first iPad simulator run (iPad Pro 11-inch (M5), build d7786081)
- UI `testDemoDark` / `testDemoLight`: pass (≈ 39 s each), no crash.
- Unit 26/27: **FAIL** `EditorModelTests.runRegistersOneUndoStepPerCommand()` (EditorModelTests.swift:37,
  `model.state.historyId == afterFirst`): the engine history id moves more than once per `run()`, i.e. one command
  produces more than one history step (or `refresh` journals something). Check `EditorModel.run`/`finishMutation`
  and the bridge's `history_id` bump in `apple/bridge/src/lib.rs` (`execute`) — the id must change exactly once per
  journaled command.
- **No `-notes` attachments were found** in the UI run: the demo tests must always attach notes (even "nothing
  missing"), otherwise a green run can be hollow. Check `UITestSupport.swift` attachment lifetime
  (`.keepAlways`) and that `run-ui-tests.sh` exports attachments from the right test ids.
