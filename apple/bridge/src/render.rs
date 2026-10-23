//! Rendering, thumbnails, waveform peaks and audio mixing outside the session lock: the caller
//! snapshots the `Arc`s under the lock and hands them to these functions.

use std::sync::Arc;

use filmcraft_engine::media_pool::MediaPool;
use filmcraft_engine::previews::PreviewStore;
use filmcraft_engine::project::{ItemId, Project};
use filmcraft_engine::render::{RenderOptions, output_size, render_item, render_sequence};
use filmcraft_engine::time::{TICKS_PER_SECOND, Tick};
use filmcraft_engine::{Services, Session};

use crate::{AudioBlock, BridgeError, RenderedImage, fail};

pub const MAX_SIDE: u32 = 8192;
pub const MAX_AUDIO_FRAMES: u32 = 1 << 20;
pub const MAX_BUCKETS: u32 = 100_000;

/// Everything a render needs, cloned out of the session (cheap: `Arc`s).
#[derive(Clone)]
pub struct Snapshot {
    pub project: Arc<Project>,
    pub media: Arc<MediaPool>,
    pub services: Arc<dyn Services>,
    pub previews: Arc<PreviewStore>,
    pub sequence: Option<ItemId>,
}

impl Snapshot {
    pub fn of(s: &Session) -> Self {
        Snapshot {
            project: s.project.clone(),
            media: s.media.clone(),
            services: s.services.clone(),
            previews: s.previews.clone(),
            sequence: s.state.active_sequence,
        }
    }
}

fn to_image(img: &filmcraft_engine::render::Image) -> Result<RenderedImage, BridgeError> {
    let (w, h) = (u32::try_from(img.w).map_err(|_| fail("frame too large"))?, u32::try_from(img.h).map_err(|_| fail("frame too large"))?);
    let rgba = img.over_black_rgba8();
    let expect = img.w.checked_mul(img.h).and_then(|n| n.checked_mul(4)).ok_or_else(|| fail("frame too large"))?;
    if rgba.len() != expect {
        return Err(fail("the renderer returned a malformed frame"));
    }
    Ok(RenderedImage { width: w, height: h, rgba })
}

/// Scale that fits `w`x`h` into `max_w`x`max_h` (never enlarges).
fn fit_scale(w: u32, h: u32, max_w: u32, max_h: u32) -> Result<f32, BridgeError> {
    if w == 0 || h == 0 {
        return Err(fail("the picture has no size"));
    }
    let (mw, mh) = (max_w.clamp(1, MAX_SIDE), max_h.clamp(1, MAX_SIDE));
    let sx = mw as f32 / w as f32;
    let sy = mh as f32 / h as f32;
    let s = sx.min(sy).min(1.0);
    if s.is_finite() && s > 0.0 { Ok(s) } else { Err(fail("invalid render size")) }
}

pub fn render_program(snap: &Snapshot, at: i64, max_w: u32, max_h: u32) -> Result<RenderedImage, BridgeError> {
    let seq_id = snap.sequence.ok_or_else(|| fail("no sequence is open"))?;
    let seq = snap.project.sequence(seq_id).ok_or_else(|| fail("no sequence is open"))?;
    let scale = fit_scale(seq.settings.width, seq.settings.height, max_w, max_h)?;
    let (w, h) = output_size(seq, scale);
    let (w, h) = (u32::try_from(w).map_err(|_| fail("frame too large"))?, u32::try_from(h).map_err(|_| fail("frame too large"))?);
    filmcraft_engine::project::validate_frame_size(w, h).map_err(|e| fail(format!("cannot render a {w}x{h} frame: {e}")))?;
    let t = seq.settings.frame_rate.sane().snap(Tick(at.max(0)));
    let provider = snap.media.provider(snap.project.clone(), snap.services.clone());
    let opts = RenderOptions { scale, captions: true, ..Default::default() };
    to_image(&render_sequence(&snap.project, seq_id, t, opts, &provider))
}

pub fn render_source(snap: &Snapshot, media_id: u64, at: i64, max_w: u32, max_h: u32) -> Result<RenderedImage, BridgeError> {
    let item = ItemId(media_id);
    let (w, h) = snap.project.source_size(item).ok_or_else(|| fail("this item has no picture"))?;
    let scale = fit_scale(w, h, max_w, max_h)?;
    let provider = snap.media.provider(snap.project.clone(), snap.services.clone());
    let dur = snap.project.item(item).map(|i| i.duration()).unwrap_or_default();
    let t = Tick(at.max(0)).min(dur.max(Tick::ZERO));
    let img = render_item(&snap.project, item, t, scale, &provider).ok_or_else(|| fail("the item could not be rendered"))?;
    to_image(&img)
}

pub fn media_thumbnail(snap: &Snapshot, media_id: u64, edge: u32) -> Result<RenderedImage, BridgeError> {
    let item = ItemId(media_id);
    let dur = snap.project.item(item).map(|i| i.duration()).unwrap_or_default();
    // a frame a little way in: the first frame of footage is often black
    let at = if dur.0 > 2 * TICKS_PER_SECOND { dur.0 / 10 } else { 0 };
    render_source(snap, media_id, at, edge, edge)
}

pub fn audio_peaks(snap: &Snapshot, media_id: u64, buckets: u32) -> Result<Vec<f32>, BridgeError> {
    if buckets == 0 {
        return Err(fail("buckets must be positive"));
    }
    let buckets = buckets.min(MAX_BUCKETS) as usize;
    let item = ItemId(media_id);
    let src = snap.media.source_for(&snap.project, item, &*snap.services).ok_or_else(|| fail("no such media"))?;
    let info = src.info();
    let stream = info.audio_streams.first().ok_or_else(|| fail("this media has no audio"))?;
    let rate = if stream.sample_rate == 0 { 48_000 } else { stream.sample_rate };
    let total = info.duration.to_units_floor(i64::from(rate)).max(0);
    let per = (total / buckets as i64).max(1);
    let read = per.min(4096) as usize;
    let mut out = Vec::with_capacity(buckets);
    let mut failures = 0usize;
    for b in 0..buckets {
        let start = (b as i64).saturating_mul(per);
        if start >= total {
            out.push(0.0);
            continue;
        }
        let n = read.min((total - start).max(1) as usize);
        let peak = match src.audio(start, n, rate) {
            Ok(buf) => buf.channels.iter().flat_map(|c| c.iter()).fold(0.0f32, |m, v| if v.is_finite() { m.max(v.abs()) } else { m }),
            Err(_) => {
                failures += 1;
                0.0
            }
        };
        out.push(peak.min(1.0));
    }
    if failures == buckets {
        return Err(fail("the audio could not be read"));
    }
    Ok(out)
}

/// Program mix, stereo interleaved, `frames` frames at `sample_rate` starting at tick `from`.
pub fn mix_audio(snap: &Snapshot, from: i64, frames: u32, sample_rate: u32) -> Result<AudioBlock, BridgeError> {
    if frames == 0 || frames > MAX_AUDIO_FRAMES {
        return Err(fail(format!("frames must be 1..={MAX_AUDIO_FRAMES}")));
    }
    if !(8_000..=384_000).contains(&sample_rate) {
        return Err(fail("sample_rate must be 8000..=384000"));
    }
    let seq_id = snap.sequence.ok_or_else(|| fail("no sequence is open"))?;
    let seq = snap.project.sequence(seq_id).ok_or_else(|| fail("no sequence is open"))?;
    let seq_rate = seq.settings.sample_rate.clamp(8_000, 384_000);
    let silent = |n: usize| AudioBlock { sample_rate, channels: 2, samples: vec![0.0; n.saturating_mul(2)] };
    if from < 0 {
        return Ok(silent(frames as usize));
    }
    let start = Tick(from).to_units_floor(i64::from(seq_rate));
    // frames of the sequence's own rate needed for `frames` output frames (+1 for interpolation)
    let need = (u64::from(frames) * u64::from(seq_rate)).div_ceil(u64::from(sample_rate)) as usize + 1;
    let provider = snap.media.provider(snap.project.clone(), snap.services.clone());
    let buf = snap.previews.mix(&snap.project, seq_id, start, need.min(1 << 21), &provider);
    let left = buf.channels.first();
    let right = buf.channels.get(1).or(left);
    let (Some(left), Some(right)) = (left, right) else { return Ok(silent(frames as usize)) };
    let n_in = left.len().min(right.len());
    let mut samples = Vec::with_capacity(frames as usize * 2);
    let ratio = f64::from(seq_rate) / f64::from(sample_rate);
    for i in 0..frames as usize {
        let pos = i as f64 * ratio;
        let i0 = pos.floor() as usize;
        let frac = (pos - i0 as f64) as f32;
        let pick = |ch: &[f32]| -> f32 {
            let a = ch.get(i0).copied().filter(|_| i0 < n_in).unwrap_or(0.0);
            let b = ch.get(i0 + 1).copied().filter(|_| i0 + 1 < n_in).unwrap_or(a);
            let v = a + (b - a) * frac;
            if v.is_finite() { v } else { 0.0 }
        };
        samples.push(pick(left));
        samples.push(pick(right));
    }
    Ok(AudioBlock { sample_rate, channels: 2, samples })
}
