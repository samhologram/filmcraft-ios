# Review C: FilmCraft/Core, Media, App (read-only)

Paths are relative to `apple/`. Most severe first. Bridge checked against `apple/bridge/src/lib.rs` because
`FilmCraftKit/Sources/FilmCraftKit/filmcraft_apple.swift` is not generated yet, so label checks use CONTRACT §3 and the Rust signatures.

1. `FilmCraft/Core/EditorModel+Commands.swift:46-58` — [compile] `nonisolated static func implementsUI` reads `links` (L27) and `workspacePanels` (L36), which are main-actor-isolated statics of the `@MainActor` class; Swift 6 rejects the synchronous access. — Mark both `nonisolated private static let` (immutable `[String: String]`), or drop `nonisolated` from `implementsUI` (its only caller, `MenuLayout.isVisible`, is `@MainActor`).

2. `FilmCraft/Media/PlaybackEngine.swift:276, 284` (declared L112) — [compile] `nonisolated private static func fill` reads `sampleRate`, a main-actor static of `PlaybackEngine`. — Declare `nonisolated static let sampleRate: Double = 48_000`, or pass the rate in as a parameter.

3. `FilmCraft/App/FilmCraftApp.swift:10-16` — [compile] nonisolated `static func main()` calls `AppEnvironment.prepareLaunch()` (`@MainActor` class) and `DemoApp.main()` / `FilmCraftApp.main()` (the App protocol's `main` is main-actor isolated). — Annotate `@MainActor static func main()` on `FilmCraftLauncher`.

4. `FilmCraft/Core/ErrorText.swift:7-9` — [compile] `case .Failed(let message)`. UniFFI emits lowerCamelCase variant names, so the generated case is `.failed(message:)`, not `.Failed`. Unverified until the bindings exist (CONTRACT §3 "generated UniFFI labels differing from what the Swift assumed"). — Use `case .failed(let message)` after generating the bindings, and check every other label against them.

5. `FilmCraft/Core/EditorModel.swift:153-158` (second registration at L224 in `endDrag`) — [undo] `finishMutation` registers an UndoManager entry for every journaled command whose history changed, with no `isDragging` guard. The bridge bumps `history_id` on every journaled `execute` during an interaction (`apple/bridge/src/lib.rs:246-258`; `begin_interaction` at L492-500 sets the history limit to `usize::MAX`, so each edit pushes an undo entry). A drag of N commands registers N entries, and `endDrag` adds one more, so the UndoManager no longer matches the engine's single collapsed step. — Add `guard !isDragging` to the registration branch of `finishMutation` (keep `refresh` and `requestFrame`); only `endDrag` registers during a gesture.

6. `FilmCraft/Core/EditorModel+Media.swift:138-152` and `FilmCraft/Core/EditorModel.swift:204-213` — [undo, engine] Nested interactions. The bridge's `begin_interaction` is a no-op when one is open (lib.rs:492-500), but `end_interaction` always closes the current one (lib.rs:504-520). `importAndPlace` opens and closes its own interaction without going through `isDragging`, so if it runs during a drag, its `endInteraction` closes the user's gesture early. `beginDrag` does not check `isAddingMedia` either. — Refuse or queue `addFromPhotos`/`addFiles` while `isDragging`, and make `beginDrag` refuse while `isAddingMedia`.

7. `FilmCraft/Core/EditorModel+Media.swift:56-58` (inside `relinkOfflineMedia`, L24-60) — [undo, data] Relink on open runs the engine's `media.relink` through `relink_missing` (journaled, `lib.rs:560-575` then `touch`), and then registers an undo step. The document opens dirty, Undo offers a relink, and autosave fires on every open of a project with offline media. — Keep relink out of the undo history: run it without journaling, or clear this UndoManager's actions after `bootstrap` and do not register.

8. `FilmCraft/Core/FilmCraftDocument.swift:13, 23, 29, 42` — [concurrency, verify] The class is `@MainActor`, but `init(configuration:)` and `snapshot(contentType:)` implement synchronous `ReferenceFileDocument` requirements, which are nonisolated. Swift 6 can reject a main-actor-isolated member that satisfies a nonisolated requirement. Only `readableContentTypes`, `writableContentTypes` and `fileWrapper` are marked `nonisolated`. — Decide the isolation explicitly: either `extension FilmCraftDocument: @MainActor ReferenceFileDocument` (isolated conformance, if the toolchain supports it), or mark the requirements `nonisolated` and hop for the model work. In `snapshot`, read `projectJson()` on the main actor and return the `Data`.

9. `FilmCraft/Core/EditorModel+Playback.swift:78-80`, `FilmCraft/Core/EditorModel+Media.swift:135-138`, `FilmCraft/Media/PlaybackEngine.swift:256-258`, `FilmCraft/Core/EditorModel+Export.swift:15-16` — [concurrency] `ProjectHandle` (a non-Sendable class from another module) is captured by `Task.detached` and passed into `ExportService`. The code depends on `@preconcurrency import` to hide this, which is not a guarantee in Swift 6 mode. — Add `extension ProjectHandle: @unchecked Sendable {}` in Core if the generated bindings do not already declare it (the Rust side is `Mutex`-guarded).

10. `FilmCraft/Media/ExportService.swift:102-112` — [main thread, data] The `.files` save runs synchronous `copyItem`/`moveItem` of a potentially multi-GB file on the main actor (`ExportService` is `@MainActor`), which freezes the UI. It also removes the destination (L106) before the copy succeeds, so a failed copy loses the user's existing file. — Do the file operations in a detached task; copy to a temporary name beside the destination and replace only on success.

11. `FilmCraft/Core/EditorModel+Media.swift:110-116` — [data] `copyIntoDocumentsMedia` treats an existing file with the same name and byte size as the same media and returns it without comparing content, so a different clip with the same size is silently linked. — Compare contents (for example SHA-256 of both), or always choose a fresh name.

12. `FilmCraft/Core/AppEnvironment.swift:41-46` — [data] `-FilmCraftResetState` is not gated by `#if DEBUG` and deletes `Documents/Media`, which holds the only copies of Files-app media (CONTRACT §2: user-visible in Files). — Gate the reset with `#if DEBUG`, and clear only the cache, not `Documents/Media`.

13. `FilmCraft/Core/EditorModel+Playback.swift:84-90` — [demo] `isDemoReady` is set only when a frame render succeeds. If the first render fails, the demo never reports ready and `demoReady`-waiting UI tests hang. — In demo mode, set `isDemoReady` after the first completed render attempt, whatever its outcome.

14. `apple/bridge/ui-commands.txt` (the file has only its header comment; no ids) — [gate] `scripts/check-command-ids.sh` (L31-45) requires every literal id the Swift sources use to be listed here, so the gate fails for `edit.undo`, `timeline.select`, `file.import`, `playback.toggle`, `help.*`, `window.workspace.*`, and the rest. — Populate the file with the ids the Swift sources reference literally in `run`, `present`, `runUI`, `isEnabled`, `"command.<id>"`.

15. `FilmCraft/Core/EditorModel.swift:228-230` — [semantics, verify] `selectClip(_:extend:)` sends `toggle: extend`, so shift-click toggles (deselects an already-selected clip) rather than extending the selection. The engine's `timeline.select` doc also offers `add`. Selection is journaled (`cmd!` sets `journal: true`, `crates/engine/src/commands.rs:40`), so confirm that selection does not bump `history_id`: the signature covers the undo and redo stacks only, so it should not. — Use `add` for extend, unless the desktop convention is toggle.

16. `FilmCraft/Media/PlaybackEngine.swift:99-120, 172-176` — [lifecycle] The `CADisplayLink` is retained by the main run loop. If the `EditorModel` deallocates while playing, the proxy's weak `engine` becomes nil, but the link keeps firing and the audio engine keeps running. `PlaybackEngine` has no teardown path. — In `tick()`, invalidate the link and stop audio when `model == nil`, or add an explicit close from the scene's teardown.

17. `FilmCraft/Media/ExportService.swift:61-66` — [error handling] Cancellation is inferred from `error.lowercased().contains("cancel")`. Any engine error that mentions "cancel" is reported as a cancellation, and the real failure is hidden. — Have the bridge report cancellation explicitly in `JobStatus`, and use `Task.isCancelled` as the cancel signal in the app.

18. `FilmCraft/Media/PhotosLibrary.swift:162-165` — [PhotoKit] Grid thumbnails set `isNetworkAccessAllowed = true`, so scrolling the browser downloads iCloud originals for every visible cell. — Use `false` for thumbnails; keep `true` only in `write` (L245), which materializes on demand.

19. `FilmCraft/Media/PhotosLibrary.swift:206-227, 230-239` — [PhotoKit] `existingCacheFile` reuses any non-empty `PH-` file without checking the asset's `modificationDate`, so an asset edited in Photos keeps its old original in the engine. — Compare `asset.modificationDate` against the cached file's modification date (or put a version in the file name), and re-materialize when Photos is newer.

20. `FilmCraft/Media/PhotosLibrary.swift:241-253` — [cleanup] When `writeData` fails, the `.partial` file stays in `Library/Caches`. Nothing removes it. — Remove the partial file on the error path (`defer` or `catch`).

21. `FilmCraft/Media/PlaybackEngine.swift:147-151, 164-170` — [audio] Each scrub during playback runs `teardown()` and `begin()`, which creates a new `AVAudioEngine`, re-activates the session and allocates a new ring. This causes audible gaps and churn. — Keep the engine and ring; reset the ring and move `startTick` and the fill task only.

22. `FilmCraft/Media/PlaybackEngine.swift:179-195, 251-255` — [audio] `teardown()` never deactivates the `AVAudioSession` (`setActive(false, options: .notifyOthersOnDeactivation)`), so other audio stays ducked. The interruption observer handles only `.began` (via `stop()`) and never handles `.ended`. — Deactivate on stop; handle `.ended` if playback should resume.

23. `FilmCraft/Media/PlaybackEngine.swift:199-223` — [perf] `tick()` runs at the display rate. Each call runs `setPlayhead` (which calls `touch()`, bumps `revision` and flushes `enabledCache`), `refreshLight()`, and `requestFrame`, and each `@Observable` assignment invalidates every view that reads `state`. — Assign `state` only when the frame changes, or throttle the UI refresh to the frame rate.

24. `FilmCraft/Core/EditorModel+Commands.swift:132` — [fragile] The workspace-to-panel mapping matches a word as a substring of every panel id. "audio" can match several panels, and the first match wins arbitrarily. — Map each workspace to an exact `PanelInfo.id`, resolved once from `catalog.panels`.

25. `FilmCraft/Core/EditorModel+Undo.swift:29-35` — [undo] `UndoManager.groupsByEvent` defaults to true on the main thread, so registrations made in one run-loop event collapse into one Cmd-Z group, and one undo steps back two engine steps at once. — Set `manager.groupsByEvent = false` on the scene's manager, or open a separate undo group for each registration.

26. `FilmCraft/Core/EditorModel+Undo.swift:10-17, 56-67` — [undo] The fallback path steps the engine without registering when `manager.canUndo` is false, while the UndoManager may still hold entries for other steps. The two stacks can diverge, so a later `manager.undo()` can run a handler whose engine step is already gone. — After a fallback step, reconcile the manager (clear its actions and re-register the remaining engine history), or make the manager the only undo path.

27. `FilmCraft/Core/EditorModel.swift:89` — [state] `inspectorVisible` is read from `UserDefaults` in `init` but never written back (no `didSet`), so the preference never persists. — Add a `didSet` that stores the value.

28. `FilmCraft/App/FilmCraftApp.swift:48` — [state, perf] `@State private var document = FilmCraftDocument()` creates a new `ProjectHandle.demo()` each time `DemoWindow` is constructed, not once. — Build the document once (for example in a holder created by `DemoApp`), not in a `@State` initializer.

29. `FilmCraft/Core/EditorModel+Playback.swift:54-64` — [never-crash, defensive] `renderBox` does not reject an infinite `viewerSize`. Infinity passes the `>= 16` check, the scale becomes 0, and `inf * 0` is NaN. The code survives only because `max(16, NaN)` returns 16. — Guard with `isFinite` and clamp explicitly.

30. `FilmCraft/Core/EditorModel+Media.swift:145-146` — [engine] Placement calls `handle.execute` directly, bypassing `EditorModel.execute`, so the error does not go through `lastError`/logging and the refresh path. A failure after the import leaves the media imported but not placed, and that partial state is undocumented. — Route placement through the same error path, and decide and document the partial-failure result.

31. `FilmCraft/Media/PhotosLibrary.swift:108-116` — [perf] `reload()` refetches all assets and albums on the main actor for every library change. `PHChange` is ignored. — Use `PHChange.changeDetails` for incremental updates, or at least debounce.

32. `FilmCraft/Core/EditorModel+Media.swift:24-54` — [PhotoKit, UX] A document opened with offline `PH-` media calls `photos.requestAccess()` automatically, so the Photos permission prompt appears on open without any user action in the editor. — Relink from Photos on user request (or show a relink affordance). Keep the cache-based relink automatic.

33. `FilmCraft/Core/EditorModel+Undo.swift:31-33, 41-43, 50-52` — [never-crash, low] `MainActor.assumeIsolated` traps if an UndoManager handler ever runs off the main thread. This is safe today because UI undo is on the main thread, but it is a crash path under the never-crash rule. — Keep the handlers main-actor-only and add a debug assertion, or route through a checked path.

34. `FilmCraft/Media/ExportService.swift:77-81` — [concurrency] `pause()` bridges `DispatchQueue.main.asyncAfter` into the `@MainActor` poll loop. Use `try? await Task.sleep(for:)` so cancellation and isolation stay structured.

35. `FilmCraft/Media/PlaybackEngine.swift:264-270` — [realtime, verify] The render block captures `ring`, so `AudioRing`'s storage is freed by whichever thread drops the last reference. If the source node outlives `teardown()`, `deinit` (which deallocates) could run on the audio thread. — Keep the ring owned by `PlaybackEngine` until the audio engine is released on the main thread, and free it there.

36. `FilmCraft/Core/EditorModel+Playback.swift:131-144` — [caching] The thumbnail cache key includes `mediaVersion`, which is bumped on every undo and every import, so every undo flushes all thumbnails. — Key on the media's own revision, or bump only when media on disk changes.

37. `FilmCraft/Core/EditorModel+Media.swift:65-79` — [errors] `addFromPhotos` overwrites `lastError` per failed item, so only the last failure is shown when several fail. — Collect the failure messages and show them together.

38. `FilmCraft/App/FilmCraftApp.swift:27-33` — [verify] `DocumentLaunchGeometry.titleViewFrame` and the `overlayAccessoryView` closure signature were not checked against the iOS 26 SDK. — Confirm both when the project builds.

Checked and not found in scope: force unwraps, `try!`, `as!`, `fatalError`, `precondition`, and unchecked subscripts (`FilmCraft/Core`, `FilmCraft/Media`, `FilmCraft/App`). Engine command ids used as literals all exist: `edit.undo`, `edit.redo`, `file.import`, `file.exportMedia`, `timeline.select`, `timeline.place` (engine `crates/engine/src/commands.rs`), and the UI ids (`playback.*`, `view.*`, `mode.*`, `help.*`, `window.workspace.*`, `tool.*`) in `crates/ui-egui/src/menus.rs` and `links.rs`. The params keys used (`timeline.select`: `clips`, `toggle`; `timeline.place`: `items`, `time`, `insert`) match the engine docs. Bridge calls and labels in Core/Media/App match CONTRACT §3 and the Rust signatures, except the `BridgeError` case in item 4. Demo launch (`-FilmCraftDemo` to `DemoApp` to `EditorScene.task` to `bootstrap`) opens the editor without the document browser and sets `isDemoReady`, subject to item 13.
