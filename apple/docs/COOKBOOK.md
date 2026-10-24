# Cookbook: native iPad/iPhone app for a {Function}Craft Rust app

For LLM agents. Replace `<App>`/`<app>` with the target (VectorCraft/vectorcraft, LightCraft/lightcraft, …). Execute in
order; each phase ends green before the next. Revision 2: adds what the LightCraft port taught (data model by category,
contract-first parallel agents, hollow-green traps, iPad-then-iPhone testing). Revision 3: opus/sonnet/haiku roles,
parallel apps, `main` + `[skip ci]` pushes, upstream sync script, live simulator testing and the haiku feature pass.

## 0. Rules
- Fork code only in `apple/` (+ CI workflow, `FORK.md`). Never edit upstream files. Upstream stays mergeable (remote
  `upstream`, merge, never rebase). Fork is `<app>-ios` on the user's GitHub; its `main` is our main branch.
  `FORK.md` documents the remotes, the "only `apple/` is ours" rule and the sync command
  (`apple/scripts/sync-upstream.sh`); copy this cookbook to `apple/docs/COOKBOOK.md` and refresh the copy from the
  workspace master on every commit. Instructions the user gives for all forks go into the master cookbook.
- Rust engine untouched; Swift only in `apple/`. No Tauri/webview. If the engine lacks something, work around it in the
  bridge or Swift and note it for upstream.
- Every UI action = an engine command by id. Menus, palette and parameter forms are generated from the engine catalog;
  hand-write only when the generic one is not good enough.
- Commit and push regularly: after every meaningful chunk (an agent's finished work, a build attempt, before going
  idle), marking unbuilt work "WIP". Commit to `main`, push to `origin` with `[skip ci]` in every message (no CI/CD runs; any workflow
  is `workflow_dispatch` only), using the git protocol the user's GitHub auth is set up for. Never commit build output
  (`apple/.gitignore`: `target/`, derived data, `.xcresult`, xcframeworks, generated `.xcodeproj`).
- Work unattended: if a tool needs a permission click (e.g. a simulator panel), switch to a route that doesn't
  (`simctl`, XCUITest) instead of waiting.
- Models: opus orchestrates each app (one session per app; several apps run in parallel); sonnet for all code; haiku
  for review/search swarms, simulator driving and feature test passes. Give each subagent a self-contained brief,
  the files it owns, the files it must not touch, its own `-derivedDataPath` and its own simulators (named with the
  app prefix, e.g. `<App>-iPad`). Parallel apps share the disk: budget ~10 GB each and check `df` before heavy builds.
- Parallel apps share the CPU: never let every app compile at once (8 cores, load ~650 = all stall). The orchestrator
  runs `buildsched.sh`, which pauses (SIGSTOP, never kills) lower-priority apps' compilers and resumes them on spare
  cores; priority in `.build.priority`, closest-to-testing first. App sessions run heavy builds in the background,
  never kill a paused (`T`) build, and do non-compile work while paused.
- Token-heavy work first: CPU is the bottleneck, agents are not. Front-load writing, review swarms, test authoring
  and docs in parallel; batch compiles so each build validates as much new code as possible.
- Low-token mode (when the user asks, e.g. near a usage limit): Opus orchestrates in short turns and delegates the
  work to Sonnet (code fixes) and Haiku (search, tests); compile and build tasks come first; record errors and batch
  fixes, don't poll, don't re-read large logs (grep the error lines).

## 0b. Product shape (decide before writing UI; ask the user when the category leaves it open)
- **Data model follows the category, not the template.** A document app (image, vector, layout, PDF) uses
  `DocumentGroup`. A library app (photos, media, catalog) uses the platform's own library as the user's library (Photos
  via PhotoKit, Music, Files…): open and edit items in place, keep the engine's catalog as an internal cache keyed by the
  platform's ids, and write results back through the platform's non-destructive editing API with the engine's settings
  as re-editable adjustment data. Never make the user "import" what the platform already holds.
- When the user's wording is ambiguous ("use the internal library"), ask once with concrete options; then re-brief
  every running agent on the decision immediately.
- Follow Apple's HIG for iPad and iPhone as closely as possible: system components, materials (Liquid Glass),
  navigation, gestures, keyboard and pointer, Pencil, Dynamic Type, accessibility, dark and light. Deviate only where
  the category demands it, and say why in a code comment.
- Hyper-productive, Apple-clean. Pro speed with system looks, by progressive disclosure, not clutter:
  - Speed: every frequent action ≤ 1 tap from the canvas; every desktop shortcut works with a hardware keyboard
    (same keys, listed in the menu bar / ⌘-hold overlay); ⌘K command palette over the whole catalog; long-press /
    right-click context menus on canvas objects, layers and list rows; drag and drop in and out (files, images,
    layers, reorder); multi-touch shortcuts (two-finger tap undo, three-finger tap redo, pinch/rotate canvas);
    Pencil double-tap/squeeze and hover; scrubbable numeric fields with exact entry; customizable toolbar
    (`toolbar(id:)`); remember last tool, panel layout and recent values; multiple windows / Stage Manager.
  - Clean: system components, SF Symbols, materials and semantic colours; one primary action visible per area,
    the rest in menus, panel headers or the palette; density adapts to the window (§4) instead of shrinking text;
    no custom chrome, no decorative colour, no modal where a popover or inline edit works.
  - Measure it: the feature pass reports taps-to-do for the top 10 workflows of the category; regressions are bugs.
- Stay faithful to the desktop app's mental model: same tools, panels, names and menu structure, adapted to touch.
- Pick a reference app (most popular, best-reviewed iPad/iPhone app in the category; verify by current App Store
  rankings), clean-room: behaviour and look only, never assets or code.

  | App | Reference |
  |---|---|
  | photo editor | Pixelmator Pro, Affinity Photo |
  | vector | Affinity Designer, Linearity Curve |
  | painting | Procreate |
  | video | LumaFusion, Final Cut Pro for iPad |
  | photo development / library | Lightroom (and Photos' own editor for library integration) |
  | PDF | PDF Expert |
  | layout/design | Affinity Publisher, Canva |
- Write the reference and 5–10 conventions taken from it in `apple/README.md` before building the UI. Review
  screenshots against it.
- Use the engine's existing interchange features for the ecosystem users come from (e.g. importing the reference
  app's presets, profiles, sidecars): the engine usually already parses them; iOS only needs the picking and the
  summary UI.

## 1. Contract first (`apple/docs/CONTRACT.md`)
- Before any code, write the contract: directory ownership, data model (§0b), bridge API with the exact Swift names
  UniFFI will generate, the Swift core surface the UI consumes (model members, entry views, sheets), and the
  accessibility identifier scheme. Then run bridge, core and UI agents in parallel against it.
- Any change goes to the contract first, then to the agents that depend on it (message running agents; don't wait).
- Survey before designing: what the engine's session/catalog/document object is, how it renders (and whether render
  jobs can run outside the lock), what it seeds on create vs. open, which commands are UI-only and where they are
  declared, and which menu layout the desktop uses.

## 2. Bridge (`apple/bridge`, own `[workspace]`)
- UniFFI crate `<app>-apple`, staticlib, path deps on upstream crates. Expose: the engine's state object
  (open/execute(commandId, paramsJson)/disabledReason/undo/redo/interaction begin-end/state/render/thumbnail/export),
  `commandCatalog()`, `commandParams(id)` (parse the upstream params doc into typed fields), platform support per
  command, and any data tables the UI generates from (e.g. slider specs).
- **UI-only desktop commands and the menu layout usually live in the desktop UI crate.** Don't depend on it (heavy GUI
  deps); parse its source tables at runtime from `include_str!`, with a small, unit-tested parser that never panics.
- Render APIs need the variants the UI overlays need (e.g. before/after, draft, full frame without crop).
- Every export runs under `catch_unwind`; poisoned locks recovered; state carries a revision and a history id.
- Files: `ui-commands.txt` (every id Swift uses), `ios-excluded-commands.txt` (id + reason; be conservative).
- Cross-compile the engine for the simulator target first thing (background); it validates the whole plan.
- Gate: `cargo test && cargo clippy --all-targets -- -D warnings`, plus the simulator-target build.

## 3. Scripts (`apple/scripts`)
- `build-xcframework.sh [--sim-only] [--debug]`: cargo build per iOS target, uniffi-bindgen Swift,
  `xcodebuild -create-xcframework`, into a `<App>Kit` Swift package.
- The Swift package declares the system frameworks the static engine library needs (`linkerSettings`): a Rust GPU or
  imaging stack pulls Metal, QuartzCore, CoreGraphics etc., and undefined symbols at link time mean one is missing.
- `check-command-ids.sh` (also flags literal ids in Swift missing from `ui-commands.txt`; widget ids must not look
  like command ids), `tool-coverage.sh` (every desktop tool/panel mapped in `docs/tool-map.toml`),
  `feature-coverage.sh --check` (generated `docs/FEATURE_COVERAGE.md`).
- `sync-upstream.sh`: fetch `upstream`, `git merge upstream/main` (never rebase), then run the bridge gate.
- Run all of them plus the bridge gate before every commit.

## 4. App (`apple/<App>`, XcodeGen `project.yml`, iOS 26+, Swift 6)
- Scene per §0b: `DocumentGroup` + `ReferenceFileDocument` (engine history on the scene `UndoManager`, autosave via
  `snapshot`) for document apps; a `WindowGroup` over the platform library for library apps (engine history still on
  the window's `UndoManager`; write-back on leaving the editor).
- Per-idiom UI: iPad sidebar/palette + options + inspector; iPhone bottom tool strip + sheets with detents that keep
  the content visible above them. Liquid Glass system styles, no custom chrome.
- Size the layout for the smallest window, not the device: iPadOS windows are resizable, in either orientation, Split
  View, Stage Manager. Order the degradation: full layout → denser (smaller controls, icons only, merged groups) →
  collapse into a menu or sheet → scroll as the last resort. Never let a control silently fall off screen. Labels in
  chips and buttons never wrap mid-word (`lineLimit(1)`, `ViewThatFits` falling back to icons).
- Full-screen canvas mode in every app (iPad and iPhone): a toolbar button and View-menu command (⌃⌘F) hide every
  panel, sidebar, inspector, tool strip and toolbar plus the status bar/home indicator, leaving only the canvas
  (viewer for video, loupe for photos) with its gestures. One small floating Liquid Glass button (corner, safe area)
  returns to the standard layout; Esc also exits. Ids `control.fullscreen` / `control.fullscreen.exit`.
- Show controls under the same conditions as the desktop (mode-dependent sections, e.g. HDR-only or B&W-only sliders);
  read the desktop panel code for the rule.
- Every interactive element has a stable accessibility identifier derived from its model id (`tool.<id>`,
  `panel.<id>`, `command.<id>`, `control.<id>`), on every surface that shows it.
- iPad menu bar = merge, not replace: keep the iPadOS system groups (app, File basics, Edit undo/clipboard, Format,
  View, Window, Help) and insert the desktop's menus and items in the desktop order, generated from the desktop
  layout, into the matching system groups or as their own top-level menus; Window and Help last. A bare iPadOS
  default menu bar is a regression. Single-key tool shortcuts = zero-size hidden buttons on the editor view.
- Panels work like the desktop (Photoshop-style): every desktop panel (adjustments, curves, levels, histogram,
  properties, layers…) exists and opens from the right-side panel menu and the Window menu; panels can be added,
  hidden, collapsed and stacked/reordered in the inspector column, and the arrangement persists per app. A panel
  entry that opens nothing is a bug: tours must open and act on every panel. iPhone shows them as sheets.
- Panel-owned actions live in their panel's header, as on the desktop (e.g. "add adjustment layer", new layer,
  mask, delete in the Layers panel), not in the global toolbar.
- Launch: for `DocumentGroup`, `DocumentGroupLaunchScene` with system background and the app icon in an overlay laid out
  from `titleViewFrame`; for a library app, open straight onto the library.
- Platform permissions (Photos read/write, add-only) have usage strings; denied and limited states have their own UI.
- App icon: always the original app's own icon — upstream SVG rendered full-bleed, opaque, 1024 px (remove the rounded
  clip). Copy the license, note it.
- Standard native look in dark and light: system backgrounds, materials, semantic colors (`.primary`, `.secondary`,
  accent) and stock controls. No custom colors or tinted chrome on the main/launch/library screens without a reason
  in a code comment; the canvas or media itself is the only exception.
- Demo launch arg (`-<App>Demo`) seeds content through engine commands for screenshots and tests. Check *when* the
  engine seeds (often only on create, not on open) and make the demo path hit that case. In a library app, demo mode
  falls back to engine sample content when the platform library is empty or denied.

## 5. Toolchain (macOS)
- Rust in `~/.cargo/bin` (often not on PATH). Xcode via `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Simulator runtime: `xcodebuild -downloadPlatform iOS`; reject device-locked runtimes; `simctl create` devices.
- Disk: check `df` first. One Rust target dir (≈ 5–11 GB); delete `target/debug` after host gates; one derived-data dir
  per agent (≈ 3 GB); delete `.xcresult` bundles once read.
- No local Xcode: push and read macOS CI errors, after checking the Actions budget.

## 6. Compile loop
1. `build-xcframework.sh --sim-only --debug`; `cd apple && xcodegen generate`.
2. `xcodebuild build-for-testing -scheme <App> -destination 'generic/platform=iOS Simulator' ARCHS=arm64
   CODE_SIGNING_ALLOWED=NO -derivedDataPath build/dd`.
3. Fix every error; grep the whole tree for the same pattern. If the bindings can be generated before the Swift is
   written, the compiler is the reviewer; otherwise have three haiku reviewers sweep thirds of the sources first.
- Known Swift 6 / iOS traps: macOS-only APIs (`openDocument`, `newDocument`, `onPasteCommand`); a
  `CommandsBuilder`/`ToolbarContentBuilder` takes ≤ 10 items and `ForEach` is not `Commands`; free functions touching
  `@MainActor` models need `@MainActor` (and only once); literal arrays inferring `[Any]`; ambiguous `.infinity`;
  main-actor statics from `nonisolated` code; a `var` captured by `Task`; `NSMutableData` → `as CFMutableData`;
  missing `return`; `@MainActor` XCTestCase overriding `setUpWithError`; non-Sendable `CGImage`/framework objects
  crossing actors (pass `Data` or ids); calls to helpers that don't exist; generated UniFFI labels differing from
  what the Swift assumed.
- Validate SF Symbol names against the runtime's `CoreGlyphs.bundle/name_availability.plist` (find it under the
  simulator runtime's mounted root).

## 7. Tests — iPad first, iPhone second
- Order: every suite runs on an **iPad simulator first**; fix what it finds; then the **iPhone simulator**. Within
  each device: portrait, then landscape (iPad), then the narrowest window you can produce.
- Unit: bridge smoke tests (swift-testing): catalogs load, a command changes state, undo/redo moves the history id,
  render returns w×h×4 bytes, persistence round-trips.
- UI test: launch with the demo arg in dark and light, reach the library, wait for a `demoReady` marker, open an item,
  act on it, open panels, attach screenshots. A missing element goes into a `-notes` attachment, not a failure.
- **Read the notes and look at the screenshots — a green run can be hollow** (an empty demo library, a panel that
  never opened, an alert covering everything). Reset state the app persists between runs (UserDefaults, caches,
  the platform library) so runs don't depend on the previous one.
- Coverage tours, one per user-facing catalog (tools, panels, menu/palette commands): visit every item through the real
  UI, act on it, screenshot it, fail only on a crash. Generate the list from the source of truth; keep the state valid
  between items (undo, reselect). Write a summary attachment with every item's outcome.
- Treat "not reached" as a bug in the app or the test, never a pass. Classify each cause, fix the root: off screen →
  layout; behind a gesture or scroll → missing identifier or a denser layout; refused by the engine → wrong test state
  or a real bug. Record full alert messages.
- Platform integration tests seed the simulator: `simctl addmedia` for photos, `simctl privacy … grant|revoke photos`
  for permission states (test denied and limited too), files placed in the app container for file imports. Verify the
  write-back through the platform API, not just the UI.
- Run: `xcodebuild test-without-building -destination id=<sim> -resultBundlePath x.xcresult`; export attachments with
  `xcresulttool export attachments` (`manifest.json` maps names to files). Downscale screenshots before reading them.
- "Unable to Import Document (DocumentManager error 1)" = stale simulator state: `simctl erase` and rerun (re-seed).
- One booted simulator on the machine at a time, across parallel app sessions: take the shared lock
  (`mkdir <workspace>/.sim.lock`) before booting, shut down and release after each run; never hold it across a build.
  Builds use `generic/platform=iOS Simulator` and never boot a device. If the Mac lags, `simctl shutdown all`.
- Parallel apps share one iPad and one iPhone simulator; don't `simctl create` per-app devices. After every run,
  `simctl uninstall` the app and its UITests runner, so no compiled app stays installed when not needed.
- Close Simulator.app while tests run; drive and inspect with XCUITest and `simctl io screenshot`, not by hand.
- With parallel apps, iPad tests run in the orchestrator session, one app at a time, haiku driving the simulator.
  App sessions send `READY-IPAD-SMOKE <app>` at each runnable build (short check, ~10 min: launch with demo, open
  an item, a few core actions, main panels, no crash) and `READY-IPAD-FULL <app>` only once stable and complete (full
  suites, tours, feature pass); results go back as a defects list. iPhone tests stay in the app session.
- Test live: attach the built-in iOS Simulator panel to each booted device and tell the orchestrator which one. When the user asks for no
  screenshots, verify through the accessibility tree, XCUITest assertions, notes and logs instead.
- Once stable, a haiku feature pass over all features: one agent per feature area (every tool, panel, command and
  document/library flow) drives the built-in simulator (iPad, then iPhone) and reports defects with evidence; sonnet
  fixes; rerun until clean. The final report has a per-feature pass/fail table.

## 8. Device
- Build the full xcframework (release, no `--sim-only`), set `DEVELOPMENT_TEAM`. With a free team, drop the iCloud
  entitlement and make the bundle ID unique. On the iPad: Developer Mode on.
- Quick device install: build only the `aarch64-apple-ios` release slice (skip the simulator slices). Keep signing
  out of tracked files: a copy of `project.yml` outside the repo (team set, `CODE_SIGN_ENTITLEMENTS` removed, bundle
  ids `ca.hologram.<user>.<app>`, extensions keep the app prefix) → `xcodegen generate --spec <copy> --project apple
  --project-root apple` → `xcodebuild … -destination id=<device> -allowProvisioningUpdates
  -allowProvisioningDeviceRegistration DEVELOPMENT_TEAM=<team>` → `devicectl device install app` + `process launch`.
  Pass the team on the command line, never commit it. Personal Team apps expire after 7 days; reinstall.
  "No Accounts" from an agent's xcodebuild = the sandboxed shell can't read the Apple ID token in the login keychain;
  signing builds need the shell sandbox off (a permission the user approves). The Apple ID must be signed in to
  Xcode → Settings → Accounts (quit Xcode with ⌘Q so it saves). Developer Mode on (Settings → Privacy & Security).
  Keep the device build dirs and a reinstall script so the 7-day re-sign is one command.
- Install on a device only an app that passed its latest simulator smoke test ("if functional").
- A device build is CPU work: give it a slot in `.build.priority` like any other build.
