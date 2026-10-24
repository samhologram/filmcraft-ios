# FilmCraft: user-story UX validation, iPadOS and iOS

## Latest FilmCraft checkpoint — 2026-10-24

Luna executed all three iPad cases against `a267d3c7`: Split/Undo/Redo passed with a selected clip and interior
playhead; the wide and portrait panel cases failed to reach Project Notes through the long native Panels menu.
Later source changes (rightmost panels toggle, picker-first New from Media, persistent owned media copies) and a
new ownership unit case compile in the generic simulator bundle. Their focused runtime results are pending;
the earlier table below is retained as historical evidence, not the latest pass/fail classification.

## Current evidence checkpoint — 2026-10-24 18:18 EDT

This checkpoint supersedes earlier status statements below. Astra reviews source/test design and Luna executes runtime cases. Latest observations are attributed to the parent/Luna/Sol handoff where no separate log inspection is stated; no new runtime test was performed for this report. Times identify this review, not invented execution timestamps.

| Platform | Classification | Current evidence and limit | Evidence path / attribution |
|---|---|---|---|
| Shared model | PASS |23 bridge and7 EditorModel tests pass. | `apple/build/results/luna-editor-tests.log`; parent/Sol handoff |
| iPadOS | PASS, limited fixture improvement | NavigationStack host fix made More toolbar visible and tappable. This alone does not pass panel or editing stories. | `apple/build/results/luna-navfix-stories.log` / `.xcresult` |
| iPadOS | Test preconditions / unreached | Three old UI cases failed amid delayed Photos authorization, a tail item in a native panel menu, and split without a demonstrated interior playhead. No independent panel-routing or split-engine defect is established. | `apple/build/results/luna-navfix-stories.log` / `.xcresult` |
| iPadOS | COMPILED, NOT RUN | a267 WIP contains all three fixture fixes. Zero-test dispatch is not a pass or app failure.24 generic panels retain PARTIAL status until their actual routes/outcomes execute. | Current owner build/handoff; prior selected-case logs under `apple/build/results/` |
| iOS | NOT TESTED | Phone editing and panel routes have not run; model test success cannot stand in for phone UX. | No phone runtime evidence in current handoff |

**Common limits:** Native DocumentGroup edit → normal close → process relaunch → reopen of the same native file remains unverified. UndoManager registration paths were found; absent explicit publisher sends are not an autosave defect. Photo's explicit flat-image copy queue is a separate verified workflow. Do not classify every raw control-frame count below44pt as a UX defect: stock toolbar controls may use system hit regions; require actual hit-testing/interaction evidence. Light's missing manual removal and unavailable optional model remain explicit capability gaps. Current phone results apply only to Photo EditCopy; the other apps' iPhone UX remains unrun.

Historical matrices and earlier evidence follow; retain their executable selectors, but use this checkpoint for current pass/fail classification.

Confirmed runtime test-precondition defect: dock test ran portrait at 834×1210, below source threshold 900, so menu.panels was absent. Corrected test asserts landscape width; a separate portrait case verifies supported sheet UX. Four bespoke panel implementations exist; generic catalog content must not be reported as full specialist editing UX. CONTRACT documents foreign-copy/new-from-media/native decoder gaps; current tests do not close them.

## Story-to-test matrix

| User goal | iPadOS executable case | iOS executable case / gap | Required observable result |
|---|---|---|---|
| Cut a movie and recover the original edit | `UserStoryUITests/testSplitClipUndoRedoPortrait` (new) | Same selector | A selected demo clip split after 12 frame steps adds a clip; undo restores original clip IDs; redo restores split IDs |
| Arrange dock panels while editing | `PanelDockUITests/testPanelCanBeAddedReopenedCollapsedAndHidden` (corrected; landscape >=900pt) | Not applicable as dock UI; run sheet story below | Project Notes opens/reopens, selected tab visible, collapse/hide/show, Media import header |
| Access a secondary panel in a narrow editor | `PanelDockUITests/testPortraitPanelSheetKeepsOpenedAndReopenedTabVisible` (new; portrait <900pt) | Same selector | More → Panels → Project Notes sheet; selected/hittable tab and actual body; close/reopen retains timeline |
| Media from Photos and export | `PhotosIntegrationUITests/testAuthorizedBrowseAndInsert`, `testExportToPhotos`, `testDeniedState`, `testLimitedState` | Same explicit permission fixtures | Timeline receives media, Photos receives exported result; permission state asserted |
| Light/dark, every panel/tool/menu | `FilmCraftUITests/testDemoLight`, `testDemoDark`; portrait/landscape tours | Portrait tours; no iPad-only skip counted | Read notes and NOT-REACHED, especially generic command panels |
| Project save/import roundtrip | Full UI roundtrip pending | Same gap | `.fcproj` reopened with edits/media; source retained; missing assets handled |

## Execution and evidence rules

Astra authored/reviewed these cases on 2026-10-24; Luna executes. The first iPad run executed all three new cases;
the full workflows remain **unverified** after the demo toolbar host setup failed. A rebuilt bundle includes a
`NavigationStack` for the demo scene and awaits rerun. Sol owns production fixes and generic `build-for-testing`;
use current `apple/build/dd`, never an old `dd-core` bundle.

1. Shared iPad `81A653B3-9027-4C16-8335-320CB937C66C` first: portrait, then landscape, then genuinely resized narrow window if available. Shared iPhone `FF7E37C5-12E6-483D-8887-D09D18EEB4A4` only after iPad fixes. One simulator under workspace `.sim.lock`; no build while holding it.
2. Run `-only-testing:FilmCraftUITests/<Class>/<method>` with the names above, `-collect-test-diagnostics never`. No screenshots. Retain assertion text, hierarchy/frames, logs and notes. Remove app/runner after each run per cookbook.
3. Record build path/commit, device, window size, orientation, appearance, fixture/permission state, exact selector, completed/failed/aborted, first failing step and full error. A skipped case, early return, missing fixture or NOT-REACHED is **not** a passed workflow.
4. Photos integration needs a known seeded asset and explicit granted/denied/limited states. Native-copy tests need known source bytes/hash, produced native URL and repeat-open identity. Demo data proves editing UI only. Never touch a personal library fixture.
5. Compare tap count only for the same route and setup. Review clipped/hittable frames, selection traits, return-to-canvas, sheet dismissal and contextual actions. System menu rows under 44pt alone are not UX bugs. Menu plus hardware shortcut is legitimate duplication; the user rejected parallel floating panel launchers.

## Remaining cross-platform acceptance work

- Reorder/stack and collapsed/selected panel state across app termination **without reset launch arguments**; PhotoCraft already has a reusable persistence case. Repeat Window/menu route separately from dock Add; selected tab must scroll into view when already selected, collapsed or previously hidden.
- Real narrow-window resizing (Stage Manager/Split View), landscape transitions mid-edit, dark/light and large Dynamic Type. Orientation alone is not proof of resizable-window support. Accessibility evidence cannot establish contrast/color correctness without render inspection; no screenshots requested.
- Hardware shortcuts and multi-finger undo/redo must show document changes, not just menu presence. Pencil hover/squeeze/pressure and physical keyboard behavior need an appropriate device pass; list unavailable hardware as unverified, not successful.
- Native document/library persistence and import/export roundtrip beyond available tests, error recovery, permission denial and media relinking. Unsupported features remain tracked gaps.

## Bounded UX review findings

| Priority | Platform | Evidence / reproduction | Interpretation and next action |
|---|---|---|---|
| P1 | iPad / all platforms at risk | Vector shortcut duplicate caused launch crash; earlier runtime used stale dd-core | Root reports source fix + regression; Luna must run current bundle before UX suite |
| P1 | Light iPad | Masking Add → Subject did not create mask; later Crop/Remove failed after cached original absolute path became stale | Root reports repairs; rerun F and tour on fresh current bundle; no cascade counted as separate proven defect |
| P2 | Film iPad | Portrait 834pt tried to find wide dock (`>=900`) | Test setup defect fixed with landscape case and separate portrait sheet story |
| P2 | Fig iPad | New Design duplicate query failed to open document | Test fixture fixed via hittable candidate plus strict demoReady/canvas; await current run |
| P2 | iOS and iPadOS | Legacy smoke steps often log missing action as notes; iPad-only panel tests skip/return on phone | New strict result stories reduce false green; inspect legacy notes and keep remaining phone gaps explicit |

This report incorporates parent/Luna observations, not an independent runtime pass. Each new failure must be classified as product defect, test defect or unavailable fixture before a production change.

## Focused execution handoff

After the app owner rebuilds the complete test bundle and Luna obtains the shared lock, run from `filmcraft-ios/apple` (choose a fresh result path):

```sh
xcodebuild test-without-building -scheme FilmCraft -derivedDataPath build/dd \
  -destination 'id=81A653B3-9027-4C16-8335-320CB937C66C' \
  -only-testing:FilmCraftUITests/UserStoryUITests/testSplitClipUndoRedoPortrait \
  -collect-test-diagnostics never -resultBundlePath build/results/story-ipad.xcresult
```

Substitute other exact selectors from the matrix. After iPad fixes pass, repeat applicable cases with destination `id=FF7E37C5-12E6-483D-8887-D09D18EEB4A4` and a distinct result bundle. Use the existing orchestrator lock/uninstall wrapper; this command alone does not acquire the workspace lock. Require the requested test name and a nonzero completed-test count in results: exit zero with zero executed tests is not a pass.

## Phase 2 evidence review (2026-10-24)

- **Film iPad:** read `filmcraft-ios/apple/build/results/luna-story-suite.log`; three requested cases executed and failed. Landscape width precondition passed, but dock `menu.panels` existed and was not hittable. Portrait `menu.more` was absent. Split added a clip (strict assertion passed), then `command.edit.undo` was absent: cut is observed, undo/redo remains unreached. Portrait hierarchy in `/tmp/film-story-attachments/D9415F75-5DA6-4D1D-92CD-75EF5E5C0557.txt` has editing/transport controls but no navigation bar/Undo. Source DemoApp → DemoWindow → EditorScene has no NavigationStack while PadEditorView supplies Undo/More only through toolbar. **P1 fixture-host hypothesis:** demo may omit toolbar navigation host; sent to Film owner. Do not infer an undo-engine defect or generalize to normal DocumentGroup. Landscape dock hit testing needs separate frame evidence.
- **Fig iPad:** read `figcraft-ios/apple/build/results/luna-dock-final.log`: one case executed, failed before demo at dynamic button enumeration with stale element index 10. This is a setup failure; no dock assertions reached. Fig owner owns a stable exact-label New Design retry helper and replacement in both dock and new opacity story. No independent all-buttons opener should be reintroduced.
- **Vector:** latest Luna report confirms six catalog consistency tests passed, including reserved paste shortcut regression. Dock run executed zero tests because test binary lacked that selector. Require regenerated project/current test binary, nonzero count and named selector; a green process exit is not runtime UX proof.
- **Photo:** new phone stories are source-authored only, not compiled/executed. The no-screenshot reusable cases are EditCopy, NewFromPhoto, PlacePhoto, Fullscreen and UserStory S1–S9. Do **not** schedule legacy PhotoCraftUITests/testScreenshotsDark or testScreenshotsLight: their `shot` helper calls XCUIScreen.main.screenshot(), contrary to this run's request.
- **Light:** no new phase-2 runtime evidence reviewed. F and current-original-path tour need Luna rerun; previous reports do not establish success of the rebuilt fixes.


## Native document persistence and isolation audit (2026-10-24)

**Source review, not a runtime persistence pass.** Apple's [ReferenceFileDocument contract](https://developer.apple.com/documentation/swiftui/referencefiledocument) says SwiftUI cannot detect reference-property mutations itself and directs apps to register mutations with the environment UndoManager. The local iPhoneOS SDK interface also requires ObservableObject and Sendable and does not isolate serialization methods to MainActor. Absence of explicit `objectWillChange.send()` alone does **not** establish broken autosave, and is not grounds for a blanket publisher patch.

All four native document editors have scene UndoManager wiring and engine-history registration: Photo `registerEngineUndo` plus `markEdited` for non-history edits; Vector `finishMutation` and grouped interaction completion; Fig refresh/history-ID tracking; Film `finishMutation`, drag completion and media import. These are architectural evidence, not proof that every edit is registered or saved before closure. The remaining risks to test are mutations before manager attachment, non-history content changes, and asynchronous mutation/close ordering. A focused owner unit check should attach an UndoManager, perform one real command and one gesture transaction, and verify registration/undo/redo; publisher emission is not the acceptance criterion.

**Confirmed isolation mismatch:** FigCraftDocument's new/read constructors use MainActor.assumeIsolated to create EditorModel although the document API may call from other isolation domains. A runtime crash has not been observed in this audit. Minimal fix is to store the thread-safe engine handle directly and lazily create the model on MainActor, matching Vector/Film; keep serialization independent of the model and avoid reading current UI traits from background document callbacks. Photo, Vector and Film already use this handle/lazy-model architecture in the inspected source.

**Required iPadOS and iOS acceptance (still incomplete):** open a known native file through the real DocumentGroup with a foreground actionable editor; change a uniquely observable property; return to Files normally; terminate and relaunch; reopen the same URL and assert the exact changed property. Repeat with Undo and Redo, and a drag/continuous adjustment. Inspect the saved native bytes through the engine after normal close to distinguish disk persistence from cached model state. Use layer opacity for Photo/Fig, shape or layer property for Vector, and a selected clip's trim/split state for Film. Keep the mutation outcome assertion strict and confirm the correct document identity. First test normal close; immediate termination during an in-flight edit is a separate durability scenario.

Photo flat-image EditCopy exercises a separate explicit copy queue, not native `.pcraft` autosave. Film's demo WindowGroup does not exercise DocumentGroup persistence. A pre-seeded native file can isolate autosave testing from browser creation, but must not count as a passed New Document story. No native persistence pass or observed data-loss claim is made here.
