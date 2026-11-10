//! The Stage feed: what a Cast receiver running beats' `stage.js` needs to draw the deck.
//!
//! Two things, both read from the deck's lock-free mirrors (never the engine's graph):
//!
//! - **The stage project**, once per project (`generation`): the nets as `stage.js` reads them
//!   (`el._project.nets`: ids, role, riff group, track channel, places / transitions with x, y,
//!   arcs by id) built from the project's [`MarkingLayout`], the same layout the Swift Stage
//!   draws from. A full project's JSON is up to ~1.4 MB, far over a Cast message's 64 KB; this
//!   keeps only the geometry. Arcs come as centre-to-centre segments, so their endpoints are
//!   matched back to node ids by position.
//! - **Fires**, continuously: the deck's fire ring (`FireEvent`: what the engine actually
//!   played, muted nets and control nets never appear, the rule of beats' `onFire`), resolved to
//!   net / transition ids. Each batch carries in-batch timing from the audio frames, so a
//!   receiver can replay a batch's spacing exactly and only add a fixed delay.

use std::sync::Arc;

use djengine::json::{JsonObject, JsonValue};
use djengine::wave::fire::{FireEvent, FireFlags};
use djengine::wave::marking_mirror::{MarkingLayout, MarkingSnapshot};
use djhost::deck::DeckMirror;

#[derive(Debug, Clone, uniffi::Record)]
pub struct StageFire {
    pub net: String,
    pub transition: String,
    /// Milliseconds relative to the batch's newest fire (<= 0): play it this much earlier.
    pub offset_ms: f64,
    pub tick: i32,
    pub note: i16,
    pub velocity: u8,
    pub channel: u8,
    pub drum: bool,
    /// A macro (mute timer, beat repeat, tempo effect) was running when it sounded.
    pub macro_running: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct StageBatch {
    /// The project these fires belong to; a change means: fetch `stage_project` again.
    pub generation: i32,
    pub fires: Vec<StageFire>,
    /// Fires the ring overwrote before they were read (the reader fell behind).
    pub lost: u32,
    pub playing: bool,
    pub tempo: f64,
    pub tick: i64,
    /// The muted net ids, only when they changed since the last batch (or the project did).
    pub muted: Option<Vec<String>>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct StageProject {
    pub generation: i32,
    /// Which song (equal across a section jump of the same song).
    pub track_serial: i32,
    /// A beats-shaped project, JSON (`{name, tempo, nets:{…}, structure:[…]}`).
    pub json: String,
}

/// The reader's state, kept with the player.
pub struct StageReader {
    cursor: usize,
    buf: Vec<FireEvent>,
    layout: Option<Arc<MarkingLayout>>,
    snap: MarkingSnapshot,
    /// (generation, muted ids) last reported.
    last_muted: Option<(i32, Vec<String>)>,
}

impl StageReader {
    pub fn new(mirror: &DeckMirror) -> StageReader {
        StageReader {
            // from now on: the backlog is the past
            cursor: mirror.fires.written(),
            buf: Vec::with_capacity(512),
            layout: None,
            snap: MarkingSnapshot::new(),
            last_muted: None,
        }
    }

    fn layout_for(&mut self, mirror: &DeckMirror, generation: i32) -> Option<Arc<MarkingLayout>> {
        if self.layout.as_ref().map(|l| l.generation) != Some(generation) {
            self.layout = mirror.marking_layout_of(generation);
        }
        self.layout.clone()
    }

    /// Everything fired since the last call, for the current project.
    pub fn poll(&mut self, mirror: &DeckMirror, sample_rate: f64) -> StageBatch {
        self.buf.clear();
        let lost = mirror.fires.drain(&mut self.cursor, &mut self.buf);
        let generation = mirror.generation.load(std::sync::atomic::Ordering::Relaxed);
        let layout = self.layout_for(mirror, generation);
        let newest = self
            .buf
            .iter()
            .filter(|f| f.generation == generation)
            .map(|f| f.frame)
            .max()
            .unwrap_or(0);
        let mut fires = Vec::with_capacity(self.buf.len());
        if let Some(l) = layout {
            for f in self.buf.iter().filter(|f| f.generation == generation) {
                let (Ok(n), Ok(t)) = (usize::try_from(f.net), usize::try_from(f.transition)) else {
                    continue;
                };
                let Some(info) = l.nets.get(n) else { continue };
                let Some(tid) = info.transition_ids.get(t) else {
                    continue;
                };
                fires.push(StageFire {
                    net: info.id.clone(),
                    transition: tid.clone(),
                    offset_ms: (f.frame - newest) as f64 / sample_rate * 1000.0,
                    tick: f.tick,
                    note: f.note,
                    velocity: f.velocity,
                    channel: f.channel,
                    drum: f.flags.contains(FireFlags::DRUM),
                    macro_running: f.flags.contains(FireFlags::MACRO),
                });
            }
        }
        let mut muted = None;
        if mirror.read_marking_of(generation, &mut self.snap) {
            if let Some(l) = &self.snap.layout {
                let now: Vec<String> = self
                    .snap
                    .muted
                    .iter()
                    .zip(&l.net_ids)
                    .filter(|(m, _)| **m != 0)
                    .map(|(_, id)| id.clone())
                    .collect();
                let changed = self.last_muted.as_ref() != Some(&(generation, now.clone()));
                if changed {
                    self.last_muted = Some((generation, now.clone()));
                    muted = Some(now);
                }
            }
        }
        StageBatch {
            generation,
            muted,
            fires,
            lost: lost as u32,
            playing: mirror.is_playing(),
            tempo: mirror.tempo(),
            tick: mirror.tick(),
        }
    }

    /// The current project's stage geometry, or None before a project is playing.
    pub fn project(&mut self, mirror: &DeckMirror, name: &str) -> Option<StageProject> {
        let generation = mirror.generation.load(std::sync::atomic::Ordering::Relaxed);
        let l = self.layout_for(mirror, generation)?;
        Some(StageProject {
            generation,
            track_serial: l.track_serial,
            json: stage_project_json(&l, name, mirror.tempo()).js_stringified(),
        })
    }
}

/// Round to 0.01: positions are layout coordinates, and two decimals keep the JSON small.
fn r2(v: f64) -> JsonValue {
    JsonValue::Number((v * 100.0).round() / 100.0)
}

/// The id of the node whose centre is at (x, y), places first.
fn node_at<'a>(
    places: &'a [String],
    px: &[f64],
    py: &[f64],
    trans: &'a [String],
    tx: &[f64],
    ty: &[f64],
    x: f64,
    y: f64,
) -> Option<&'a str> {
    const EPS: f64 = 1e-6;
    let hit = |xs: &[f64], ys: &[f64]| {
        xs.iter()
            .zip(ys)
            .position(|(a, b)| (a - x).abs() < EPS && (b - y).abs() < EPS)
    };
    if let Some(i) = hit(px, py) {
        return places.get(i).map(String::as_str);
    }
    hit(tx, ty).and_then(|i| trans.get(i)).map(String::as_str)
}

fn stage_project_json(l: &MarkingLayout, name: &str, tempo: f64) -> JsonValue {
    let mut nets = JsonObject::new();
    for (i, n) in l.nets.iter().enumerate() {
        let place_ids: &[String] = l.place_ids.get(i).map(Vec::as_slice).unwrap_or(&[]);
        let mut net = JsonObject::new();
        let mut track = JsonObject::new();
        track.set("channel", JsonValue::int(n.channel));
        track.set("instrument", n.instrument.as_str().into());
        if let Some(g) = &n.group {
            track.set("group", g.as_str().into());
        }
        net.set("track", track.into());
        if n.role == "control" {
            net.set("role", "control".into());
        }
        if !n.riff_group.is_empty() {
            net.set("riffGroup", n.riff_group.as_str().into());
            net.set("riffVariant", n.riff_variant.as_str().into());
        }
        let mut places = JsonObject::new();
        for (j, id) in place_ids.iter().enumerate() {
            let mut p = JsonObject::new();
            p.set("x", r2(n.place_x.get(j).copied().unwrap_or(0.0)));
            p.set("y", r2(n.place_y.get(j).copied().unwrap_or(0.0)));
            places.set(id.as_str(), p.into());
        }
        net.set("places", places.into());
        let mut trans = JsonObject::new();
        for (j, id) in n.transition_ids.iter().enumerate() {
            let mut t = JsonObject::new();
            t.set("x", r2(n.transition_x.get(j).copied().unwrap_or(0.0)));
            t.set("y", r2(n.transition_y.get(j).copied().unwrap_or(0.0)));
            if n.transition_has_midi.get(j).copied().unwrap_or(false) {
                // stage.js only asks whether a transition sounds; the note comes with each fire
                let mut m = JsonObject::new();
                m.set("note", JsonValue::int(0));
                t.set("midi", m.into());
            }
            trans.set(id.as_str(), t.into());
        }
        net.set("transitions", trans.into());
        let arcs: Vec<JsonValue> = n
            .arcs
            .iter()
            .filter_map(|a| {
                let src = node_at(
                    place_ids,
                    &n.place_x,
                    &n.place_y,
                    &n.transition_ids,
                    &n.transition_x,
                    &n.transition_y,
                    a.x1,
                    a.y1,
                )?;
                let dst = node_at(
                    place_ids,
                    &n.place_x,
                    &n.place_y,
                    &n.transition_ids,
                    &n.transition_x,
                    &n.transition_y,
                    a.x2,
                    a.y2,
                )?;
                let mut o = JsonObject::new();
                o.set("source", src.into());
                o.set("target", dst.into());
                Some(o.into())
            })
            .collect();
        net.set("arcs", JsonValue::Array(arcs));
        nets.set(n.id.as_str(), net.into());
    }
    let mut r = JsonObject::new();
    r.set("name", name.into());
    r.set("tempo", tempo.into());
    r.set("nets", nets.into());
    if !l.sections.is_empty() {
        let secs = l
            .sections
            .iter()
            .map(|s| {
                let mut o = JsonObject::new();
                o.set("name", s.name.as_str().into());
                o.set("steps", JsonValue::int(s.steps));
                o.into()
            })
            .collect();
        r.set("structure", JsonValue::Array(secs));
    }
    r.into()
}
