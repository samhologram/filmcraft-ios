//! UniFFI bridge between the FilmCraft engine and the Swift app (iOS / iPadOS).
//!
//! The API is specified in `apple/docs/CONTRACT.md` section 3; names and types here match it.
//! Never panics on input: engine calls run under `catch_unwind` as a last-resort guard, locks are
//! poison-tolerant, sizes are clamped.
//!
//! Deviations from CONTRACT.md (also listed in the bridge report):
//! * `desktop_menu_layout()` items: command ids, "---" separators between the engine / UI / panel
//!   groups of a menu, and "@Sub" (first-level submenu name, NOT a full path) at the position of a
//!   submenu's first item; deeper levels are found through the `menu` field of `CommandInfo` /
//!   `UiCommandInfo`. Window entries for panels are the panel ids ("panel.timeline"), not the
//!   desktop's "window.panel.timeline".
//! * `ProjectHandle::open_json`: the project is decoded through `file.open` from a temp file;
//!   `path_hint` becomes the session path afterwards (relative media paths are then re-resolved by a
//!   relink scan), it is not the folder the decode itself resolves against.
//! * `ui_command_catalog()` also lists the keyboard-parity commands of `panels/keyboard.rs`
//!   (`COMMANDS`), as the desktop's menu builder does.
#![deny(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::unimplemented, clippy::todo, clippy::unreachable)]

use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use filmcraft_engine::Session;
use filmcraft_engine::time::{FrameRate, Tick};
use serde_json::{Value, json};

mod info;
pub mod menus_src;
pub mod params_doc;
mod render;

uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum BridgeError {
    #[error("{message}")]
    Failed { message: String },
}

pub(crate) fn fail(message: impl Into<String>) -> BridgeError {
    BridgeError::Failed { message: message.into() }
}

#[derive(uniffi::Record)]
pub struct CommandInfo {
    pub id: String,
    pub label: String,
    /// e.g. ["Clip", "Speed"]; empty = not in menus.
    pub menu: Vec<String>,
    /// egui notation, "Cmd+Shift+R".
    pub shortcut: Option<String>,
    /// The upstream params doc, e.g. `{"seconds":f64=5}`.
    pub params: String,
    /// `journal == false`.
    pub is_query: bool,
}

/// UI-only desktop commands, parsed from `crates/ui-egui/src/menus.rs` (and `panels/keyboard.rs`).
#[derive(uniffi::Record)]
pub struct UiCommandInfo {
    pub id: String,
    pub label: String,
    pub shortcut: Option<String>,
    /// ["Window", "Workspaces"]; empty = not in menus.
    pub menu: Vec<String>,
}

#[derive(Debug, uniffi::Record)]
pub struct MenuSection {
    pub title: String,
    pub items: Vec<String>,
}

/// Structured view of a params doc; best effort.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ParamField {
    /// "" = free-form extra params (`doc` = raw fragment).
    pub key: String,
    /// "number", "integer", "bool", "choice", "string", "ids", "time", "json".
    pub kind: String,
    pub min: Option<f64>,
    pub max: Option<f64>,
    pub default_json: Option<String>,
    pub choices: Vec<String>,
    pub label: String,
    pub is_optional: bool,
    pub doc: String,
}

#[derive(uniffi::Record)]
pub struct ToolInfo {
    pub id: String,
    pub label: String,
    pub shortcut: Option<String>,
}

#[derive(uniffi::Record)]
pub struct PanelInfo {
    pub id: String,
    pub title: String,
}

#[derive(uniffi::Record)]
pub struct ProjectState {
    /// Bumps on every call that may change anything.
    pub revision: u64,
    /// Changes when an undo step is recorded, undone or redone.
    pub history_id: u64,
    pub can_undo: bool,
    pub can_redo: bool,
    pub undo_label: Option<String>,
    pub redo_label: Option<String>,
    pub dirty: bool,
    pub project_name: String,
    pub sequence_name: Option<String>,
    pub playhead: i64,
    pub duration: i64,
    pub in_point: Option<i64>,
    pub out_point: Option<i64>,
    pub fps_num: u32,
    pub fps_den: u32,
    pub width: u32,
    pub height: u32,
    pub sample_rate: u32,
    pub selected_clips: Vec<u64>,
    pub media_count: u64,
}

#[derive(uniffi::Record)]
pub struct MediaInfo {
    pub id: u64,
    pub name: String,
    pub path: String,
    /// "video","audio","image","sequence","graphic","synthetic".
    pub kind: String,
    pub duration: i64,
    pub width: u32,
    pub height: u32,
    pub has_video: bool,
    pub has_audio: bool,
    pub offline: bool,
}

#[derive(uniffi::Record)]
pub struct ClipInfo {
    pub id: u64,
    pub track_id: u64,
    pub media_id: Option<u64>,
    pub name: String,
    pub start: i64,
    pub end: i64,
    pub source_in: i64,
    /// "video","audio","graphic","adjustment".
    pub kind: String,
    pub selected: bool,
    pub enabled: bool,
    /// "#rrggbb".
    pub color: Option<String>,
    pub linked: Vec<u64>,
}

#[derive(uniffi::Record)]
pub struct TrackInfo {
    pub id: u64,
    pub name: String,
    /// "video" or "audio".
    pub kind: String,
    pub index: u32,
    pub muted: bool,
    pub locked: bool,
    pub hidden: bool,
    pub solo: bool,
    pub clips: Vec<ClipInfo>,
}

#[derive(uniffi::Record)]
pub struct MarkerInfo {
    pub id: u64,
    pub at: i64,
    pub duration: i64,
    pub name: String,
    pub color: Option<String>,
}

#[derive(uniffi::Record)]
pub struct TimelineSnapshot {
    pub revision: u64,
    pub tracks: Vec<TrackInfo>,
    pub markers: Vec<MarkerInfo>,
    pub duration: i64,
}

#[derive(uniffi::Record)]
pub struct RenderedImage {
    pub width: u32,
    pub height: u32,
    /// RGBA8 sRGB composited over black (alpha 255), stride = width * 4.
    pub rgba: Vec<u8>,
}

#[derive(uniffi::Record)]
pub struct AudioBlock {
    pub sample_rate: u32,
    pub channels: u32,
    /// Interleaved float32.
    pub samples: Vec<f32>,
}

#[derive(uniffi::Record)]
pub struct JobStatus {
    pub id: u64,
    pub kind: String,
    pub fraction: f64,
    pub done: bool,
    pub error: Option<String>,
    pub output: Option<String>,
}

/// An open `begin_interaction` gesture.
struct Interaction {
    label: String,
    /// Undo-stack length when the gesture began.
    base: usize,
    /// The history limit to restore (it is lifted while a gesture runs so its first step survives).
    limit: usize,
}

type HistorySig = (usize, usize, usize);

struct Inner {
    session: Session,
    revision: u64,
    history_id: u64,
    history_sig: HistorySig,
    interaction: Option<Interaction>,
}

impl Inner {
    fn new(session: Session) -> Self {
        let sig = Self::sig(&session);
        Inner { session, revision: 1, history_id: 1, history_sig: sig, interaction: None }
    }

    fn sig(s: &Session) -> HistorySig {
        let top = s.history.undo.last().map(|u| Arc::as_ptr(&u.1) as usize).unwrap_or(0);
        (s.history.undo.len(), s.history.redo.len(), top)
    }

    /// Bump `history_id` when the undo/redo stacks moved since the last look.
    fn sync_history(&mut self) {
        let sig = Self::sig(&self.session);
        if sig != self.history_sig {
            self.history_sig = sig;
            self.history_id = self.history_id.wrapping_add(1);
        }
    }

    fn touch(&mut self) {
        self.revision = self.revision.wrapping_add(1);
        self.sync_history();
        // nobody reads the event queue here; keep it from growing
        self.session.events.clear();
    }
}

#[derive(uniffi::Object)]
pub struct ProjectHandle {
    inner: Mutex<Inner>,
}

fn panic_message(payload: &(dyn std::any::Any + Send)) -> String {
    let text = payload.downcast_ref::<&str>().map(|s| (*s).to_string()).or_else(|| payload.downcast_ref::<String>().cloned());
    format!("internal error: {}", text.unwrap_or_else(|| "the engine panicked".into()))
}

fn parse_params(params_json: &str) -> Result<Value, BridgeError> {
    if params_json.trim().is_empty() {
        return Ok(json!({}));
    }
    let v: Value = serde_json::from_str(params_json).map_err(|e| fail(format!("params_json is not valid JSON: {e}")))?;
    if v.is_null() { Ok(json!({})) } else { Ok(v) }
}

fn run_cmd(s: &mut Session, id: &str, params: Value) -> Result<Value, BridgeError> {
    s.execute(id, params).map_err(|e| fail(e.to_string()))
}

static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

impl ProjectHandle {
    fn wrap(session: Session) -> Arc<Self> {
        Arc::new(Self { inner: Mutex::new(Inner::new(session)) })
    }

    /// Run `f` with the session locked, turning a panic into an error.
    fn guarded<T>(&self, f: impl FnOnce(&mut Inner) -> Result<T, BridgeError>) -> Result<T, BridgeError> {
        let mut guard = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        match catch_unwind(AssertUnwindSafe(|| f(&mut guard))) {
            Ok(r) => r,
            Err(payload) => Err(fail(panic_message(payload.as_ref()))),
        }
    }

    /// Like [`Self::guarded`] for calls that cannot report an error.
    fn guarded_or<T>(&self, fallback: T, f: impl FnOnce(&mut Inner) -> T) -> T {
        let mut guard = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        catch_unwind(AssertUnwindSafe(|| f(&mut guard))).unwrap_or(fallback)
    }

    /// Clone what a render needs under the lock; the render itself then runs outside it.
    fn snapshot(&self) -> Result<render::Snapshot, BridgeError> {
        self.guarded(|i| Ok(render::Snapshot::of(&i.session)))
    }
}

fn run_outside<T>(f: impl FnOnce() -> Result<T, BridgeError>) -> Result<T, BridgeError> {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or_else(|p| Err(fail(panic_message(p.as_ref()))))
}

/// `file.exportMedia` params from the contract's options JSON.
fn export_params(path: &str, options_json: &str) -> Result<Value, BridgeError> {
    let opts: Value = if options_json.trim().is_empty() {
        json!({})
    } else {
        serde_json::from_str(options_json).map_err(|e| fail(format!("options_json is not valid JSON: {e}")))?
    };
    let o = match &opts {
        Value::Object(o) => o.clone(),
        Value::Null => Default::default(),
        _ => return Err(fail("options_json must be a JSON object")),
    };
    if path.trim().is_empty() {
        return Err(fail("the export path is empty"));
    }
    let mut p = json!({"path": path, "wait": false});
    const FORMATS: [&str; 19] = [
        "h264", "hevc", "prores", "dnxhr", "apv", "mjpeg", "mxf-op1a", "mxf-opatom", "png", "tiff", "bmp", "jpg", "tga", "dpx", "exr", "gif", "wav", "aiff", "aac",
    ];
    if let Some(preset) = o.get("preset").and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()) {
        let lower = preset.to_ascii_lowercase();
        if FORMATS.contains(&lower.as_str()) || lower == "flac" {
            p["format"] = json!(lower);
        } else {
            p["preset"] = json!(preset);
        }
    }
    for key in ["width", "height"] {
        if let Some(n) = o.get(key).and_then(Value::as_u64).filter(|n| (1..=16_384).contains(n)) {
            p[key] = json!(n);
        }
    }
    if let Some(n) = o.get("crf").and_then(Value::as_u64).filter(|n| *n <= 51) {
        p["crf"] = json!(n);
        p["bitrateMode"] = json!("crf");
    }
    if let Some(n) = o.get("bitrateKbps").and_then(Value::as_u64).filter(|n| (1..=2_000_000).contains(n)) {
        p["bitrateKbps"] = json!(n);
    }
    match o.get("audio") {
        Some(Value::String(a)) if a == "none" => p["audio"] = json!(false),
        Some(Value::String(a)) if !a.is_empty() => p["audioCodec"] = json!(a),
        Some(Value::Bool(b)) => p["audio"] = json!(*b),
        _ => {}
    }
    match o.get("range").and_then(Value::as_str) {
        Some("all") => p["range"] = json!("entire"),
        Some("inout") => p["range"] = json!("inOut"),
        Some(other) if !other.is_empty() => p["range"] = json!(other),
        _ => {}
    }
    Ok(p)
}

#[uniffi::export]
impl ProjectHandle {
    /// A new empty project with one default sequence (`file.newProject` + `file.newSequence`).
    #[uniffi::constructor]
    pub fn new_project(name: String) -> Arc<Self> {
        let handle = Self::wrap(Session::default());
        let _ = handle.guarded(|i| {
            run_cmd(&mut i.session, "file.newProject", json!({"name": if name.trim().is_empty() { "Untitled" } else { name.as_str() }}))?;
            // an unusable default sequence leaves an empty project; the app can still add one
            let _ = run_cmd(&mut i.session, "file.newSequence", json!({"name": "Sequence 01"}));
            // a fresh project has no undo history and is not dirty
            let limit = i.session.history.limit;
            i.session.history = Default::default();
            i.session.history.limit = limit;
            i.session.saved_revision = i.session.revision;
            i.history_sig = Inner::sig(&i.session);
            i.touch();
            Ok(())
        });
        handle
    }

    /// The procedural demo project (synthetic footage, nothing on disk).
    #[uniffi::constructor]
    pub fn demo() -> Arc<Self> {
        let handle = Self::wrap(Session::default());
        let _ = handle.guarded(|i| {
            run_cmd(&mut i.session, "file.openDemoProject", json!({}))?;
            i.history_sig = Inner::sig(&i.session);
            i.touch();
            Ok(())
        });
        handle
    }

    /// Decode an `.fcproj` (UTF-8 JSON). `path_hint` = the document's path, kept as the session path.
    #[uniffi::constructor]
    pub fn open_json(json: String, path_hint: Option<String>) -> Result<Arc<Self>, BridgeError> {
        if json.trim().is_empty() {
            return Err(fail("the project file is empty"));
        }
        let handle = Self::wrap(Session::default());
        handle.guarded(|i| {
            let dir = filmcraft_engine::temp_dir().join(format!("filmcraft-open-{}-{}", std::process::id(), TEMP_COUNTER.fetch_add(1, Ordering::Relaxed)));
            std::fs::create_dir_all(&dir).map_err(|e| fail(format!("cannot create a temporary folder: {e}")))?;
            let file = dir.join("project.fcproj");
            let written = std::fs::write(&file, json.as_bytes()).map_err(|e| fail(format!("cannot write the temporary project: {e}")));
            let opened = written.and_then(|()| run_cmd(&mut i.session, "file.open", json!({"path": file.to_string_lossy()})));
            let _ = std::fs::remove_dir_all(&dir);
            opened?;
            if let Some(hint) = path_hint.filter(|h| !h.trim().is_empty()) {
                i.session.path = Some(hint);
                filmcraft_engine::relink::refresh(&mut i.session);
            } else {
                i.session.path = None;
            }
            i.session.history = Default::default();
            i.session.history.limit = 200;
            i.session.saved_revision = i.session.revision;
            i.history_sig = Inner::sig(&i.session);
            i.touch();
            Ok(())
        })?;
        Ok(handle)
    }

    /// The project as `.fcproj` JSON (not pretty-printed), including which sequence is open.
    pub fn project_json(&self) -> Result<String, BridgeError> {
        self.guarded(|i| {
            let view = i.session.project_view();
            let bytes = filmcraft_format::encode_with_view(&i.session.project, Some(&view), false);
            String::from_utf8(bytes).map_err(|e| fail(format!("the project is not valid UTF-8: {e}")))
        })
    }

    /// Run a command by id with JSON params; returns the result JSON.
    pub fn execute(&self, id: String, params_json: String) -> Result<String, BridgeError> {
        let params = parse_params(&params_json)?;
        self.guarded(|i| {
            let mutates = filmcraft_engine::find_command(&id).is_none_or(|c| c.journal);
            let r = i.session.execute(&id, params);
            if mutates {
                i.touch();
            } else {
                i.sync_history();
                i.session.events.clear();
            }
            r.map(|v| v.to_string()).map_err(|e| fail(e.to_string()))
        })
    }

    /// `None` = enabled. Unknown ids are reported as disabled.
    pub fn disabled_reason(&self, id: String) -> Option<String> {
        self.guarded_or(Some("internal error".to_string()), |i| match filmcraft_engine::find_command(&id) {
            None => Some(format!("unknown command `{id}`")),
            Some(spec) => (spec.enabled)(&i.session).err(),
        })
    }

    pub fn undo(&self) -> Result<Option<String>, BridgeError> {
        self.guarded(|i| {
            let r = i.session.undo();
            i.touch();
            Ok(r)
        })
    }

    pub fn redo(&self) -> Result<Option<String>, BridgeError> {
        self.guarded(|i| {
            let r = i.session.redo();
            i.touch();
            Ok(r)
        })
    }

    /// Start a continuous edit (a drag): everything until `end_interaction` is one undo step.
    pub fn begin_interaction(&self, label: String) -> Result<(), BridgeError> {
        self.guarded(|i| {
            if i.interaction.is_none() {
                i.interaction = Some(Interaction { label, base: i.session.history.undo.len(), limit: i.session.history.limit });
                // keep every step of the gesture so its first snapshot can be found afterwards
                i.session.history.limit = usize::MAX;
            }
            i.touch();
            Ok(())
        })
    }

    pub fn end_interaction(&self) -> Result<(), BridgeError> {
        self.guarded(|i| {
            if let Some(g) = i.interaction.take() {
                let h = &mut i.session.history;
                h.limit = g.limit;
                // the snapshot before the gesture's first edit stands for the whole gesture
                let first = h.undo.get(g.base).map(|e| e.1.clone());
                if let Some(first) = first {
                    h.undo.truncate(g.base);
                    h.undo.push((g.label, first));
                }
                while h.undo.len() > h.limit && !h.undo.is_empty() {
                    h.undo.remove(0);
                }
                h.merge_key = None;
            }
            i.touch();
            Ok(())
        })
    }

    pub fn state(&self) -> ProjectState {
        let fallback = ProjectState {
            revision: 0,
            history_id: 0,
            can_undo: false,
            can_redo: false,
            undo_label: None,
            redo_label: None,
            dirty: false,
            project_name: String::new(),
            sequence_name: None,
            playhead: 0,
            duration: 0,
            in_point: None,
            out_point: None,
            fps_num: 24,
            fps_den: 1,
            width: 0,
            height: 0,
            sample_rate: 48_000,
            selected_clips: Vec::new(),
            media_count: 0,
        };
        self.guarded_or(fallback, |i| {
            i.sync_history();
            info::state(&i.session, i.revision, i.history_id)
        })
    }

    pub fn timeline(&self) -> TimelineSnapshot {
        self.guarded_or(TimelineSnapshot { revision: 0, tracks: Vec::new(), markers: Vec::new(), duration: 0 }, |i| info::timeline(&i.session, i.revision))
    }

    pub fn media(&self) -> Vec<MediaInfo> {
        self.guarded_or(Vec::new(), |i| info::media(&i.session))
    }

    /// The clip's effect instances as JSON (the shape used inside `project_json`): `[]` without effects,
    /// an error for an unknown clip. Looks in the active sequence first, then in every sequence.
    pub fn clip_effects_json(&self, clip_id: u64) -> Result<String, BridgeError> {
        self.guarded(|i| {
            let id = filmcraft_engine::project::ClipId(clip_id);
            let s = &i.session;
            let in_active = s.active_sequence().and_then(|q| q.all_tracks().find_map(|t| t.item(id)));
            let found = in_active.or_else(|| {
                s.project.items.values().filter_map(|it| it.as_sequence()).find_map(|q| q.all_tracks().find_map(|t| t.item(id)))
            });
            let clip = found.ok_or_else(|| fail(format!("no such clip {clip_id}")))?;
            serde_json::to_string(&clip.effects).map_err(|e| fail(e.to_string()))
        })
    }

    /// `file.import`; returns the new media item ids.
    pub fn import_files(&self, paths: Vec<String>) -> Result<Vec<u64>, BridgeError> {
        if paths.is_empty() {
            return Err(fail("no files to import"));
        }
        self.guarded(|i| {
            let r = run_cmd(&mut i.session, "file.import", json!({"paths": paths}));
            i.touch();
            let v = r?;
            Ok(v.get("items").and_then(Value::as_array).map(|a| a.iter().filter_map(Value::as_u64).collect()).unwrap_or_default())
        })
    }

    /// Relink offline media whose file name exists in `resolver_dir`; returns the ids still offline.
    pub fn relink_missing(&self, resolver_dir: String) -> Vec<u64> {
        self.guarded_or(Vec::new(), |i| {
            let dir = Path::new(&resolver_dir);
            let pending: Vec<(u64, String)> = info::media(&i.session).into_iter().filter(|m| m.offline && !m.path.is_empty()).map(|m| (m.id, m.path)).collect();
            for (id, path) in pending {
                let Some(name) = Path::new(&path).file_name() else { continue };
                let candidate = dir.join(name);
                if candidate.is_file() {
                    let cand = candidate.to_string_lossy().into_owned();
                    i.session.media.allow(&cand);
                    let _ = i.session.execute("media.relink", json!({"item": id, "path": cand, "force": true}));
                }
            }
            filmcraft_engine::relink::refresh(&mut i.session);
            i.touch();
            info::media(&i.session).into_iter().filter(|m| m.offline).map(|m| m.id).collect()
        })
    }

    pub fn set_playhead(&self, at: i64) {
        self.guarded_or((), |i| {
            i.session.set_playhead(Tick(at.max(0)));
            i.touch();
        });
    }

    /// The program frame at `at` ticks fitting `max_w` x `max_h`. Rendered outside the lock.
    pub fn render_program(&self, at: i64, max_w: u32, max_h: u32) -> Result<RenderedImage, BridgeError> {
        let snap = self.snapshot()?;
        run_outside(|| render::render_program(&snap, at, max_w, max_h))
    }

    /// A project item's own picture (Source monitor) at media time `at`.
    pub fn render_source(&self, media_id: u64, at: i64, max_w: u32, max_h: u32) -> Result<RenderedImage, BridgeError> {
        let snap = self.snapshot()?;
        run_outside(|| render::render_source(&snap, media_id, at, max_w, max_h))
    }

    pub fn media_thumbnail(&self, media_id: u64, edge: u32) -> Result<RenderedImage, BridgeError> {
        let snap = self.snapshot()?;
        run_outside(|| render::media_thumbnail(&snap, media_id, edge))
    }

    /// Peak level 0...1 per bucket over the media's audio.
    pub fn audio_peaks(&self, media_id: u64, buckets: u32) -> Result<Vec<f32>, BridgeError> {
        let snap = self.snapshot()?;
        run_outside(|| render::audio_peaks(&snap, media_id, buckets))
    }

    /// The program's stereo mix, `frames` frames at `sample_rate` from tick `from`.
    pub fn mix_audio(&self, from: i64, frames: u32, sample_rate: u32) -> Result<AudioBlock, BridgeError> {
        let snap = self.snapshot()?;
        run_outside(|| render::mix_audio(&snap, from, frames, sample_rate))
    }

    /// Start `file.exportMedia` as a background job; poll `job_status`.
    pub fn start_export(&self, path: String, options_json: String) -> Result<u64, BridgeError> {
        let params = export_params(&path, &options_json)?;
        self.guarded(|i| {
            let r = run_cmd(&mut i.session, "file.exportMedia", params);
            i.touch();
            let v = r?;
            v.get("job").and_then(Value::as_u64).ok_or_else(|| fail("the export did not start a job"))
        })
    }

    pub fn job_status(&self, job_id: u64) -> Option<JobStatus> {
        self.guarded_or(None, |i| {
            let job = i.session.jobs.iter().find(|j| j.id == job_id)?;
            let result = job.result.lock().unwrap_or_else(PoisonError::into_inner).clone();
            let progress_error = job.progress.error.lock().unwrap_or_else(PoisonError::into_inner).clone();
            let finished = job.progress.finished.load(Ordering::Relaxed);
            let (done, error, output) = match &result {
                Some(Ok(r)) => (true, None, Some(r.path.clone())),
                Some(Err(e)) => (true, Some(e.clone()), None),
                None => (finished, progress_error, None),
            };
            let fraction = if matches!(result, Some(Ok(_))) { 1.0 } else { f64::from(job.progress.fraction()).clamp(0.0, 1.0) };
            Some(JobStatus { id: job.id, kind: job.label.clone(), fraction, done, error, output })
        })
    }

    pub fn cancel_job(&self, job_id: u64) {
        self.guarded_or((), |i| {
            if let Some(j) = i.session.jobs.iter().find(|j| j.id == job_id) {
                j.progress.cancel.store(true, Ordering::Relaxed);
            }
        });
    }
}

/// Every engine command with its menu placement, shortcut and params doc.
#[uniffi::export]
pub fn command_catalog() -> Vec<CommandInfo> {
    filmcraft_engine::command_specs()
        .iter()
        .map(|c| CommandInfo {
            id: c.id.to_string(),
            label: c.label.to_string(),
            menu: c.menu.iter().map(|m| (*m).to_string()).collect(),
            shortcut: c.shortcut.map(str::to_string),
            params: c.params.to_string(),
            is_query: !c.journal,
        })
        .collect()
}

/// UI-only desktop commands (views, panels, tools, playback, dialogs).
#[uniffi::export]
pub fn ui_command_catalog() -> Vec<UiCommandInfo> {
    menus_src::ui_commands()
}

/// The desktop menu bar layout.
#[uniffi::export]
pub fn desktop_menu_layout() -> Vec<MenuSection> {
    menus_src::menu_layout()
}

/// Parsed parameters of a command (empty for unknown ids and commands without params).
#[uniffi::export]
pub fn command_params(id: String) -> Vec<ParamField> {
    catch_unwind(|| params_doc::fields_for(&id)).unwrap_or_default()
}

/// `None` = supported on iOS; `Some(reason)` from `ios-excluded-commands.txt`.
#[uniffi::export]
pub fn command_platform_support(id: String) -> Option<String> {
    params_doc::excluded_commands().into_iter().find(|(e, _)| *e == id).map(|(_, reason)| reason)
}

#[uniffi::export]
pub fn timeline_tools() -> Vec<ToolInfo> {
    menus_src::tools()
}

#[uniffi::export]
pub fn panel_catalog() -> Vec<PanelInfo> {
    menus_src::panels()
}

#[uniffi::export]
pub fn ticks_per_second() -> i64 {
    filmcraft_engine::time::TICKS_PER_SECOND
}

/// `HH:MM:SS:FF` for `ticks` at the frame rate (non-drop-frame).
#[uniffi::export]
pub fn format_timecode(ticks: i64, fps_num: u32, fps_den: u32) -> String {
    catch_unwind(|| {
        let rate = FrameRate::new(i64::from(fps_num), i64::from(fps_den.max(1))).sane();
        let frame = rate.frame_at(Tick(ticks));
        filmcraft_engine::time::format_timecode_frames(frame, rate, false)
    })
    .unwrap_or_else(|_| "00:00:00:00".into())
}

#[uniffi::export]
pub fn engine_version() -> String {
    format!("filmcraft-apple {}", env!("CARGO_PKG_VERSION"))
}
