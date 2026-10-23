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
