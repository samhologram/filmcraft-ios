# FilmCraft for iOS and iPadOS: internal contracts

Single source of truth shared by the Rust bridge, the Swift core and the Swift UI. Change it first, then the code on
both sides; tell running agents. Template: the LightCraft port (`/Users/samuelhalle/Code/LC/lightcraft-ios/apple`).
Recipe: `/Users/samuelhalle/Code/CraftApps/COOKBOOK.md`.

## 1. Directory ownership

| Path | Owner | What |
|---|---|---|
| `apple/bridge/` | Bridge agent | `filmcraft-apple` crate (own `[workspace]`, UniFFI 0.32, proc-macros only) |
| `apple/scripts/` | Bridge agent | build-xcframework, check-command-ids, tool-coverage, feature-coverage, dump-catalog |
| `apple/FilmCraftKit/` | Bridge agent | local Swift package: xcframework + generated Swift bindings (`Sources/FilmCraftKit`) |
| `apple/project.yml`, `apple/.gitignore` | Bridge agent | XcodeGen spec (`.xcodeproj` generated, gitignored) |
| `apple/FilmCraft/Core/` | Core agent | `EditorModel`, document, catalogs, settings, demo seeding, focused values |
| `apple/FilmCraft/Media/` | Core agent | PhotoKit library, media cache, playback (frames + audio), export to Photos/Files |
| `apple/FilmCraft/App/` | Core agent | `@main`, scenes, menu bar `Commands`, launch scene |
| `apple/FilmCraft/UI/` | UI agent | `Shared/`, `Pad/`, `Phone/`, `Panels/`, `Timeline/`, `Commands/` |
| `apple/FilmCraft/Resources/` | UI agent | `Assets.xcassets` (AppIcon), `Info.plist` keys via project.yml |
| `apple/FilmCraftTests/`, `apple/FilmCraftUITests/` | Test agent (later phase) | swift-testing unit tests, XCUITest suites + tours |
| `FORK.md`, `.github/workflows/apple-*.yml` | Orchestrator | fork notes, CI |

Upstream files (everything outside `apple/`, `FORK.md`, `.github/workflows/apple-*.yml`) are never edited.

## 2. Data model (decided by the user: "Both, documents first")

- **A project is a document**: `DocumentGroup` + `ReferenceFileDocument` over upstream's `.fcproj` (UTF-8 JSON
  envelope `{"format":"filmcraft.project",…}`). UTType `ca.hologram.filmcraft.project`, extension `fcproj`,
  conforms to `public.json`, exported by the app. Launch = `DocumentGroupLaunchScene`.
- **Photos is the primary media source** inside the editor (PhotoKit, not `PhotosPicker` copies): the media browser
  lists the user's videos/photos and albums; adding one never shows an "import" step. The engine needs a file path,
  so the asset is materialized into the **media cache** `Library/Caches/FilmCraftMedia/PH-<b64url(localIdentifier)>.<ext>`
  (`PHAssetResourceManager`, original resource) and the engine imports that path. The file name encodes the asset id,
  so on open any missing `PH-…` media is re-materialized from Photos and relinked (container paths change between
  installs). Files-app media (secondary) is copied into `Documents/Media/` (visible in Files).
- **Export** renders H.264 + AAC MP4 with the engine encoder to a temp file, then saves it to Photos
  (add-only authorization, `PHAssetCreationRequest`) or Files (`fileExporter`) / share sheet.
- Engine undo history is mirrored on the scene `UndoManager` (one registration per `historyId` change).
- Autosave = `snapshot(contentType:)` returning the project JSON from `ProjectHandle.projectJson()`.

## 3. Rust bridge API (UniFFI, crate `filmcraft_apple`, Swift module `FilmCraftKit`)

Swift names are what UniFFI 0.32 generates (snake_case → camelCase, `Vec<u8>` → `Data`, `u64` → `UInt64`,
`i64` → `Int64`, `u32` → `UInt32`, `f64` → `Double`, `f32` → `Float`, `Vec<f32>` → `[Float]`, `Option<T>` → `T?`).
Times cross the bridge as `i64` ticks (`filmcraft_time::Tick`, 254 016 000 000/s); Swift converts only for display.
Every exported fn runs engine code under `catch_unwind` and never panics; poisoned locks are recovered.

```rust
#[derive(uniffi::Error)] pub enum BridgeError { Failed { message: String } }

#[derive(uniffi::Record)] pub struct CommandInfo {
    pub id: String, pub label: String,
    pub menu: Vec<String>,          // ["Clip","Speed"]; empty = not in menus
    pub shortcut: Option<String>,   // egui notation "Cmd+Shift+R"
    pub params: String,             // upstream params doc, e.g. {"seconds":f64=5}
    pub is_query: bool,             // journal == false
}
#[derive(uniffi::Record)] pub struct UiCommandInfo {      // crates/ui-egui/src/menus.rs UI_COMMANDS (include_str!)
    pub id: String, pub label: String, pub shortcut: Option<String>, pub menu: Vec<String>,
}
#[derive(uniffi::Record)] pub struct MenuSection { pub title: String, pub items: Vec<String> }
    // title in MENUS order (File, Edit, Clip, Sequence, Markers, Graphics and Titles, View, Window, Help);
    // items: command ids (engine + UI), "---" separators, "@Sub/Path" submenu placeholders, in desktop order
    // as menu_items_for builds them (engine specs incl. sequence_tools splices, then UI commands).
#[derive(uniffi::Record)] pub struct ParamField {         // best-effort parse of a params doc; never panics
    pub key: String, pub kind: String,                    // "number","integer","bool","choice","string","ids","time","json"
    pub min: Option<f64>, pub max: Option<f64>, pub default_json: Option<String>,
    pub choices: Vec<String>, pub label: String, pub is_optional: bool, pub doc: String,
}
#[derive(uniffi::Record)] pub struct ToolInfo { pub id: String, pub label: String, pub shortcut: Option<String> }
    // "tool.selection", … in crates/ui-egui/src/state.rs Tool order (labels/shortcuts from UI_COMMANDS)
#[derive(uniffi::Record)] pub struct PanelInfo { pub id: String, pub title: String }
    // "panel.project", "panel.program", "panel.timeline", "panel.effectControls", … from dock.rs PanelKind::ALL
    // id = "panel." + lowerCamel(variant); title = desktop panel title

#[derive(uniffi::Record)] pub struct ProjectState {
    pub revision: u64,              // bumps on every call that may change anything
    pub history_id: u64,            // changes when an undo step is recorded / undone / redone
    pub can_undo: bool, pub can_redo: bool,
    pub undo_label: Option<String>, pub redo_label: Option<String>,
    pub dirty: bool,
    pub project_name: String,
    pub sequence_name: Option<String>,   // active sequence; None = no sequence
    pub playhead: i64, pub duration: i64,            // ticks
    pub in_point: Option<i64>, pub out_point: Option<i64>,
    pub fps_num: u32, pub fps_den: u32, pub width: u32, pub height: u32,
    pub sample_rate: u32,
    pub selected_clips: Vec<u64>,
    pub media_count: u64,
}
#[derive(uniffi::Record)] pub struct MediaInfo {
    pub id: u64, pub name: String, pub path: String,
    pub kind: String,               // "video","audio","image","sequence","graphic","synthetic"
    pub duration: i64, pub width: u32, pub height: u32,
    pub has_video: bool, pub has_audio: bool, pub offline: bool,
}
#[derive(uniffi::Record)] pub struct ClipInfo {
    pub id: u64, pub track_id: u64, pub media_id: Option<u64>, pub name: String,
    pub start: i64, pub end: i64,   // timeline ticks
    pub source_in: i64,             // ticks into the source
    pub kind: String,               // "video","audio","graphic","text","adjustment",…
    pub selected: bool, pub enabled: bool, pub color: Option<String>, // "#rrggbb"
    pub linked: Vec<u64>,
}
#[derive(uniffi::Record)] pub struct TrackInfo {
    pub id: u64, pub name: String, pub kind: String,  // "video","audio"
    pub index: u32, pub muted: bool, pub locked: bool, pub hidden: bool, pub solo: bool,
    pub clips: Vec<ClipInfo>,
}
#[derive(uniffi::Record)] pub struct MarkerInfo { pub id: u64, pub at: i64, pub duration: i64, pub name: String, pub color: Option<String> }
#[derive(uniffi::Record)] pub struct TimelineSnapshot {
    pub revision: u64, pub tracks: Vec<TrackInfo>, pub markers: Vec<MarkerInfo>, pub duration: i64,
}
#[derive(uniffi::Record)] pub struct RenderedImage { pub width: u32, pub height: u32, pub rgba: Vec<u8> }
    // RGBA8 sRGB, straight alpha composited over black (alpha 255), stride = width*4
#[derive(uniffi::Record)] pub struct AudioBlock { pub sample_rate: u32, pub channels: u32, pub samples: Vec<f32> }
    // interleaved float32
#[derive(uniffi::Record)] pub struct JobStatus {
    pub id: u64, pub kind: String, pub fraction: f64, pub done: bool, pub error: Option<String>, pub output: Option<String>,
}

#[derive(uniffi::Object)] pub struct ProjectHandle { /* Mutex<Inner{session, revision, history_id}> */ }
#[uniffi::export] impl ProjectHandle {
    #[uniffi::constructor] pub fn new_project(name: String) -> Arc<Self>;          // file.newProject + a default sequence
    #[uniffi::constructor] pub fn demo() -> Arc<Self>;                             // file.openDemoProject (procedural, no disk)
    #[uniffi::constructor] pub fn open_json(json: String, path_hint: Option<String>) -> Result<Arc<Self>, BridgeError>;
        // decodes an .fcproj (temp file + file.open); path_hint = where relative media paths resolve
    pub fn project_json(&self) -> Result<String, BridgeError>;                     // filmcraft_format::encode, pretty=false
    pub fn execute(&self, id: String, params_json: String) -> Result<String, BridgeError>; // result JSON
    pub fn disabled_reason(&self, id: String) -> Option<String>;                   // None = enabled; unknown id → Some
    pub fn undo(&self) -> Result<Option<String>, BridgeError>;                     // label undone
    pub fn redo(&self) -> Result<Option<String>, BridgeError>;
    pub fn begin_interaction(&self, label: String) -> Result<(), BridgeError>;     // a drag = one undo step
    pub fn end_interaction(&self) -> Result<(), BridgeError>;
    pub fn state(&self) -> ProjectState;
    pub fn timeline(&self) -> TimelineSnapshot;                                    // active sequence; empty if none
    pub fn media(&self) -> Vec<MediaInfo>;
    pub fn import_files(&self, paths: Vec<String>) -> Result<Vec<u64>, BridgeError>; // file.import; new media ids
    pub fn relink_missing(&self, resolver_dir: String) -> Vec<u64>;                // relinks offline media whose file
        // name exists in resolver_dir; returns still-offline ids (Swift re-materializes PH-… then calls again)
    pub fn clip_effects_json(&self, clip_id: u64) -> Result<String, BridgeError>;
        // serde_json of the clip's effect stack (Vec of {effect, enabled, params:{id:{value:ParamValue,keyframes}}, masks}),
        // same shape as inside project_json; "[]" for a clip without effects; Err for an unknown clip
    pub fn set_playhead(&self, at: i64);
    // Rendering: snapshot Arcs under the lock, render OUTSIDE it (thread-safe; call from a background task).
    pub fn render_program(&self, at: i64, max_w: u32, max_h: u32) -> Result<RenderedImage, BridgeError>;
    pub fn render_source(&self, media_id: u64, at: i64, max_w: u32, max_h: u32) -> Result<RenderedImage, BridgeError>;
    pub fn media_thumbnail(&self, media_id: u64, edge: u32) -> Result<RenderedImage, BridgeError>;
    pub fn audio_peaks(&self, media_id: u64, buckets: u32) -> Result<Vec<f32>, BridgeError>; // 0…1 per bucket
    pub fn mix_audio(&self, from: i64, frames: u32, sample_rate: u32) -> Result<AudioBlock, BridgeError>; // program mix, stereo
    // Export (file.exportMedia under the hood). Starts a background job; poll job_status.
    pub fn start_export(&self, path: String, options_json: String) -> Result<u64, BridgeError>;
        // options: {"preset":"h264"|"prores"|…, "width"?, "height"?, "crf"?, "audio":"aac", "range":"all"|"inout"}
    pub fn job_status(&self, job_id: u64) -> Option<JobStatus>;
    pub fn cancel_job(&self, job_id: u64);
}
#[uniffi::export] pub fn command_catalog() -> Vec<CommandInfo>;
#[uniffi::export] pub fn ui_command_catalog() -> Vec<UiCommandInfo>;
#[uniffi::export] pub fn desktop_menu_layout() -> Vec<MenuSection>;
#[uniffi::export] pub fn command_params(id: String) -> Vec<ParamField>;
#[uniffi::export] pub fn command_platform_support(id: String) -> Option<String>; // Some(reason) from ios-excluded-commands.txt
#[uniffi::export] pub fn timeline_tools() -> Vec<ToolInfo>;
#[uniffi::export] pub fn panel_catalog() -> Vec<PanelInfo>;
#[uniffi::export] pub fn ticks_per_second() -> i64;
#[uniffi::export] pub fn format_timecode(ticks: i64, fps_num: u32, fps_den: u32) -> String; // HH:MM:SS:FF
#[uniffi::export] pub fn engine_version() -> String;
```

Bridge files: `ui-commands.txt` (every command id the Swift sources reference literally), `ios-excluded-commands.txt`
(`id<TAB>reason`, conservative: Finder/reveal, external monitors, native windows, speech downloads, capture devices…).
Engine features: default only (no whisper/neural voices/downloads). No dependency on `filmcraft-ui-egui`,
`filmcraft-gpu`, cpal, egui, tokio. `filmcraft-platform` only if it builds for iOS without edits (it falls back to
pure-Rust decode there; VideoToolbox is `cfg(target_os = "macos")` upstream — note for upstream).

## 4. Swift core surface (`apple/FilmCraft/Core`, `Media`, `App`)

```swift
final class FilmCraftDocument: ReferenceFileDocument {        // Snapshot = Data (project JSON)
    static var readableContentTypes: [UTType] { [.filmcraftProject] }
    let model: EditorModel                                    // created in init(); init(configuration:) → open_json
}
@MainActor @Observable final class EditorModel {
    let handle: ProjectHandle
    var state: ProjectState                 // refreshed after every call
    var timeline: TimelineSnapshot
    var media: [MediaInfo]
    var activeTool: String                  // "tool.selection" … (ToolInfo.id)
    var activePanel: String?                // "panel.effectControls" … (PanelInfo.id) shown in the inspector/sheet
    var isPlaying: Bool
    var pixelsPerSecond: Double             // timeline zoom
    var lastError: String?                  // alert with the full message
    var isDemoReady: Bool
    var pendingCommand: String?             // command that needs params → CommandSheet
    var showCommandPalette: Bool, showMediaBrowser: Bool, showExport: Bool, inspectorVisible: Bool
    var programFrame: CGImage?              // latest rendered program frame
    var undoRedoTick: Int
    weak var undoManager: UndoManager?

    @discardableResult func run(_ id: String, _ params: [String: Any] = [:]) -> Bool   // true on success; execute + refresh + undo registration; errors → lastError
    func isEnabled(_ id: String) -> Bool
    func present(_ id: String)              // runs directly when no required params, else pendingCommand = id
    @discardableResult func runUI(_ id: String) -> Bool  // UI-only ids: tool.*, panel.*/window.*, view.*, playback.* handled in Swift
    func refresh()
    func seek(_ ticks: Int64)               // set_playhead + render
    func togglePlay(); func stepFrame(_ delta: Int)
    func selectClip(_ id: UInt64, extend: Bool)
    func beginDrag(_ label: String); func endDrag()
    func addFromPhotos(_ localIdentifiers: [String], insertAtPlayhead: Bool) async
    func addFiles(_ urls: [URL], insertAtPlayhead: Bool) async
    func thumbnail(media id: UInt64, edge: Int) async -> CGImage?
    func export(to destination: ExportDestination, options: ExportOptions) async   // .photos / .files(URL)
}
@MainActor @Observable final class PhotosLibrary {             // Media/
    var authorization: PHAuthorizationStatus; var assets: [PHAsset]; var albums: [PHAssetCollection]
    func requestAccess() async; func select(album: PHAssetCollection?)
    func materialize(_ localIdentifier: String) async throws -> URL   // media cache path (PH-…)
}
final class PlaybackEngine                                     // Media/: CADisplayLink frames + AVAudioEngine source node pulling mix_audio
enum ExportDestination { case photos; case files(URL) }
struct ExportOptions { var preset: String; var width: Int?; var height: Int?; var quality: Int }
```

Entry views: the scene builds `EditorRootView(model: document.model)` (UI, `UI/Shared/EditorRootView.swift`), which picks
`PadEditorView` or `PhoneEditorView` by horizontal size class / window width. `EditorRootView` attaches the
`CommandSheet`, `CommandPaletteView`, `ExportSheet`, `MediaBrowserView` sheets and the error alert, and publishes
`.focusedSceneValue(\.editorModel, model)` (key declared in `Core/FocusedValues.swift`). Menu bar
`App/EditorCommands.swift` (Core) reads `@FocusedValue(\.editorModel)` and is generated from `desktop_menu_layout()`.

`CommandCatalog` (Core, singleton): `menus: [MenuSection]`, `tools: [ToolInfo]`, `panels: [PanelInfo]`,
`command(id)`, `label(id)`, `shortcut(id) -> KeyboardShortcut?`, `params(id)`, `isExcludedOnIOS(id)`.

Demo: launch argument `-FilmCraftDemo` opens a new untitled document built from `ProjectHandle.demo()` (seeds on
create), sets `isDemoReady = true` after the first program frame rendered.

## 5. Accessibility identifiers (UI tests drive only these)

`tool.<id>` (e.g. `tool.razor`), `panel.<id>`, `command.<id>` on every surface showing a command (menus, context
menus, toolbars, sheets, palette rows), `param.<key>` in command forms, `track.<id>`, `clip.<id>`, `media.<id>`,
`asset.<index>` (Photos browser cells, in display order), `album.<index>`, `marker.<id>`, `timeline`, `viewer`,
`playhead`, `timecode`, `transport.play`, `transport.stepBack`, `transport.stepForward`, `transport.start`,
`transport.end`, `mediaBrowser`, `import.photos`, `import.files`, `export`, `export.photos`, `export.files`,
`export.progress`, `inspector`, `palette`, `demoReady` (hidden element once demo seeding finished),
`photos.denied`, `photos.limited`. Widget ids never look like command ids: a dotted widget id must start with a reserved widget prefix that no engine
or UI command uses: `menu.`, `photos.`, `fx.`, `album.`, `asset.`, `media.`, `track.`, `clip.`, `marker.`, `transport.`,
`export.`, `import.`, `param.`, `tool.`/`panel.`/`command.` (these three name catalog items). Other widget ids are
undotted camelCase (`commandSheetRun`, `paletteDone`, `mediaPanel`, `trackMute_<id>`). `scripts/check-command-ids.sh`
checks only literals passed to run/present/runUI and `command.<id>` identifiers.

## 6. Panels, panel actions and the menu bar (cookbook §4, all-forks rules)

**Rules.**
1. Every desktop panel (`panel_catalog()`, from `crates/ui-egui/src/dock.rs` `PanelKind::ALL`: Project, Media Browser,
   Libraries, Info, Effects, Markers, History, Source, Effect Controls, Audio Clip Mixer, Metadata, Program, Timeline,
   Tools, Audio Meters, Audio Track Mixer, Lumetri Color, Lumetri Scopes, Essential Graphics, Essential Sound, Text to
   Speech, Properties, Text, Events, Progress, Reference Monitor, Timecode, Project Notes) exists on iOS with its own
   content and opens from both the panel menu (`menu.panels`) and the Window menu (`command.panel.<id>`). A panel entry
   that opens nothing, or only a list of loosely related commands, is a bug. Panels excluded on iOS are listed in
   `bridge/ios-excluded-commands.txt` with a reason and are hidden from both menus.
2. iPad: panels live in a dock (the top-leading zone plus an optional inspector column) where the user can **add,
   hide, collapse, and stack/reorder** them like Premiere's panel groups (tabs within a group, groups stacked
   vertically, drag a tab to reorder or move it between groups, a chevron collapses a group). The arrangement is
   persisted per window scene (`@SceneStorage`, JSON of `[[panelId]]` + collapsed set) and restorable via Window ▸
   Workspaces ▸ Reset. Program and Timeline are panels too (the viewer and timeline zones are their default homes).
   iPhone: every panel opens as a sheet with detents (unchanged).
3. **Panel-owned actions sit in their panel's header**, not the global toolbar: Media/Project → Import (Photos,
   Files), New Bin, list/grid; Timeline → Add Track, snapping, linked selection, track height; Effects → search;
   Effect Controls → reset all; Audio mixers → add/remove track; Markers → add marker; Lumetri → reset. The global
   toolbar keeps only document-level items: undo/redo, tools menu, panels menu, palette, full screen, share/export.
   Header ids: `panel.<id>.header`, actions `command.<id>` (engine commands) or `<panelId>.<action>` widget ids under a
   reserved prefix (e.g. `media.import`, `track.add`).
4. **iPad menu bar = merge**: keep the iPadOS system groups (app menu, File, Edit, Format, View, Window, Help) and
   insert the desktop menus and their items in desktop order (File, Edit, Clip, Sequence, Markers, Graphics and
   Titles, View, Window, Help — `desktop_menu_layout()`): desktop File/Edit/View items go into the system File/Edit/View
   groups (`CommandGroup(after:)`), desktop-only menus (Clip, Sequence, Markers, Graphics and Titles) sit between Edit
   and View in that order, Window (with every panel and the workspaces) and Help come last.
5. Coverage: `PanelTourUITests` opens **and acts on** every panel from `catalogDump`; "opened but empty" and "no
   action possible" are failures, not notes.

**Current non-compliance (as of 6a8a45a2, to fix when FilmCraft is off hold).**
- Only 4 panels have content (`panel.project`, `panel.effects`, `panel.effectControls`, `panel.audioTrackMixer` in
  `UI/Panels/PanelHost.swift`); the other 24 fall back to `GenericPanel` (a command list) — violates rule 1. Missing
  real content for: Media Browser, Libraries, Info, Markers, History, Source, Audio Clip Mixer, Metadata, Program,
  Timeline, Tools, Audio Meters, Lumetri Color, Lumetri Scopes, Essential Graphics, Essential Sound, Text to Speech,
  Properties, Text, Events, Progress, Reference Monitor, Timecode, Project Notes (or an iOS exclusion with reason).
- Panels are fixed chips + a "More" menu (`UI/Panels/PanelHost.swift`, `UI/Pad/PadEditorView.swift`): no add/hide,
  collapse, stacking, reordering or persistence — violates rule 2. Program and Timeline are fixed zones, not panels.
- `addMedia` (Import) is a global toolbar item (`UI/Shared/TopBarControls.swift`) instead of the Media panel header;
  no panel has a header action row; Add Track and markers actions are not in their panels — violates rule 3.
- Menu bar (`App/EditorCommands.swift`): desktop Clip/Sequence/Markers/Graphics and Titles menus are appended after
  the system View menu, and desktop File/Edit/View items are not merged into the system groups — violates rule 4.
- `PanelTourUITests` records empty panels as notes, not failures — violates rule 5.

## 7. Productivity, Apple-clean (cookbook §0b)

**Rules.**
1. **≤ 1 tap** from the viewer or timeline for every frequent action: play/pause, split at playhead, delete/ripple
   delete, trim, add marker, set in/out, undo/redo, add media at playhead, select tool, open Effect Controls of the
   selected clip.
2. **Hardware keyboard = desktop shortcuts**, same keys, generated from the catalogs (`CommandInfo.shortcut`,
   `UiCommandInfo.shortcut`, tools): J/K/L shuttle (J = reverse shuttle, repeated presses speed up), Space, I/O,
   ⇧I/⇧O, C/V/B/N/R/Y/U/P/H/Z/T tools, ⌘K add edit, Q/W ripple trim, ←/→ frame step, ↑/↓ edit points, M marker,
   ⌘Z/⇧⌘Z. Shown in the iPad ⌘-hold overlay through the menu bar. `⌘⇧P` (and `⌘K` if not taken by Add Edit — use the
   desktop's palette shortcut) opens the command palette.
3. **Context menus** on clips (`clip.<id>`), tracks (`track.<id>`), markers, project media/bins (`media.<id>`) and
   Photos assets, built from the desktop menu sections (`CommandMenuContent`), every item `command.<id>`.
4. **Drag & drop**: Photos assets and project media onto the timeline (insert at the drop time/track), Files/other
   apps into the media panel (`dropDestination` for movies/images/audio), clips within the timeline (move), and out
   to other apps as exported movie (`draggable` with a lazy `Transferable` export) where cheap.
5. **Gestures**: two-finger tap = undo, three-finger tap = redo (on the editor root, not inside text fields); pinch
   = timeline zoom; long-press = context menu.
6. **Scrubbable fields**: timecode (`timecode`) and every numeric parameter (Effect Controls, command forms) can be
   dragged horizontally to change the value (one undo step per drag) and tapped to type.
7. **Customizable toolbar** (`.toolbar(id:)` + `ToolbarItem(id:)` + `.toolbarRole(.editor)`), **remember** last
   layout (panel dock, zoom, inspector), last export settings and last command-form values (`@SceneStorage` /
   `@AppStorage`), **multi-window** (each window = one document scene; `UIApplicationSupportsMultipleScenes`).
8. **Clean**: system components, SF Symbols, semantic colours; one primary action per area, everything else in
   menus, panel headers or the palette; no custom chrome.
9. The Haiku feature pass reports **taps-to-do** for the top 10 workflows: add a clip from Photos at the playhead;
   split + delete a segment; trim a clip end; reorder two clips; add a cross-dissolve; adjust volume of a clip; add a
   title; colour-correct (Lumetri exposure); add a marker and jump to it; export to Photos.

**Current gaps (as of a99eea88).**
- Context menus exist only via `CommandMenuContent` in menus; no `.contextMenu` on clips, tracks, markers, media or
  assets (rule 3).
- No drag & drop anywhere (`dropDestination`/`draggable` absent) (rule 4).
- No two/three-finger tap undo/redo (rule 5).
- Keyboard: only a hand-written subset of single keys in `UI/Shared/EditorRootView.swift`; J steps one frame
  instead of reverse shuttle; not generated from the catalog shortcuts (rule 2).
- Timecode and numeric parameter fields are not scrubbable (rule 6).
- Toolbar is not customizable (no `.toolbar(id:)`/`.toolbarRole(.editor)`); only the Pad split fraction is
  remembered; last export/command-form values are not (rule 7).
- Import (`addMedia`) is in the global toolbar (also §6 rule 3). Multi-window is declared in `project.yml` but
  untested.

## 8. Start from / import media (cookbook §0b)

**Rules.** A new project can start from media: the launch/new-document flow offers "New Project from Media…"
(Photos + Files), creating the project and a sequence matching the first clip, with all picked items on the timeline
in pick order. Into an open project, media is imported into the current context — the selected bin, or straight onto
the timeline at the playhead (`EditorModel.addFromPhotos/addFiles(insertAtPlayhead:)`) — from the camera roll (the
in-app PhotoKit browser, plus `PhotosPicker` when Photos access is denied/limited), Files/iCloud Drive
(`fileImporter`, movies/images/audio, security-scoped copy into `Documents/Media/`), drag & drop and paste
(`pasteDestination`/⌘V of movie, image, audio or file URLs). Entry points: new-project flow, Media panel header
"Import" (`media.import`), File ▸ Import (`command.file.import`), the palette, and context menus on bins and the
timeline ("Add Media Here").

**Current gaps (as of a2698f0b).** No "New Project from Media" flow (new documents start empty); no `PhotosPicker`
fallback for denied/limited access; no drag & drop or paste import; no bin targeting (media goes to the project root);
Import lives in the global toolbar (`addMedia`), not the Media panel header.

**Native decoding (cookbook §0b).** Imported video/audio decode with AVFoundation/VideoToolbox (H.264, HEVC incl.
10-bit/HDR, ProRes, AAC/ALAC; hardware-accelerated) and still images with ImageIO (HEIC, JPEG, PNG, RAW/ProRAW via
CoreImage); the engine's pure-Rust decoders are used only for its own formats or where no native decoder exists.
Design: the bridge declares UniFFI foreign traits implemented in Swift (`Media/NativeDecoders.swift`):
`NativeVideoDecoder` (open(path) → info {w, h, fps, duration, hasAudio}; frame(at: ticks, maxW, maxH) → RGBA8/BGRA
`Data` via `AVAssetImageGenerator`/`AVAssetReader` + `VTDecompressionSession`), `NativeAudioDecoder` (open; read(from:
ticks, frames, sampleRate) → interleaved f32 via `AVAssetReader`/`AVAudioFile`), `NativeImageDecoder` (ImageIO). Swift
registers them once at launch with `register_native_decoders(video:audio:image:)`; the bridge wraps them as
`filmcraft_codecs` decoder factories ahead of the built-ins (the same hook `filmcraft-platform` uses for VideoToolbox
on macOS, `crates/codecs/src/lib.rs` factory registry), so `MediaPool::open_file` picks them for the formats they
claim. Export likewise may register an AVAssetWriter H.264/HEVC + AAC encoder through `filmcraft_export::register_encoder`
(fall back to the engine's pure-Rust H.264/AAC). Never call Swift decoders on the audio realtime thread; frames cross
the bridge as `Data`. Upstream note: `filmcraft-platform`'s VideoToolbox code is `cfg(target_os = "macos")` only —
propose widening it to iOS upstream; until then the bridge-side registration is the fork's workaround.

**Gap (as of 23e7868a).** All decode is pure Rust (the bridge doesn't use `filmcraft-platform`; no native decoder or
encoder registration exists).
