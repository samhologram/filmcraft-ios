#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use filmcraft_apple::*;

#[test]
fn catalogs_are_loaded() {
    assert!(command_catalog().len() > 300);
    assert!(command_catalog().iter().any(|c| c.id == "edit.undo"));
    assert!(ui_command_catalog().iter().any(|c| c.id == "playback.toggle"));
    let menus = desktop_menu_layout();
    let titles: Vec<&str> = menus.iter().map(|m| m.title.as_str()).collect();
    assert_eq!(titles, ["File", "Edit", "Clip", "Sequence", "Markers", "Graphics and Titles", "View", "Window", "Help"]);
    assert!(menus.iter().all(|m| !m.items.is_empty()));
    assert!(engine_version().starts_with("filmcraft-apple"));
    assert_eq!(ticks_per_second(), 254_016_000_000);
}

#[test]
fn tools_and_panels() {
    let tools = timeline_tools();
    assert!(tools.len() >= 15);
    assert_eq!(tools.iter().find(|t| t.id == "tool.razor").and_then(|t| t.shortcut.clone()).as_deref(), Some("C"));
    let panels = panel_catalog();
    assert!(panels.iter().any(|p| p.id == "panel.timeline"));
    assert!(panels.iter().any(|p| p.id == "panel.program"));
}

#[test]
fn demo_has_content() {
    let h = ProjectHandle::demo();
    let st = h.state();
    assert!(st.media_count > 0);
    assert!(st.sequence_name.is_some());
    assert!(st.duration > 0 && st.width > 0 && st.fps_num > 0);
    assert!(!h.media().is_empty());
    let tl = h.timeline();
    assert!(tl.tracks.iter().any(|t| !t.clips.is_empty()));
}

#[test]
fn undo_redo_move_history() {
    let h = ProjectHandle::demo();
    let before = h.state();
    h.execute("file.newBin".into(), r#"{"name":"B"}"#.into()).unwrap();
    let after = h.state();
    assert_ne!(before.history_id, after.history_id);
    assert!(after.can_undo);
    assert!(h.undo().unwrap().is_some());
    let undone = h.state();
    assert_ne!(after.history_id, undone.history_id);
    assert!(undone.can_redo);
    h.redo().unwrap();
    assert!(h.state().can_undo);
}

#[test]
fn interaction_is_one_undo_step() {
    let h = ProjectHandle::demo();
    h.begin_interaction("Drag".into()).unwrap();
    h.execute("file.newBin".into(), r#"{"name":"A"}"#.into()).unwrap();
    h.execute("file.newBin".into(), r#"{"name":"B"}"#.into()).unwrap();
    h.end_interaction().unwrap();
    assert_eq!(h.state().undo_label.as_deref(), Some("Drag"));
    h.undo().unwrap();
    assert!(!h.state().can_undo);
}

#[test]
fn render_and_mix() {
    let h = ProjectHandle::demo();
    let img = h.render_program(0, 320, 180).unwrap();
    assert_eq!(img.rgba.len(), (img.width * img.height * 4) as usize);
    assert!(img.width <= 320 && img.height <= 180 && img.width > 0);
    let a = h.mix_audio(0, 1024, 48_000).unwrap();
    assert_eq!(a.samples.len(), 2048);
    let a = h.mix_audio(0, 1000, 44_100).unwrap();
    assert_eq!(a.samples.len(), 2000);
    let m = h.media();
    let v = m.iter().find(|x| x.has_video).unwrap();
    let t = h.media_thumbnail(v.id, 64).unwrap();
    assert_eq!(t.rgba.len(), (t.width * t.height * 4) as usize);
}

#[test]
fn project_json_round_trips() {
    let h = ProjectHandle::demo();
    let clips = |h: &ProjectHandle| h.timeline().tracks.iter().map(|t| t.clips.len()).sum::<usize>();
    let n = clips(&h);
    assert!(n > 0);
    let json = h.project_json().unwrap();
    let h2 = ProjectHandle::open_json(json, None).unwrap();
    assert_eq!(clips(&h2), n);
    assert!(!h2.state().can_undo && !h2.state().dirty);
}

#[test]
fn new_project_has_a_sequence() {
    let h = ProjectHandle::new_project("Test".into());
    let st = h.state();
    assert_eq!(st.project_name, "Test");
    assert!(st.sequence_name.is_some(), "{st:?}", st = st.project_name);
    assert!(!st.can_undo);
}

#[test]
fn params_and_disabled() {
    let f = command_params("file.exportMedia".into());
    assert!(f.iter().any(|x| x.key == "path"));
    assert!(command_params("nope.nothing".into()).is_empty());
    let h = ProjectHandle::new_project("T".into());
    // nothing selected: a clip command is disabled with a reason
    assert!(h.disabled_reason("edit.cut".into()).is_some());
    assert!(h.disabled_reason("no.such".into()).is_some());
}

#[test]
fn hostile_inputs_error_not_panic() {
    let h = ProjectHandle::demo();
    assert!(h.execute("no.such.command".into(), "{}".into()).is_err());
    assert!(h.execute("edit.undo".into(), "{garbage".into()).is_err());
    assert!(h.execute("timeline.trim".into(), r#"{"clip":-5,"delta":"x"}"#.into()).is_err());
    assert!(h.render_program(i64::MAX, u32::MAX, u32::MAX).is_ok() || h.render_program(i64::MAX, 100, 100).is_err());
    let _ = h.render_program(-5, 0, 0);
    assert!(h.mix_audio(i64::MIN, u32::MAX, 0).is_err());
    assert!(h.mix_audio(i64::MAX, 100, 48_000).is_ok());
    assert!(h.mix_audio(0, 0, 48_000).is_err());
    assert!(h.audio_peaks(u64::MAX, 100).is_err());
    assert!(h.audio_peaks(0, 0).is_err());
    assert!(h.render_source(u64::MAX, -1, 10, 10).is_err());
    assert!(h.media_thumbnail(u64::MAX, u32::MAX).is_err());
    assert!(ProjectHandle::open_json("not json".into(), None).is_err());
    assert!(ProjectHandle::open_json(String::new(), None).is_err());
    assert!(h.start_export(String::new(), "{}".into()).is_err());
    assert!(h.start_export("/tmp/x.mp4".into(), "[1]".into()).is_err());
    assert!(h.job_status(999).is_none());
    h.cancel_job(999);
    h.set_playhead(i64::MIN);
    h.set_playhead(i64::MAX);
    let _ = h.state();
    assert!(h.import_files(vec![]).is_err());
    assert!(h.import_files(vec!["/nonexistent/file.mp4".into()]).is_err());
    assert!(!format_timecode(i64::MIN, 0, 0).is_empty());
    assert_eq!(format_timecode(0, 24, 1), "00:00:00:00");
    let _ = h.relink_missing("/nonexistent".into());
}

#[test]
fn export_runs_to_completion() {
    let h = ProjectHandle::demo();
    let dir = std::env::temp_dir().join(format!("fc-apple-export-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let out = dir.join("out.mp4");
    let job = h.start_export(out.to_string_lossy().into_owned(), r#"{"preset":"h264","width":160,"height":90,"crf":35,"range":"all"}"#.into());
    let job = job.unwrap();
    let t0 = std::time::Instant::now();
    loop {
        let s = h.job_status(job).unwrap();
        if s.done {
            assert!(s.error.is_none(), "{:?}", s.error);
            break;
        }
        assert!(t0.elapsed().as_secs() < 300, "export too slow");
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    assert!(std::fs::metadata(&out).map(|m| m.len() > 0).unwrap_or(false));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn clip_effects_json_works() {
    let h = ProjectHandle::demo();
    let tl = h.timeline();
    let ids: Vec<u64> = tl.tracks.iter().flat_map(|t| t.clips.iter().map(|c| c.id)).collect();
    assert!(!ids.is_empty());
    for id in &ids {
        let j = h.clip_effects_json(*id).unwrap();
        let v: serde_json::Value = serde_json::from_str(&j).unwrap();
        assert!(v.is_array());
    }
    assert!(h.clip_effects_json(u64::MAX).is_err());
}
