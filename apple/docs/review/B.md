# Review B: FilmCraft/UI/Panels and FilmCraft/UI/Commands (read-only)

Scope: `FilmCraft/UI/Panels/*.swift`, `FilmCraft/UI/Commands/*.swift`. Checked against the Core/Media API, the engine
command params docs (`crates/engine/src/commands.rs`), CONTRACT §3 to §5 (no generated bindings exist yet, so §3 was
used), CoreGlyphs `name_availability.plist` (host copy under `/System/Library/PrivateFrameworks/SFSymbols.framework`),
and COOKBOOK §6. EffectControlsPanel.swift and EffectCatalog.swift were read last, in their on-disk state at review time.

- Engine ids used in scope (effects.*, sequence.apply*Transition, timeline.place, timeline.setTrack, edit.undo/redo) all
  exist, and their param keys match the params docs.
- Every SF Symbol name in scope exists in the plist.
- No force unwraps, `try!`, `as!`, or `fatalError` in scope.

## Findings (most severe first)

1. `FilmCraft/UI/Commands/CommandForm.swift:87` — `Int(...clamped(to:))` traps when the value is NaN (`clamped` returns NaN for NaN input). NaN can arrive from the number field (`CommandFieldRow.swift:102`, `TextField(value:format:.number)`). Breaks the never-crash rule. — Reject non-finite values in `numberBinding`'s setter (`CommandFieldRow.swift:87`) and guard `isFinite` before `Int(...)` in `params()`, falling back to 0 or the default.

2. `FilmCraft/UI/Panels/EffectControlsPanel.swift:62` — `Task.detached` captures `handle` (`ProjectHandle`, a UniFFI object) in a `@Sendable` closure. Under Swift 6 strict concurrency this is a compile error if the generated class is not `Sendable`. Bindings are not generated yet, so this is unverified. — Once bindings exist, check the conformance. If it is not Sendable, wrap it the way `PhotosLibrary.swift:8` does (`Unchecked<T>`), or capture the project JSON on the main actor and pass only `String`.

3. `FilmCraft/UI/Panels/EffectControlsPanel.swift:79` (decl), `:90` (return), signature `:78` — `var out: [(FXParamInfo, FXParamValue)]` is returned as `[(info:, value:)]`. Array conversion between unlabelled and labelled tuple element types is likely rejected. — Declare `var out: [(info: FXParamInfo, value: FXParamValue)]` and append labelled tuples.

4. `FilmCraft/UI/Panels/EffectControlsPanel.swift:277` — `FloatControl` commits only `if dragging`. Changes that arrive without an editing phase (VoiceOver increment/decrement, Switch Control, hardware keyboard) are dropped, so accessibility users cannot change the value. — Always commit. Call `beginDrag` and `endDrag` only around the `onEditingChanged` phases, and let a non-drag change be its own undo step.

5. `FilmCraft/UI/Commands/CommandForm.swift:42` — a numeric default for a `choice` field is matched against names and falls back to `choices.first`. The engine accepts an index here, so the default is mapped to the wrong option. Non-optional choice fields are always sent (`:48`), so the wrong value is sent. — Resolve numeric defaults by index: `if let i = Int(wanted), f.choices.indices.contains(i) { texts[f.key] = f.choices[i] }`.

6. `FilmCraft/UI/Commands/CommandForm.swift:106-107` and `CommandFieldRow.swift:76-80` — `time` kind fields are sent as a free-typed String under their own key. The engine reads `time` only as an integer (`crates/engine/src/commands.rs:243`), so a typed string is ignored silently and the playhead is used. — Send the string under `timecode` (the engine parses it), or parse to ticks or `seconds`. Verify how the bridge's `ParamField` kind `"time"` names its key.

7. `FilmCraft/UI/Panels/EffectControlsPanel.swift:355-364` — `ColorPicker` commits `effects.setParam` on every change with no `beginDrag` and `endDrag`. A single drag in the picker creates one undo step per tick. — Group a picker interaction into one interaction (begin on the first change, end on dismiss or after a pause), as `FloatControl` does.

8. `FilmCraft/UI/Panels/EffectControlsPanel.swift:59-62` — every revision change (each engine call, including each slider frame) re-serializes the whole project (`projectJson()`) and parses it in `FXInspect.load`. The cost grows with project size during drags. — Cache the parsed clip per revision, or add an engine query that returns one clip's effects.

9. `FilmCraft/UI/Panels/EffectControlsPanel.swift:135`, `:146`, `:171`, `:181`, `:343` — widget ids are keyed by `effectID` (`fx.<effectID>`, `fx.<effectID>.<param>`, `fxAnimate.…`, `fxResetParam.…`, `"\(id).\(suffix)"`). Two instances of the same effect on one clip produce duplicate accessibility identifiers. These are dotted `x.y` forms, which CONTRACT §5 forbids for widgets. — Key by `effect.index` and use a non-dotted form (e.g. `fx_<index>_<param>`), or add the scheme to CONTRACT §5.

10. `FilmCraft/UI/Panels/EffectControlsPanel.swift:114`, `:121`, `:129` — `fxToggle.<index>`, `fxReset.<index>`, `fxRemove.<index>` are dotted `x.y` widget ids (CONTRACT §5 rule). — Rename to a non-dotted form, e.g. `fxToggle_<index>`.

11. `FilmCraft/UI/Panels/AudioMixerPanel.swift:30` — the row id `track.<id>.mixer` departs from CONTRACT §5 `track.<id>`. It shares the namespace with timeline track ids and could collide with them. — Rename to `mixerTrack_<id>`, or update CONTRACT §5 and the timeline to match.

12. `FilmCraft/UI/Panels/AudioMixerPanel.swift:19`, `:22`, `:25` — the Mute, Solo and Lock buttons use the same labels ("Mute", "Solo", "Lock") for every track, so VoiceOver cannot tell tracks apart. The ids `trackMute_<id>` etc. are not in the contract. — Include the track name in the label. `toggle(...)` takes `LocalizedStringKey`, so change it to `String`.

13. `FilmCraft/UI/Panels/MediaBrowserView.swift:51` — the iPad inline media panel is identified `mediaPanel`, but CONTRACT §5 names this surface `mediaBrowser`. UI tests that drive `mediaBrowser` will fail on iPad. — Use `mediaBrowser` for both cases, or amend CONTRACT §5.

14. `FilmCraft/UI/Panels/MediaBrowserView.swift:80` — `import.photos` is applied to the Photos source-tab toggle. CONTRACT §5 defines `import.photos` as the Photos import action. — Give the tab a distinct id (e.g. `mediaSourcePhotos`) and keep `import.photos` for the add action, or amend CONTRACT §5.

15. `FilmCraft/UI/Panels/MediaBrowserView.swift:140` (`photos.openSettings`) and `:193` (`photos.manage`) — dotted ids that are neither commands nor listed in CONTRACT §5. `check-command-ids.sh` will flag them as command-like. — Use non-dotted ids (`photosOpenSettings`, `photosManage`), or add them to CONTRACT §5.

16. `FilmCraft/UI/Panels/MediaBrowserView.swift:205` — `album.all` departs from the contract's `album.<index>`. — Use a non-dotted id such as `albumLibrary`, or amend CONTRACT §5.

17. `FilmCraft/UI/Commands/CommandMenuContent.swift:78`, `:110` — menu ids `menu.<Title>` and `menu.<A>.<B>` are dotted and not in CONTRACT §5. — Add them to CONTRACT §5 or use a non-dotted scheme.

18. `bridge/ui-commands.txt:1` — the file holds only its header line. CONTRACT §3 requires it to list every command id the Swift sources reference literally (e.g. `effects.apply`, `effects.setParam`, `timeline.place`, `sequence.applyVideoTransition`, `edit.undo`), so `scripts/check-command-ids.sh` will fail. — Regenerate it from the Swift tree (`grep -rhoE` over quoted dotted ids, filtered to engine and UI command ids).

19. `docs/CONTRACT.md:199` and `:202` — the contract says `run` and `runUI` return `Void`. The code (`FilmCraft/Core/EditorModel.swift:139`, `EditorModel+Commands.swift:61`) returns `Bool`, and `EffectsPanel.swift:126` depends on it. — Update CONTRACT §4 to `-> Bool` (`@discardableResult`).

20. `FilmCraft/UI/Panels/EffectControlsPanel.swift:358` — `UIColor` is used but the file imports only SwiftUI and FilmCraftKit. — Add `import UIKit`.

21. `FilmCraft/UI/Panels/MediaBrowserView.swift:1-4` — `UIApplication` (`:137`), `UIImage` (`:243`, `:319`) and `UIColor` (`:253`, `:400`) are used without `import UIKit`. Compiles via SwiftUI's re-export in practice, but is fragile. — Add `import UIKit`.

22. `FilmCraft/UI/Commands/CommandSheet.swift:12` — `@State private var errorText` shadows the global `errorText(_:)` (`FilmCraft/Core/ErrorText.swift:5`). Any future `errorText(error)` call inside this struct will fail to compile. — Rename the state to `formError`.

23. `FilmCraft/UI/Commands/CommandPaletteView.swift:105` — a fixed 450 ms sleep before invoking the command, to wait for the palette dismissal. It is racy on slow devices and makes UI tests timing-dependent. — Invoke the pending command from the sheet's `onDismiss` (`EditorRootView.swift`) instead of sleeping.

24. `FilmCraft/UI/Panels/MediaBrowserView.swift:147` — `.task { await photos.requestAccess() }` on the spinner runs every time the view appears, which can start overlapping system authorization prompts. — Guard on `authorization == .notDetermined` with an in-flight flag in `PhotosLibrary`.

25. `FilmCraft/UI/Panels/MediaBrowserView.swift:160-161`, `:171` — `previewIndex` is an index into `photos.assets`. A library change bumps `revision` and can make the open preview show a different asset. — Store the `localIdentifier` and resolve it against `photos.assets` at render time.

26. `FilmCraft/UI/Panels/MediaBrowserView.swift:260-268` — the thumbnail is a tappable `onTapGesture` on a `.contain` element with the `.isButton` trait. VoiceOver activation does not reliably reach the tap. — Make the cell a `Button` (the add "+" stays a nested Button).

27. `FilmCraft/UI/Panels/PanelHost.swift:102` — `@Binding var detent` on `PanelSheet` is never read or written; `EditorRootView.swift:88` sets the detent. Dead parameter. — Remove it.

28. `FilmCraft/UI/Panels/EffectsPanel.swift:13` — `private static let kinds: [(id: String, title: LocalizedStringKey)]` is non-Sendable static state. Possible Swift 6 strict-concurrency warning or error. — Make it a computed instance property.

29. `FilmCraft/UI/Panels/EffectsPanel.swift:102` — effect rows get `effectRow_<id>`. Each row applies the `effects.apply` command, but CONTRACT §5 expects `command.<id>` on surfaces showing a command, and the contract does not say effects are exempt. — Document the exception in CONTRACT §5, or use `command.effects.apply` with the effect id in the row value.

30. `FilmCraft/UI/Panels/EffectCatalog.swift:39` (with `:37-40`) — `EngineQuery.json` for `effects.list` runs synchronously on the main actor, and `ensureLoaded` retries on every call when the query fails. A slow first call blocks the UI. — Load off the main actor, or cache the failure.

31. `FilmCraft/UI/Commands/CommandFieldRow.swift:102-106` — number fields are not clamped to `min`/`max` when typed (Stepper and TextField are unbounded when `min`/`max` are absent). Out-of-range input reaches the engine. — Clamp in `numberBinding`'s setter when the bounds exist.

32. `FilmCraft/UI/Panels/GenericPanel.swift:58-61` — the comment says the last-resort fallback uses the "Window and Edit menus", but the code filters only `Edit`. — Fix the comment, or add `Window`.

33. `FilmCraft/UI/Panels/GenericPanel.swift:12` — the `"panel.project"` prefix entry is unreachable, because `PanelContentView` routes `panel.project` to `MediaBrowserView`. Dead code. — Remove the entry.

34. `FilmCraft/UI/Commands/CommandSheet.swift:11` — `CommandForm(commandID:)` is constructed in every `CommandSheet.init`, re-parsing the params doc each time the parent re-renders, although `@State` keeps only the first. — Build the form lazily (e.g. `.task` or an optional `@State`).

35. `FilmCraft/UI/Panels/EffectControlsPanel.swift:54` — the panel body is identified `effectControls`, while CONTRACT §5 defines panels as `panel.<id>`. The tab already uses `panel.effectControls`. — Use `panel.effectControls` on the body too, or document the exception.

## Resolution (UI agent)

1 fixed (non-finite rejected in the number binding, clamped to min/max; `safeInt`). 2 fixed (`UIUnchecked` wrapper; bindings not generated yet). 3 fixed (labelled tuples). 4 fixed (non-drag changes commit as one begin/commit/end). 5 fixed (numeric default resolved by index). 6 fixed (typed value sent as `timecode` (contains `:`/`;`) or `seconds` (plain number) under the key's prefix: `time` -> `timecode`/`seconds`, `atTime` -> `atTimecode`/`atSeconds`). 7 fixed (colour picker is one interaction, closed after 700 ms pause or on disappear).
8 not fixed: bindings file is absent; `TODO(clipEffectsJson)` left in `EffectCatalog.swift` and a shared `parseEffects` decoder extracted so the switch is small. 9, 10 fixed: ids now `fx.<index>` (section), `fx.<index>.<param>`, `fx.toggle.<i>`, `fx.reset.<i>`, `fx.remove.<i>`, `fx.animate.<i>.<param>`, `fx.resetParam.<i>.<param>`, all under the reserved `fx.` prefix and keyed by index.
11 fixed: `mixerTrack_<id>`. 12 fixed (labels include the track name; ids `mixerMute_/mixerSolo_/mixerLock_<id>`, distinct from the timeline header ids). 13 fixed (`mediaBrowser` for both). 14 rejected: `import.photos` is the Photos side of the import surface and nothing else uses it. 15 rejected: `photos.openSettings`, `photos.manage` are under the reserved `photos.` prefix. 16 rejected: `album.all` accepted by the §5 note. 17 rejected: `menu.` prefix is reserved.
18 not UI (bridge). 19 not UI (CONTRACT). 20, 21 fixed (`import UIKit`). 22 fixed (`formError`). 23 fixed (see A.16). 24 fixed (only when `.notDetermined`, in-flight flag). 25 fixed (preview keyed by `localIdentifier`). 26 fixed (thumbnail is a `Button`, "+" is a sibling). 27 fixed. 28 fixed. 29 rejected: `effectRow_<id>` is an undotted widget id; the effect id is part of the name, as one command serves many rows.
30 partly fixed (failed load retried at most 3 times; still on the main actor). 31 fixed (clamp in the binding). 32, 33 fixed. 34 rejected: `State` keeps only the first form; the re-parse per parent render is small. 35 rejected: `panel.effectControls` is the tab button; the body keeps `effectControls`.
