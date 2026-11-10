//! djmobile: the djrust engine for the Android app: decks A and B, the mixer, the vocoder,
//! behind UniFFI.
//!
//! The same host path as `djctl play` (djrust-vevr-se `crates/djctl/src/play.rs`): open the
//! output, build the engine at its rate (`host_engine`), start the stream, then service the
//! engine every ~10 ms (`Rig::tick`). Composes run on workers through `ComposeJobs`, as the
//! desktop app's Compose button does, so a call from the UI never waits on one.
//!
//! Threads:
//! - the audio owner: opens the device, builds the engine, starts the stream, then holds the
//!   stream (cpal's stream need not be `Send`) until [`Player::shutdown`];
//! - the ticker: services the engine every 10 ms;
//! - callers (Kotlin): every method takes the engine's lock briefly and never blocks on audio.
//!
//! Every deck call names its deck, "A" or "B" (anything else is refused).

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use djengine::fx::vocoder::VocoderParam;
use djengine::session::action::DeckAction;
use djengine::TrackSpec;
use djhost::deck::vocoder::{CarrierPick, ModulatorPick, VocoderSwitch};
use djhost::deck::{ComposeJobs, DeckMirror, Landed, PerformCtx, Rig};

#[cfg(target_os = "android")]
mod android;
mod chords;
mod fx;
mod heos;
mod level;
mod stage;
mod td3;
mod voc_presets;

pub use chords::{ChordPad, ChordSet};
pub use heos::{HeosGroup, HeosState, HeosZone};
pub use stage::{StageBatch, StageFire, StageProject};
pub use td3::Td3Loop;
pub use voc_presets::VocoderPreset;

uniffi::setup_scaffolding!();

/// The decks, in mixer order.
const DECKS: [&str; 2] = ["A", "B"];
/// A bar is 16 ticks (sixteenth notes) in every beats structure.
const TICKS_PER_BAR: i64 = 16;
/// How many played tracks back can go, per deck.
const HISTORY: usize = 50;

/// What an offline render of the engine measured (no audio device involved).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct RenderStats {
    pub frames: u64,
    pub sample_rate: u32,
    pub tempo: f64,
    pub title: String,
    /// Largest |sample| over both channels.
    pub peak: f32,
    pub rms: f32,
    /// Share of frames that were not digital silence.
    pub active: f32,
    /// FNV-1a of the rendered samples (bit-exact repeatability check).
    pub checksum: u64,
}

/// Compose `genre`/`seed` and render `seconds` of deck A through the engine's own mixer, offline
/// (the renderer the CoreAudio callback calls, driven by hand). Deterministic: the same inputs
/// give the same `checksum`. This is the smoke test that needs no sound card.
#[uniffi::export]
pub fn render_offline(
    genre: String,
    seed: i64,
    seconds: f64,
    sample_rate: u32,
) -> Result<RenderStats, DjError> {
    use djhost::deck::offline::OfflineConductor;
    if !genres().contains(&genre) {
        return Err(DjError::Spec(format!("unknown genre {genre}")));
    }
    let spec = TrackSpec::parse(&format!("{genre}:{seed}")).map_err(|e| DjError::Spec(format!("{e:?}")))?;
    let mut cfg = djhost::deck::EngineConfig::new(sample_rate as f64);
    cfg.history_beats = None;
    let (mut e, renderer) = djhost::deck::host_engine(cfg, false, true);
    e.set_crossfader(0.0);
    let mut jobs = ComposeJobs::new();
    jobs.ask(&e, "A", spec.clone());
    let mut landed = false;
    for _ in 0..4000 {
        for l in jobs.poll(&mut e) {
            landed |= matches!(l.landed, Landed::Loaded(_));
        }
        if landed {
            break;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    if !landed {
        return Err(DjError::Spec("the compose made no track".into()));
    }
    e.perform(&DeckAction::Play { deck: "A".into(), on: true }, PerformCtx::default());
    let mut c = OfflineConductor::new(e, renderer);
    let target = (seconds * sample_rate as f64) as i64;
    let (mut peak, mut sq, mut active, mut n) = (0f32, 0f64, 0u64, 0u64);
    let mut sum = 0xcbf29ce484222325u64;
    while c.engine().frame() < target {
        let (l, r) = c.step_block();
        for (a, b) in l.iter().zip(r.iter()) {
            peak = peak.max(a.abs()).max(b.abs());
            sq += (*a as f64).powi(2) + (*b as f64).powi(2);
            if *a != 0.0 || *b != 0.0 {
                active += 1;
            }
            for v in [a, b] {
                for byte in v.to_bits().to_le_bytes() {
                    sum = (sum ^ byte as u64).wrapping_mul(0x100000001b3);
                }
            }
            n += 1;
        }
    }
    let d = c.engine().deck("A").ok_or(DjError::Closed)?;
    Ok(RenderStats {
        frames: n,
        sample_rate,
        tempo: d.mirror.tempo(),
        title: djengine::gen::generate_track_name(&genre, seed as f64),
        peak,
        rms: if n > 0 { (sq / (2 * n) as f64).sqrt() as f32 } else { 0.0 },
        active: if n > 0 { active as f32 / n as f32 } else { 0.0 },
        checksum: sum,
    })
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum DjError {
    #[error("audio: {0}")]
    Audio(String),
    #[error("bad track: {0}")]
    Spec(String),
    #[error("no deck {0} (A or B)")]
    NoDeck(String),
    #[error("vocoder: {0}")]
    Vocoder(String),
    #[error("HEOS: {0}")]
    Heos(String),
    #[error("the player has shut down")]
    Closed,
}

/// A palette: the set of sounds a track plays with.
#[derive(Debug, Clone, uniffi::Record)]
pub struct Palette {
    pub id: String,
    pub label: String,
    pub description: String,
    /// Why it can't play here (no SoundFont bank, …); None when it can.
    pub unavailable: Option<String>,
    pub selected: bool,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Section {
    pub name: String,
    pub start_tick: i64,
    pub ticks: i64,
}

/// A role of the song on a deck (kick, bass, lead, …), as the desktop mixer's role row.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct RoleState {
    pub name: String,
    /// Making sound now (not paused, and the song's section has it in).
    pub audible: bool,
    /// Locked out: muted now and left out of every track this deck loads until let back in.
    pub disabled: bool,
}

/// What the UI draws for one deck, read in one go.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DeckState {
    pub deck: String,
    pub loaded: bool,
    pub playing: bool,
    pub composing: bool,
    pub genre: Option<String>,
    pub seed: Option<i64>,
    /// None: an endless loop.
    pub structure: Option<String>,
    /// "Solar Colimit".
    pub title: Option<String>,
    pub tempo: f64,
    pub base_tempo: f64,
    /// -1..1 of `pitch_range`.
    pub pitch: f64,
    pub pitch_range: f64,
    pub volume: f64,
    pub tick: i64,
    /// `tick` plus the fraction of it played (the mirror's tick phase, per audio block): the
    /// playhead the UI draws and extrapolates between polls.
    pub position: f64,
    pub total_ticks: i64,
    pub bar: i64,
    pub total_bars: i64,
    pub section: Option<String>,
    pub sections: Vec<Section>,
    /// The deck's peak, 0..1.
    pub level: f32,
    pub palette: String,
    /// The last thing that went wrong (a compose that made no track, …).
    pub message: Option<String>,
    /// Auto-next every N bars (djrust docs/AUTO-NEXT.md): on, N, and bars left counting the
    /// one playing (None while it is off or not counting: stopped, nothing composed).
    pub auto_next_on: bool,
    pub auto_next_bars: u32,
    pub auto_next_left: Option<u32>,
    /// The seed the deck is composing to (an auto-next step or a Compose on its way in).
    pub next_seed: Option<i64>,
    /// At a song's end, play its next version (the next generated seed, Swift's
    /// `autoAdvance`): the engine keeps it composed while the song plays.
    pub auto_advance: bool,
    /// The seed [`Player::next_track`] plays: the next version's (None before a track).
    pub next_version_seed: Option<i64>,
    /// A track played before this one, for [`Player::previous_track`].
    pub has_previous: bool,
    /// The song's roles in mixer order (empty before a track).
    pub roles: Vec<RoleState>,
    /// The TD-3 loop on the deck ("1A"), None for a composed track.
    pub td3: Option<String>,
    /// What auto level does to the deck now, dB (0 while it is off).
    pub auto_gain_db: f64,
}

/// The mixer.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct MixState {
    /// 0 = all A, 1 = all B.
    pub crossfader: f64,
    pub master_level: f32,
    /// Auto level: decks A and B kept at the same loudness (each deck's trim, ±6 dB).
    pub auto_level: bool,
}

/// The vocoder as the phone plays it: the internal synth (three oscillators a voice) is the
/// carrier, a deck the modulator (its rhythm and timbre shape the synth: "talking drums").
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct VocoderState {
    pub on: bool,
    /// The deck shaping the synth (None: off).
    pub modulator: Option<String>,
    /// The notes the synth holds.
    pub notes: Vec<u8>,
    /// Levels 0..1: what comes in from the modulator, the carrier, and out.
    pub modulator_level: f32,
    pub carrier_level: f32,
    pub out_level: f32,
    /// The knobs the phone shows, in their own units (see [`Player::vocoder_set`]).
    pub knobs: Vec<VocoderKnob>,
    /// The sound last loaded ([`Player::vocoder_preset`]), and whether a knob moved since.
    pub preset: Option<String>,
    pub edited: bool,
    /// Auto level: the vocoder's level kept with the decks' (the Level knob sets it around
    /// that), and what it does now, dB.
    pub auto_level: bool,
    pub auto_gain_db: f64,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct VocoderKnob {
    /// The param's name (`djengine::fx::vocoder::VocoderParam`): "cutoff", "mix", …
    pub name: String,
    pub value: f64,
    pub min: f64,
    pub max: f64,
}

/// The vocoder knobs the phone shows: the vocoder's (five up front, the rest under "More"), then
/// the synth's three oscillators and its filter and gate, as the desktop's Vocoder window has them.
const PHONE_KNOBS: [VocoderParam; 33] = [
    VocoderParam::Mix,
    VocoderParam::Volume,
    VocoderParam::Cutoff,
    VocoderParam::Shift,
    VocoderParam::Release,
    VocoderParam::Resonance,
    VocoderParam::SynthDetune,
    VocoderParam::Drift,
    VocoderParam::Bands,
    VocoderParam::Attack,
    VocoderParam::Noise,
    VocoderParam::Vowel,
    VocoderParam::VowelMix,
    VocoderParam::SynthLevel,
    VocoderParam::Osc1Wave,
    VocoderParam::Osc1Oct,
    VocoderParam::Osc1Fine,
    VocoderParam::Osc1Level,
    VocoderParam::Osc2Wave,
    VocoderParam::Osc2Oct,
    VocoderParam::Osc2Fine,
    VocoderParam::Osc2Level,
    VocoderParam::Osc3Wave,
    VocoderParam::Osc3Oct,
    VocoderParam::Osc3Fine,
    VocoderParam::Osc3Level,
    VocoderParam::Pwm,
    VocoderParam::Sync,
    VocoderParam::Ring,
    VocoderParam::EnvAmount,
    VocoderParam::EnvDecay,
    VocoderParam::SynthAttack,
    VocoderParam::SynthRelease,
];

#[derive(Debug, Clone, uniffi::Record)]
pub struct EngineInfo {
    pub sample_rate: u32,
    pub sound_fonts: u32,
    pub local_only_banks: u32,
}

/// The genres beats composes, sorted.
#[uniffi::export]
pub fn genres() -> Vec<String> {
    djengine::gen::BeatsTables::shared()
        .genres
        .keys()
        .cloned()
        .collect()
}

/// The structures a compose takes; "loop" means none (an endless loop).
#[uniffi::export]
pub fn structures() -> Vec<String> {
    ["loop", "minimal", "standard", "extended"]
        .iter()
        .map(|s| s.to_string())
        .collect()
}

/// The track's generated name for a genre and seed ("Solar Colimit").
#[uniffi::export]
pub fn track_title(genre: String, seed: i64) -> String {
    djengine::gen::generate_track_name(&genre, seed as f64)
}

/// The vocoder's chord pads in a genre's key: its seven triads, i to vii.
#[uniffi::export]
pub fn chord_pads(genre: String) -> ChordSet {
    chords::chords_for_genre(&genre)
}

/// The vocoder's sounds: one tap sets the synth and the vocoder's knobs (not the level).
#[uniffi::export]
pub fn vocoder_presets() -> Vec<VocoderPreset> {
    voc_presets::list()
}

/// The TD-3 loops: four groups of an A and a B pattern, one bar each.
#[uniffi::export]
pub fn td3_loops() -> Vec<Td3Loop> {
    td3::bank()
}

/// One deck's back-and-forth through the tracks it played.
#[derive(Default)]
struct Hist {
    /// The tracks played before this one, newest last.
    played: Vec<TrackSpec>,
    /// The track on the deck at the last tick, to notice a new one.
    on_deck: Option<TrackSpec>,
    /// The next new track came from going back: do not push the one it replaces.
    going_back: bool,
}

struct Inner {
    rig: Rig,
    jobs: ComposeJobs,
    messages: HashMap<String, String>,
    info: EngineInfo,
    stage: Option<(String, stage::StageReader)>,
    hist: HashMap<String, Hist>,
    /// The deck the vocoder's modulator is (None: the vocoder is off).
    vocoder_mod: Option<String>,
    /// Auto level on the decks, each deck's leveller (in [`DECKS`] order) and the trim last sent.
    auto_level: bool,
    levelers: [level::Leveler; 2],
    gain_sent: [f64; 2],
    /// Auto level on the vocoder, its leveller, and the level the user set (the engine's
    /// `volume` is this times the leveller's gain).
    voc_auto: bool,
    voc_leveler: level::Leveler,
    voc_volume: f64,
    /// The sound last loaded, and a knob moved since.
    voc_preset: Option<String>,
    voc_edited: bool,
    /// The TD-3 loop on each deck (cleared when a composed track lands).
    td3: HashMap<String, String>,
    /// The ticker's time at the last level step, seconds.
    level_t: f64,
}

impl Inner {
    /// A new track on a deck (any way: auto-next, Compose, next, back): the one it replaced goes
    /// on that deck's history, unless we are going back through it.
    fn note_tracks(&mut self) {
        for deck in DECKS {
            let now = self.rig.engine.deck(deck).and_then(|d| d.spec.clone());
            let h = self.hist.entry(deck.to_string()).or_default();
            if now == h.on_deck {
                continue;
            }
            if now.is_some() {
                self.td3.remove(deck);
            }
            if let Some(i) = DECKS.iter().position(|d| *d == deck) {
                self.levelers[i].relearn();
            }
            if let Some(prev) = h.on_deck.take() {
                if !std::mem::take(&mut h.going_back) {
                    h.played.push(prev);
                    if h.played.len() > HISTORY {
                        h.played.remove(0);
                    }
                }
            }
            h.on_deck = now;
        }
    }

    fn hist(&mut self, deck: &str) -> &mut Hist {
        self.hist.entry(deck.to_string()).or_default()
    }

    /// Auto level, every tick: each deck's trim and the vocoder's level walked toward the
    /// shared target (see `level.rs`); off, back to unity and the user's level.
    fn level(&mut self, now: f64) {
        let dt = (now - self.level_t).clamp(0.0, 0.1);
        self.level_t = now;
        for (i, deck) in DECKS.iter().enumerate() {
            let Some(d) = self.rig.engine.deck(deck) else {
                continue;
            };
            let (peak, playing) = (d.mirror.level(), d.mirror.is_playing());
            let l = &mut self.levelers[i];
            let g = if self.auto_level {
                l.step(peak, dt, playing, &level::DECKS)
            } else {
                l.reset();
                0.0
            };
            let param = level::deck_gain_param(g);
            if (param - self.gain_sent[i]).abs() > 0.002 {
                self.rig.engine.set_gain(deck, param);
                self.gain_sent[i] = param;
            }
        }
        let v = &self.rig.engine.vocoder;
        let active = v.settings.on && !v.notes.is_empty();
        let now_vol = v.settings.volume;
        let out = v.mirror.levels().2 as f64;
        let raw = if now_vol > 1e-3 { out / now_vol } else { 0.0 };
        let g = if self.voc_auto {
            self.voc_leveler.step(raw as f32, dt, active, &level::VOCODER)
        } else {
            self.voc_leveler.reset();
            0.0
        };
        let want = (self.voc_volume * level::lin(g)).clamp(0.0, 1.0);
        if (want - now_vol).abs() > 0.002 {
            self.rig.engine.vocoder_set(VocoderParam::Volume, want);
        }
    }

    fn deck_index(deck: &str) -> usize {
        DECKS.iter().position(|d| *d == deck).unwrap_or(0)
    }

    /// Load a TD-3 loop on `deck` and play it, on the bar with the other deck when that one
    /// plays (`with`: sync to it).
    fn load_td3(&mut self, deck: &'static str, proj: &djengine::pflow::Project, id: &str, with: bool) -> Result<(), DjError> {
        if !self.rig.engine.load(deck, proj, 303.0) {
            return Err(DjError::Spec(format!("the TD-3 loop {id} did not load")));
        }
        self.td3.insert(deck.to_string(), id.to_string());
        self.messages.remove(deck);
        self.levelers[Self::deck_index(deck)].relearn();
        let e = &mut self.rig.engine;
        e.perform(&DeckAction::Play { deck: deck.into(), on: true }, PerformCtx::default());
        if with {
            e.perform(
                &DeckAction::Sync {
                    deck: deck.into(),
                    align: "bar".into(),
                },
                PerformCtx::default(),
            );
        }
        Ok(())
    }
}

fn deck_name(deck: &str) -> Result<&'static str, DjError> {
    DECKS
        .iter()
        .find(|d| d.eq_ignore_ascii_case(deck))
        .copied()
        .ok_or_else(|| DjError::NoDeck(deck.to_string()))
}

#[derive(uniffi::Object)]
pub struct Player {
    inner: Arc<Mutex<Inner>>,
    /// HEOS: its own lock (the network is never waited on under the engine's).
    heos: Mutex<Option<heos::HeosSide>>,
    stop: Arc<AtomicBool>,
    threads: Mutex<Vec<JoinHandle<()>>>,
}

#[uniffi::export]
impl Player {
    /// Open the default output, load the SoundFonts in `soundfont_dir` (an app files folder;
    /// missing is fine: synth voices), build the engine and start the stream. The crossfader
    /// starts all the way to A.
    #[uniffi::constructor]
    pub fn new(soundfont_dir: String) -> Result<Arc<Player>, DjError> {
        let stop = Arc::new(AtomicBool::new(false));
        let (tx, rx) = mpsc::channel::<Result<(Rig, EngineInfo), String>>();
        let audio_stop = stop.clone();
        let audio = std::thread::Builder::new()
            .name("djmobile-audio".into())
            .spawn(move || {
                let started = (|| {
                    // DJ_AUDIO_DEVICE: a device-name substring (macOS dev/smoke use; the default otherwise)
                    let want = std::env::var("DJ_AUDIO_DEVICE").ok().filter(|s| !s.is_empty());
                    let out = djhost::audio::Output::open(want.as_deref(), None).map_err(|e| e.to_string())?;
                    let sr = out.sample_rate();
                    let mut cfg = djhost::deck::EngineConfig::new(sr as f64);
                    // no history loop or freeze on a phone: saves its buffers
                    cfg.history_beats = None;
                    let found = djhost::sampler::Library::scan(std::path::Path::new(&soundfont_dir))
                        .for_host();
                    let info = EngineInfo {
                        sample_rate: sr,
                        sound_fonts: found.sound_fonts as u32,
                        local_only_banks: found.local_only as u32,
                    };
                    cfg.library = found.library;
                    let (mut e, renderer) = djhost::deck::host_engine(cfg, true, true);
                    e.set_crossfader(0.0);
                    let running = out
                        .start(renderer, djhost::deck::output::Routing::Stereo, None)
                        .map_err(|e| e.to_string())?;
                    Ok((Rig::new(e), info, running))
                })();
                match started {
                    Err(why) => {
                        let _ = tx.send(Err(why));
                    }
                    Ok((rig, info, running)) => {
                        let _ = tx.send(Ok((rig, info)));
                        while !audio_stop.load(Ordering::Relaxed) {
                            std::thread::park_timeout(Duration::from_millis(200));
                        }
                        drop(running);
                    }
                }
            })
            .map_err(|e| DjError::Audio(e.to_string()))?;
        let (rig, info) = rx
            .recv()
            .map_err(|_| DjError::Audio("the audio thread died".into()))?
            .map_err(DjError::Audio)?;
        let inner = Arc::new(Mutex::new(Inner {
            rig,
            jobs: ComposeJobs::new(),
            messages: HashMap::new(),
            info,
            stage: None,
            hist: HashMap::new(),
            vocoder_mod: None,
            auto_level: true,
            levelers: Default::default(),
            gain_sent: [0.5; 2],
            voc_auto: true,
            voc_leveler: Default::default(),
            voc_volume: djengine::fx::vocoder::VocoderSettings::default().volume,
            voc_preset: None,
            voc_edited: false,
            td3: HashMap::new(),
            level_t: 0.0,
        }));
        let tick_inner = inner.clone();
        let tick_stop = stop.clone();
        let ticker = std::thread::Builder::new()
            .name("djmobile-tick".into())
            .spawn(move || {
                let t0 = Instant::now();
                let mut last_drain = Instant::now();
                while !tick_stop.load(Ordering::Relaxed) {
                    if let Ok(mut g) = tick_inner.lock() {
                        let g = &mut *g;
                        g.rig.recorded.clear();
                        let now = t0.elapsed().as_secs_f64();
                        g.rig.tick(now);
                        g.note_tracks();
                        g.level(now);
                        for landing in g.jobs.poll(&mut g.rig.engine) {
                            let why = match landing.landed {
                                Landed::Loaded(_) | Landed::Superseded | Landed::Pending => None,
                                Landed::NotComposed => Some(format!(
                                    "{} {} made no track",
                                    landing.spec.genre, landing.spec.seed
                                )),
                                Landed::Lost => Some("the compose crashed".into()),
                            };
                            if let Some(why) = why {
                                g.messages.insert(landing.deck.clone(), why);
                            }
                        }
                        if last_drain.elapsed() >= Duration::from_secs(1) {
                            last_drain = Instant::now();
                            g.rig.engine.drain_retired();
                        }
                    }
                    std::thread::sleep(Duration::from_millis(10));
                }
            })
            .map_err(|e| DjError::Audio(e.to_string()))?;
        Ok(Arc::new(Player {
            inner,
            heos: Mutex::new(None),
            stop,
            threads: Mutex::new(vec![audio, ticker]),
        }))
    }

    pub fn info(&self) -> EngineInfo {
        self.lock().map(|g| g.info.clone()).unwrap_or(EngineInfo {
            sample_rate: 0,
            sound_fonts: 0,
            local_only_banks: 0,
        })
    }

    // MARK: a deck

    /// Compose `genre` / `seed` / `structure` ("loop" or None: endless) and load it on `deck`
    /// when it is ready; the deck keeps playing what it has until then.
    pub fn compose(
        &self,
        deck: String,
        genre: String,
        seed: i64,
        structure: Option<String>,
    ) -> Result<bool, DjError> {
        let deck = deck_name(&deck)?;
        if !genres().contains(&genre) {
            return Err(DjError::Spec(format!("unknown genre {genre}")));
        }
        let structure = structure.filter(|s| !s.is_empty() && s != "loop");
        let text = match &structure {
            Some(s) => format!("{genre}:{seed}:{s}"),
            None => format!("{genre}:{seed}"),
        };
        let spec = TrackSpec::parse(&text).map_err(|e| DjError::Spec(format!("{e:?}")))?;
        let mut g = self.lock()?;
        g.messages.remove(deck);
        g.hist(deck).going_back = false;
        let g = &mut *g;
        Ok(g.jobs.ask(&g.rig.engine, deck, spec))
    }

    pub fn set_playing(&self, deck: String, on: bool) -> Result<(), DjError> {
        let deck = deck_name(&deck)?;
        self.perform(DeckAction::Play {
            deck: deck.into(),
            on,
        })
    }

    /// The tempo fader: -1..1 of the pitch range.
    pub fn set_pitch(&self, deck: String, pitch: f64) -> Result<(), DjError> {
        self.param(&deck, "pitch", pitch.clamp(-1.0, 1.0))
    }

    /// The pitch fader's range: 0.08, 0.16, 0.5.
    pub fn set_pitch_range(&self, deck: String, range: f64) -> Result<(), DjError> {
        let deck = deck_name(&deck)?;
        self.lock()?.rig.engine.set_pitch_range(deck, range);
        Ok(())
    }

    pub fn set_volume(&self, deck: String, volume: f64) -> Result<(), DjError> {
        self.param(&deck, "volume", volume.clamp(0.0, 1.0))
    }

    /// None or "studio": the default sounds.
    pub fn set_palette(&self, deck: String, palette: Option<String>) -> Result<(), DjError> {
        let deck = deck_name(&deck)?;
        self.perform(DeckAction::SetPalette {
            deck: deck.into(),
            palette: palette.filter(|p| p != "studio"),
        })
    }

    /// The palettes for the track on `deck` (empty until one is loaded).
    pub fn palettes(&self, deck: String) -> Vec<Palette> {
        let (Ok(deck), Ok(g)) = (deck_name(&deck), self.lock()) else {
            return Vec::new();
        };
        g.rig
            .engine
            .palette_cards(deck)
            .into_iter()
            .map(|c| Palette {
                id: c.id,
                label: c.label,
                description: c.description,
                unavailable: c.unavailable,
                selected: c.selected,
            })
            .collect()
    }

    pub fn state(&self, deck: String) -> Result<DeckState, DjError> {
        let deck = deck_name(&deck)?;
        let g = self.lock()?;
        let e = &g.rig.engine;
        let composing = g.jobs.is_composing(deck);
        let Some(d) = e.deck(deck) else {
            return Err(DjError::Closed);
        };
        let sections: Vec<Section> = d
            .sections
            .iter()
            .map(|s| Section {
                name: s.name.clone(),
                start_tick: s.start_tick,
                ticks: s.steps,
            })
            .collect();
        let total_ticks = sections
            .iter()
            .map(|s| s.start_tick + s.ticks)
            .max()
            .unwrap_or(0);
        let tick = d.mirror.tick();
        let phase = d.mirror.tick_phase().clamp(0.0, 1.0);
        let spec = d.spec.as_ref();
        let roles = e
            .roles(deck)
            .into_iter()
            .map(|r| RoleState {
                audible: e.is_role_audible(deck, &r),
                disabled: e.is_role_disabled(deck, &r),
                name: r,
            })
            .collect();
        Ok(DeckState {
            deck: deck.to_string(),
            loaded: d.project.is_some(),
            playing: d.mirror.is_playing(),
            composing,
            // a TD-3 loop is in the acid genre's key: the vocoder's pads take it
            genre: spec
                .map(|s| s.genre.clone())
                .or_else(|| g.td3.contains_key(deck).then(|| "acid".to_string())),
            seed: spec.map(|s| s.seed as i64),
            structure: spec.and_then(|s| s.structure.clone()),
            title: spec
                .map(|s| djengine::gen::generate_track_name(&s.genre, s.seed))
                .or_else(|| {
                    let id = g.td3.get(deck)?;
                    let l = td3::bank().into_iter().find(|l| &l.id == id)?;
                    Some(format!("TD-3 {} · {}", l.id, l.name))
                }),
            tempo: d.mirror.tempo(),
            base_tempo: d.base_tempo,
            pitch: d.pitch,
            pitch_range: d.pitch_range,
            volume: d.volume,
            tick,
            position: tick as f64 + if d.mirror.is_playing() { phase } else { 0.0 },
            total_ticks,
            bar: tick.max(0) / TICKS_PER_BAR + 1,
            total_bars: total_ticks / TICKS_PER_BAR,
            section: e
                .current_section(deck)
                .and_then(|i| d.sections.get(i))
                .map(|s| s.name.clone()),
            sections,
            level: d.mirror.level(),
            palette: e.palette(deck).unwrap_or_else(|| "studio".into()),
            message: g.messages.get(deck).cloned(),
            auto_next_on: d.bar_next.on,
            auto_next_bars: d.bar_next.bars,
            auto_next_left: e.bar_next_left(deck),
            next_seed: d.track.seed_target.as_ref().map(|s| s.seed as i64),
            auto_advance: d.auto_advance,
            next_version_seed: spec.map(|s| s.next_version().seed as i64),
            has_previous: g.hist.get(deck).is_some_and(|h| !h.played.is_empty()),
            roles,
            td3: g.td3.get(deck).cloned().filter(|_| spec.is_none()),
            auto_gain_db: if g.auto_level {
                g.levelers[Inner::deck_index(deck)].gain_db()
            } else {
                0.0
            },
        })
    }

    /// Auto-next every N bars, the desktop's (djhost `Engine::set_bar_next`): on the line that
    /// starts the run's last bar the deck steps to seed + 1 on the same song settings, composed
    /// and swapped in on the N-bar line (a loop from its top). `bars` is clamped to 1..=1024.
    pub fn set_auto_next(&self, deck: String, on: bool, bars: u32) -> Result<(), DjError> {
        let deck = deck_name(&deck)?;
        self.lock()?
            .rig
            .engine
            .set_bar_next(deck, Some(on), Some(bars as i64))
            .map_err(DjError::Spec)
    }

    /// At a song's end, play its next version: the next generated seed on the same genre,
    /// structure and sound (djhost `MainDeck::auto_advance`, Swift's `autoAdvance`). On, the
    /// engine keeps that version composed while the song plays, so the hand-over is seamless
    /// and [`next_track`](Self::next_track) is instant. A loop never ends: only next uses it.
    pub fn set_auto_advance(&self, deck: String, on: bool) -> Result<(), DjError> {
        let deck = deck_name(&deck)?;
        self.perform(DeckAction::AutoAdvance {
            deck: deck.into(),
            on,
        })
    }

    /// Skip to the next version now (the media controls' next): the composed one if the
    /// engine has it ready, else composed now and loaded when ready. Keeps playing if it was.
    /// False with nothing on the deck.
    pub fn next_track(&self, deck: String) -> Result<bool, DjError> {
        let deck = deck_name(&deck)?;
        let mut g = self.lock()?;
        let g = &mut *g;
        g.hist(deck).going_back = false;
        let Some(d) = g.rig.engine.deck(deck) else {
            return Err(DjError::Closed);
        };
        let Some(spec) = d.spec.clone() else {
            return Ok(false);
        };
        let want = spec.next_version();
        if d.track.next.ready_spec() == Some(&want) {
            g.rig.engine.perform(
                &DeckAction::NextTrack { deck: deck.into() },
                PerformCtx::default(),
            );
            return Ok(true);
        }
        Ok(g.jobs.ask(&g.rig.engine, deck, want))
    }

    /// The track played before this one (the media controls' previous, past the first
    /// seconds): composed again and loaded when ready. False when there is none.
    pub fn previous_track(&self, deck: String) -> Result<bool, DjError> {
        let deck = deck_name(&deck)?;
        let mut g = self.lock()?;
        let g = &mut *g;
        let h = g.hist(deck);
        let Some(spec) = h.played.pop() else {
            return Ok(false);
        };
        h.going_back = true;
        Ok(g.jobs.ask(&g.rig.engine, deck, spec))
    }

    /// Back to the top of the song (its first section). A loop has no sections: nothing.
    pub fn restart(&self, deck: String) -> Result<(), DjError> {
        let deck = deck_name(&deck)?;
        self.perform(DeckAction::Section {
            deck: deck.into(),
            index: 0,
        })
    }

    // MARK: roles

    /// Pause a role (or let it play again) on the song now, as the desktop's role button. A
    /// locked-out role stays off.
    pub fn set_role(&self, deck: String, role: String, on: bool) -> Result<(), DjError> {
        let deck = deck_name(&deck)?;
        self.perform(DeckAction::Role {
            deck: deck.into(),
            role,
            on,
        })
    }

    /// Lock a role out (muted now, and left out of every track this deck loads from now on)
    /// or let it back in.
    pub fn set_role_disabled(&self, deck: String, role: String, disabled: bool) -> Result<(), DjError> {
        let deck = deck_name(&deck)?;
        self.perform(DeckAction::RoleDisable {
            deck: deck.into(),
            role,
            on: disabled,
        })
    }

    // MARK: tricks and macros

    /// The ids of the performance tricks, in the desktop's order.
    pub fn trick_ids(&self) -> Vec<String> {
        fx::trick_ids()
    }

    /// Every macro: the song's own (net), the master FX ones and the pan / shape / aux ones.
    pub fn macro_catalogue(&self) -> Vec<fx::MacroInfo> {
        fx::catalogue()
    }

    /// Fire a trick on (held) or off on `deck`, landing on the deck's own grid.
    pub fn trick(&self, deck: String, kind: String, on: bool) -> Result<(), DjError> {
        let deck = deck_name(&deck)?;
        let k = fx::parse_trick(&kind).ok_or_else(|| DjError::Vocoder(format!("no trick {kind}")))?;
        self.lock()?
            .rig
            .engine
            .trick(deck, k, on, None, fx::quant())
            .map_err(DjError::Vocoder)
    }

    /// The filter's knob under a hand: 0 low-pass all the way, 0.5 open, 1 high-pass all the way.
    pub fn trick_knob(&self, deck: String, v: f64) -> Result<(), DjError> {
        let deck = deck_name(&deck)?;
        self.lock()?
            .rig
            .engine
            .trick_knob(deck, djengine::fx::tricks::TrickKind::Filter, v)
            .map(|_| ())
            .map_err(DjError::Vocoder)
    }

    /// The tricks now on, as "deck:kind" ("A:stutter").
    pub fn tricks_on(&self) -> Result<Vec<String>, DjError> {
        let g = self.lock()?;
        let mut on = Vec::new();
        for d in ["A", "B"] {
            for k in fx::TRICKS {
                if g.rig.engine.trick_on(d, k) {
                    on.push(format!("{d}:{}", k.name()));
                }
            }
        }
        Ok(on)
    }

    /// Fire a macro on `deck` (for `bars` bars, or its own length), as `deck macro` on the desktop.
    pub fn fire_macro(&self, deck: String, id: String, bars: Option<i32>) -> Result<bool, DjError> {
        let deck = deck_name(&deck)?;
        Ok(self.lock()?.rig.engine.fire_macro_traced(deck, &id, bars))
    }

    /// PANIC: end `deck`'s macros and tricks (the aux ones too).
    pub fn panic(&self, deck: String) -> Result<(), DjError> {
        let deck = deck_name(&deck)?;
        let mut g = self.lock()?;
        g.rig.engine.panic(deck);
        g.rig.engine.cancel_aux_macros(None);
        Ok(())
    }

    // MARK: the mixer

    pub fn mix(&self) -> Result<MixState, DjError> {
        let g = self.lock()?;
        Ok(MixState {
            crossfader: g.rig.engine.crossfader,
            master_level: g.rig.engine.master_level(),
            auto_level: g.auto_level,
        })
    }

    /// Auto level on the decks: A and B kept at the same loudness on their trims, the volume
    /// faders left alone. Off puts the trims back to unity.
    pub fn set_auto_level(&self, on: bool) -> Result<(), DjError> {
        self.lock()?.auto_level = on;
        Ok(())
    }

    // MARK: TD-3 loops

    /// Load TD-3 loop `id` ("1A" … "4B", see [`td3_loops`]) on `deck` in place of its track and
    /// play it, synced to the other deck on the bar when that one plays. `drums`: with a kick
    /// and an offbeat hat (else the acid line alone). Compose (or back) returns to a track.
    pub fn load_td3(&self, deck: String, id: String, drums: bool) -> Result<(), DjError> {
        let deck = deck_name(&deck)?;
        let (proj, info) =
            td3::project(&id, drums).ok_or_else(|| DjError::Spec(format!("no TD-3 loop {id}")))?;
        let other = if deck == "A" { "B" } else { "A" };
        let mut g = self.lock()?;
        let with = g
            .rig
            .engine
            .deck(other)
            .is_some_and(|d| d.project.is_some() && d.mirror.is_playing());
        g.load_td3(deck, &proj, &info.id, with)
    }

    /// A TD-3 group on both decks: its A pattern on deck A, its B on deck B, both playing and
    /// locked on the bar, so the crossfader swaps the line's answer in and out.
    pub fn load_td3_pair(&self, group: u32, drums: bool) -> Result<(), DjError> {
        let a = format!("{group}A");
        let b = format!("{group}B");
        let (pa, ia) =
            td3::project(&a, drums).ok_or_else(|| DjError::Spec(format!("no TD-3 group {group}")))?;
        let (pb, ib) =
            td3::project(&b, drums).ok_or_else(|| DjError::Spec(format!("no TD-3 group {group}")))?;
        let mut g = self.lock()?;
        g.load_td3("A", &pa, &ia.id, false)?;
        g.load_td3("B", &pb, &ib.id, true)
    }

    /// 0 = all A, 1 = all B.
    pub fn set_crossfader(&self, v: f64) -> Result<(), DjError> {
        self.perform(DeckAction::Crossfader(v.clamp(0.0, 1.0)))
    }

    /// Match `deck`'s tempo and beat to the other deck's (the desktop's SYNC); it follows the
    /// other's tempo from then on.
    pub fn sync(&self, deck: String) -> Result<(), DjError> {
        let deck = deck_name(&deck)?;
        self.perform(DeckAction::Sync {
            deck: deck.into(),
            align: "beat".into(),
        })
    }

    // MARK: the vocoder

    /// The vocoder on, the synth as its carrier and `modulator` (a deck) shaping it; or off
    /// (None), the synth's notes let go.
    pub fn set_vocoder(&self, modulator: Option<String>) -> Result<(), DjError> {
        let modulator = modulator.map(|d| deck_name(&d)).transpose()?;
        let mut g = self.lock()?;
        let g = &mut *g;
        let e = &mut g.rig.engine;
        match modulator {
            Some(deck) => {
                e.vocoder_carrier(CarrierPick::Synth).map_err(DjError::Vocoder)?;
                e.vocoder_modulator(ModulatorPick::Deck(deck.into()))
                    .map_err(DjError::Vocoder)?;
                e.vocoder_switch(VocoderSwitch::On, true);
                g.vocoder_mod = Some(deck.to_string());
            }
            None => {
                e.vocoder_set_notes(&[]);
                e.vocoder_switch(VocoderSwitch::On, false);
                g.vocoder_mod = None;
            }
        }
        Ok(())
    }

    /// The notes the synth holds (a chord pad's); empty lets go.
    pub fn vocoder_notes(&self, notes: Vec<u8>) -> Result<(), DjError> {
        self.lock()?.rig.engine.vocoder_set_notes(&notes);
        Ok(())
    }

    /// Set a vocoder knob by name ("cutoff", "mix", …) in its own units (clamped).
    pub fn vocoder_set(&self, name: String, value: f64) -> Result<f64, DjError> {
        let p = VocoderParam::parse(&name)
            .ok_or_else(|| DjError::Vocoder(format!("no knob {name}")))?;
        let mut g = self.lock()?;
        if p == VocoderParam::Volume {
            // the user's level: auto level works around it (applied on the next tick)
            let (lo, hi) = p.range();
            g.voc_volume = value.clamp(lo, hi);
            if !g.voc_auto {
                let v = g.voc_volume;
                g.rig.engine.vocoder_set(p, v);
            }
            return Ok(g.voc_volume);
        }
        g.voc_edited = true;
        g.rig
            .engine
            .vocoder_set(p, value)
            .ok_or_else(|| DjError::Vocoder(format!("{name} refused {value}")))
    }

    /// Load one of the vocoder's sounds ([`vocoder_presets`]): the synth's factory preset it
    /// names and the vocoder's own knobs, from their defaults. The level stays the user's.
    pub fn vocoder_preset(&self, id: String) -> Result<(), DjError> {
        let d = voc_presets::find(&id).ok_or_else(|| DjError::Vocoder(format!("no sound {id}")))?;
        let mut g = self.lock()?;
        let g = &mut *g;
        let e = &mut g.rig.engine;
        for (p, v) in voc_presets::base_knobs() {
            e.vocoder_set(p, v);
        }
        e.synth_preset_load(d.synth).map_err(DjError::Vocoder)?;
        for (k, v) in d.knobs {
            if let Some(p) = VocoderParam::parse(k) {
                e.vocoder_set(p, *v);
            }
        }
        g.voc_preset = Some(d.id.to_string());
        g.voc_edited = false;
        g.voc_leveler.relearn();
        Ok(())
    }

    /// Auto level on the vocoder: its level kept with the decks' while a chord sounds (the
    /// Level knob sets it around that). Off: the Level knob is the level.
    pub fn set_vocoder_auto_level(&self, on: bool) -> Result<(), DjError> {
        self.lock()?.voc_auto = on;
        Ok(())
    }

    pub fn vocoder(&self) -> Result<VocoderState, DjError> {
        let g = self.lock()?;
        let v = &g.rig.engine.vocoder;
        let (m, c, o) = v.mirror.levels();
        Ok(VocoderState {
            on: v.settings.on,
            modulator: g.vocoder_mod.clone().filter(|_| v.settings.on),
            notes: v.notes.iter().copied().collect(),
            modulator_level: m,
            carrier_level: c,
            out_level: o,
            knobs: PHONE_KNOBS
                .iter()
                .map(|&p| {
                    let (min, max) = p.range();
                    VocoderKnob {
                        name: p.name().to_string(),
                        value: if p == VocoderParam::Volume {
                            g.voc_volume
                        } else {
                            v.settings.get(p)
                        },
                        min,
                        max,
                    }
                })
                .collect(),
            preset: g.voc_preset.clone(),
            edited: g.voc_edited,
            auto_level: g.voc_auto,
            auto_gain_db: if g.voc_auto { g.voc_leveler.gain_db() } else { 0.0 },
        })
    }

    // MARK: the Stage feed

    /// Fires on `deck` since the last call, as net / transition ids. The first call (or one
    /// for another deck) starts the feed from now.
    pub fn stage_poll(&self, deck: String) -> Result<StageBatch, DjError> {
        let deck = deck_name(&deck)?;
        let mut g = self.lock()?;
        let sr = g.info.sample_rate as f64;
        let g = &mut *g;
        let mirror = g.rig.engine.deck(deck).ok_or(DjError::Closed)?.mirror.clone();
        let reader = Self::stage_reader(&mut g.stage, deck, &mirror);
        Ok(reader.poll(&mirror, sr))
    }

    /// Forget the feed's position: the next `stage_poll` starts from now (a new Cast session
    /// must not get a burst of fires from before it connected).
    pub fn stage_reset(&self) {
        if let Ok(mut g) = self.lock() {
            g.stage = None;
        }
    }

    /// The Stage geometry of what `deck` plays (None before one plays).
    pub fn stage_project(&self, deck: String) -> Result<Option<StageProject>, DjError> {
        let deck = deck_name(&deck)?;
        let mut g = self.lock()?;
        let g = &mut *g;
        let d = g.rig.engine.deck(deck).ok_or(DjError::Closed)?;
        let mirror = d.mirror.clone();
        let name = d
            .spec
            .as_ref()
            .map(|s| djengine::gen::generate_track_name(&s.genre, s.seed))
            .unwrap_or_default();
        let reader = Self::stage_reader(&mut g.stage, deck, &mirror);
        Ok(reader.project(&mirror, &name))
    }

    // MARK: HEOS

    /// Start HEOS (the first call; later ones reconnect): `host` (`host[:port]`, a zone's
    /// address) or None to find the zones on the Wi-Fi (SSDP + mDNS).
    pub fn heos_start(&self, host: Option<String>) -> Result<(), DjError> {
        let host = host.filter(|h| !h.trim().is_empty());
        let mut h = self.heos_lock()?;
        match h.as_ref() {
            None => *h = Some(heos::HeosSide::start(host)),
            Some(side) => side.send(djhost::heos::Cmd::Connect(djhost::heos::Target::parse(
                host.as_deref().unwrap_or("auto"),
            ))),
        }
        Ok(())
    }

    /// The zones, their groups and the stream, read without waiting (off until started).
    pub fn heos_state(&self) -> HeosState {
        match self.heos.lock() {
            Ok(h) => h.as_ref().map_or_else(heos::off, |s| s.state()),
            Err(_) => heos::off(),
        }
    }

    /// Find the zones again.
    pub fn heos_discover(&self) -> Result<(), DjError> {
        self.heos_cmd(djhost::heos::Cmd::Discover)
    }

    pub fn heos_refresh(&self) -> Result<(), DjError> {
        self.heos_cmd(djhost::heos::Cmd::Refresh)
    }

    /// A zone's volume, 0..100.
    pub fn heos_volume(&self, pid: i64, level: u8) -> Result<(), DjError> {
        self.heos_cmd(djhost::heos::Cmd::Volume {
            pid,
            level: level.min(100),
        })
    }

    /// A group's volume, 0..100.
    pub fn heos_group_volume(&self, gid: i64, level: u8) -> Result<(), DjError> {
        self.heos_cmd(djhost::heos::Cmd::GroupVolume {
            gid,
            level: level.min(100),
        })
    }

    /// Mute a zone (None toggles).
    pub fn heos_mute(&self, pid: i64, on: Option<bool>) -> Result<(), DjError> {
        self.heos_cmd(djhost::heos::Cmd::Mute { pid, on })
    }

    /// "play", "pause" or "stop" on a zone (a group's from its leader).
    pub fn heos_transport(&self, pid: i64, state: String) -> Result<(), DjError> {
        let state = djhost::heos::PlayState::parse(&state)
            .ok_or_else(|| DjError::Heos(format!("{state}: play, pause or stop")))?;
        self.heos_cmd(djhost::heos::Cmd::PlayState { pid, state })
    }

    /// Group zones, the first leading.
    pub fn heos_group(&self, pids: Vec<i64>) -> Result<(), DjError> {
        if pids.len() < 2 {
            return Err(DjError::Heos("a group needs two zones or more".into()));
        }
        self.heos_cmd(djhost::heos::Cmd::SetGroup { pids })
    }

    /// Ungroup the group `pid` is in.
    pub fn heos_ungroup(&self, pid: i64) -> Result<(), DjError> {
        let h = self.heos_lock()?;
        h.as_ref().ok_or_else(|| DjError::Heos("HEOS isn't started".into()))?.ungroup(pid);
        Ok(())
    }

    /// Play the phone's mix on `pids` (the first leads; several are grouped so they stay
    /// together). They lag a little (HEOS buffers a stream). Returns the URL.
    pub fn heos_stream(&self, pids: Vec<i64>) -> Result<String, DjError> {
        let (src, sr) = {
            let g = self.lock()?;
            (g.rig.engine.master_stream_source(), g.info.sample_rate)
        };
        let mut h = self.heos_lock()?;
        h.as_mut()
            .ok_or_else(|| DjError::Heos("HEOS isn't started".into()))?
            .stream(&pids, || (src, sr))
            .map_err(DjError::Heos)
    }

    /// Stop the zones playing the phone's mix and close the stream.
    pub fn heos_stream_stop(&self) -> Result<(), DjError> {
        let mut h = self.heos_lock()?;
        if let Some(s) = h.as_mut() {
            s.stream_stop();
        }
        Ok(())
    }

    /// Stop the stream and the ticker. The player is unusable after.
    pub fn shutdown(&self) {
        if let Ok(mut h) = self.heos.lock() {
            if let Some(s) = h.as_mut() {
                s.stream_stop();
            }
            *h = None;
        }
        self.stop.store(true, Ordering::Relaxed);
        if let Ok(mut t) = self.threads.lock() {
            for h in t.drain(..) {
                h.thread().unpark();
                let _ = h.join();
            }
        }
    }
}

impl Player {
    fn lock(&self) -> Result<std::sync::MutexGuard<'_, Inner>, DjError> {
        if self.stop.load(Ordering::Relaxed) {
            return Err(DjError::Closed);
        }
        self.inner.lock().map_err(|_| DjError::Closed)
    }

    fn heos_lock(&self) -> Result<std::sync::MutexGuard<'_, Option<heos::HeosSide>>, DjError> {
        if self.stop.load(Ordering::Relaxed) {
            return Err(DjError::Closed);
        }
        self.heos.lock().map_err(|_| DjError::Closed)
    }

    fn heos_cmd(&self, c: djhost::heos::Cmd) -> Result<(), DjError> {
        let h = self.heos_lock()?;
        h.as_ref().ok_or_else(|| DjError::Heos("HEOS isn't started".into()))?.send(c);
        Ok(())
    }

    fn perform(&self, a: DeckAction) -> Result<(), DjError> {
        self.lock()?
            .rig
            .engine
            .perform(&a, PerformCtx::default());
        Ok(())
    }

    fn param(&self, deck: &str, name: &str, value: f64) -> Result<(), DjError> {
        let deck = deck_name(deck)?;
        self.perform(DeckAction::Param {
            deck: deck.into(),
            name: name.into(),
            value,
        })
    }

    /// The feed's reader for `deck`: a new one (from now) when the feed moves to another deck.
    fn stage_reader<'a>(
        slot: &'a mut Option<(String, stage::StageReader)>,
        deck: &str,
        mirror: &DeckMirror,
    ) -> &'a mut stage::StageReader {
        if slot.as_ref().is_none_or(|(d, _)| d != deck) {
            *slot = Some((deck.to_string(), stage::StageReader::new(mirror)));
        }
        &mut slot.as_mut().unwrap().1
    }
}

impl Drop for Player {
    fn drop(&mut self) {
        self.shutdown();
    }
}
