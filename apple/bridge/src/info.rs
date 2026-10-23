//! Read-only views of the session for the Swift app (state, timeline, media list). Never panics.

use filmcraft_engine::Session;
use filmcraft_engine::project::{ItemId, ItemKind, Label, MediaRef, TrackKind};
use filmcraft_media::MediaKind;

use crate::{ClipInfo, MarkerInfo, MediaInfo, ProjectState, TimelineSnapshot, TrackInfo};

fn hex(l: Label) -> String {
    let [r, g, b] = l.rgb();
    format!("#{r:02x}{g:02x}{b:02x}")
}

pub fn state(s: &Session, revision: u64, history_id: u64) -> ProjectState {
    let seq = s.active_sequence();
    let rate = s.sequence_rate().sane();
    ProjectState {
        revision,
        history_id,
        can_undo: s.history.can_undo(),
        can_redo: s.history.can_redo(),
        undo_label: s.history.undo.last().map(|e| e.0.clone()),
        redo_label: s.history.redo.last().map(|e| e.0.clone()),
        dirty: s.is_dirty(),
        project_name: s.project.name.clone(),
        sequence_name: s.state.active_sequence.and_then(|id| s.project.item(id)).map(|i| i.name.clone()),
        playhead: s.playhead().0,
        duration: seq.map(|q| q.duration().0).unwrap_or(0),
        in_point: seq.and_then(|q| q.mark_in).map(|t| t.0),
        out_point: seq.and_then(|q| q.mark_out).map(|t| t.0),
        fps_num: u32::try_from(rate.num).unwrap_or(24),
        fps_den: u32::try_from(rate.den).unwrap_or(1),
        width: seq.map(|q| q.settings.width).unwrap_or(0),
        height: seq.map(|q| q.settings.height).unwrap_or(0),
        sample_rate: seq.map(|q| q.settings.sample_rate).unwrap_or(48_000),
        selected_clips: s.state.selection.iter().map(|c| c.0).collect(),
        media_count: s.project.items.values().filter(|i| matches!(i.kind, ItemKind::Media(_))).count() as u64,
    }
}

fn clip_kind(s: &Session, item: ItemId, track: TrackKind) -> &'static str {
    match s.project.item(item).map(|i| &i.kind) {
        Some(ItemKind::Graphic { .. }) => "graphic",
        Some(ItemKind::AdjustmentLayer { .. }) => "adjustment",
        _ => match track {
            TrackKind::Video => "video",
            TrackKind::Audio => "audio",
        },
    }
}

pub fn timeline(s: &Session, revision: u64) -> TimelineSnapshot {
    let Some(seq) = s.active_sequence() else {
        return TimelineSnapshot { revision, tracks: Vec::new(), markers: Vec::new(), duration: 0 };
    };
    let mut tracks = Vec::new();
    for (kind, list) in [(TrackKind::Video, &seq.video_tracks), (TrackKind::Audio, &seq.audio_tracks)] {
        for (index, t) in list.iter().enumerate() {
            let clips = t
                .items
                .iter()
                .map(|c| {
                    let linked = match c.link {
                        Some(l) => seq.all_tracks().flat_map(|tr| tr.items.iter()).filter(|o| o.link == Some(l) && o.id != c.id).map(|o| o.id.0).collect(),
                        None => Vec::new(),
                    };
                    let media_id = match s.project.item(c.item).map(|i| &i.kind) {
                        Some(ItemKind::Media(_) | ItemKind::Sequence(_) | ItemKind::Subclip { .. }) => Some(c.item.0),
                        _ => None,
                    };
                    ClipInfo {
                        id: c.id.0,
                        track_id: t.id.0,
                        media_id,
                        name: c.name.clone(),
                        start: c.start.0,
                        end: c.start.0.saturating_add(c.duration.0),
                        source_in: c.source_in.0,
                        kind: clip_kind(s, c.item, kind).into(),
                        selected: s.state.selection.contains(&c.id),
                        enabled: c.enabled,
                        color: Some(hex(c.label)),
                        linked,
                    }
                })
                .collect();
            let video = kind == TrackKind::Video;
            tracks.push(TrackInfo {
                id: t.id.0,
                name: t.name.clone(),
                kind: if video { "video" } else { "audio" }.into(),
                index: u32::try_from(index).unwrap_or(u32::MAX),
                muted: if video { false } else { t.muted || !t.enabled },
                locked: t.locked,
                hidden: video && !t.enabled,
                solo: t.solo,
                clips,
            });
        }
    }
    let markers =
        seq.markers.iter().map(|m| MarkerInfo { id: m.id.0, at: m.start.0, duration: m.duration.0, name: m.name.clone(), color: Some(hex(m.color)) }).collect();
    TimelineSnapshot { revision, tracks, markers, duration: seq.duration().0 }
}

pub fn media(s: &Session) -> Vec<MediaInfo> {
    let mut out = Vec::new();
    for (id, item) in &s.project.items {
        let missing = s.offline.missing.contains(id);
        match &item.kind {
            ItemKind::Media(m) => {
                let kind = match m.info.kind {
                    MediaKind::Movie | MediaKind::ImageSequence => "video",
                    MediaKind::AudioOnly => "audio",
                    MediaKind::Still => "image",
                    MediaKind::Synthetic => "synthetic",
                };
                let (width, height) = m.info.video.as_ref().map(|v| (v.width, v.height)).unwrap_or((0, 0));
                out.push(MediaInfo {
                    id: id.0,
                    name: item.name.clone(),
                    path: match &m.media {
                        MediaRef::File { path } => path.clone(),
                        MediaRef::Generator(_) => String::new(),
                    },
                    kind: kind.into(),
                    duration: m.info.duration.0,
                    width,
                    height,
                    has_video: m.info.has_video(),
                    has_audio: m.info.has_audio(),
                    offline: m.offline || missing,
                });
            }
            ItemKind::Sequence(q) => out.push(MediaInfo {
                id: id.0,
                name: item.name.clone(),
                path: String::new(),
                kind: "sequence".into(),
                duration: q.duration().0,
                width: q.settings.width,
                height: q.settings.height,
                has_video: true,
                has_audio: true,
                offline: false,
            }),
            ItemKind::AdjustmentLayer { width, height, duration, .. } => out.push(MediaInfo {
                id: id.0,
                name: item.name.clone(),
                path: String::new(),
                kind: "graphic".into(),
                duration: duration.0,
                width: *width,
                height: *height,
                has_video: true,
                has_audio: false,
                offline: false,
            }),
            ItemKind::Subclip { .. } | ItemKind::Graphic { .. } => {}
        }
    }
    out
}
