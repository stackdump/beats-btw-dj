//! TD-3 loops: a bank of one-bar acid lines, as a TD-3 holds them (four groups, each with an A
//! and a B pattern), to load on a deck in place of a composed track and mix against the other.
//!
//! A loop is a hand-built project (djhost `Engine::load`): the acid genre's kick and offbeat hat
//! (left out without drums) and a 16-step bass ring on its `acid` voice, the notes from
//! djengine's TD-3 acid generator (`gear::td3::Td3Pattern::acid`), accents as hard velocities,
//! slides and ties as notes held into the next step. Every loop is in A minor, the acid genre's
//! key, so the vocoder's chord pads fit whichever plays.
//!
//! A and B of a group share their first half (the B answers the A), so loading 1A on deck A and
//! 1B on deck B and riding the crossfader swaps the line's ending, TD-3 style.

use djengine::gear::td3::{Td3Pattern, Transpose};
use djengine::pflow::{NetBundle, Project};
use djengine::TrackSpec;

/// The pattern's C (the TD-3's middle octave, C2); A minor sits on A2 = 45, the acid genre's root.
const BASE: u8 = 36;
/// A (0 = C).
const ROOT: u8 = 9;
const STEPS: usize = 16;

/// One loop of the bank, as the phone lists it.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Td3Loop {
    /// "1A" … "4B".
    pub id: String,
    /// 1..=4.
    pub group: u32,
    /// "A" or "B".
    pub side: String,
    /// The group's name ("Classic").
    pub name: String,
    pub description: String,
    pub bpm: f64,
}

#[derive(Clone, Copy)]
enum Flavor {
    /// The generator's line as it comes.
    Classic,
    /// Slides on every fourth step, accents on the "and": rubbery.
    Squelch,
    /// No rests, octave pumps on the offbeats: driving.
    Rolling,
    /// The root on every eighth: hypnotic, one-note acid.
    Hypno,
}

struct Group {
    name: &'static str,
    description: &'static str,
    seed: f64,
    bpm: f64,
    flavor: Flavor,
}

const GROUPS: [Group; 4] = [
    Group {
        name: "Classic",
        description: "The textbook acid line: accents, a few slides, a rest or two.",
        seed: 303.0,
        bpm: 125.0,
        flavor: Flavor::Classic,
    },
    Group {
        name: "Squelch",
        description: "Rubbery: slides into every beat, accents on the off-beat.",
        seed: 909.0,
        bpm: 128.0,
        flavor: Flavor::Squelch,
    },
    Group {
        name: "Rolling",
        description: "Every step plays, octaves pumping on the offbeats: drives a mix.",
        seed: 808.0,
        bpm: 130.0,
        flavor: Flavor::Rolling,
    },
    Group {
        name: "Hypno",
        description: "One-note acid: the root on every eighth, the line in between.",
        seed: 606.0,
        bpm: 122.0,
        flavor: Flavor::Hypno,
    },
];

/// The bank: 1A, 1B, 2A, … 4B.
pub fn bank() -> Vec<Td3Loop> {
    let mut v = Vec::new();
    for (g, grp) in GROUPS.iter().enumerate() {
        for side in ["A", "B"] {
            v.push(Td3Loop {
                id: format!("{}{side}", g + 1),
                group: g as u32 + 1,
                side: side.into(),
                name: grp.name.into(),
                description: grp.description.into(),
                bpm: grp.bpm,
            });
        }
    }
    v
}

/// "1A" → (group index 0, B side false).
fn parse_id(id: &str) -> Option<(usize, bool)> {
    let id = id.trim().to_ascii_uppercase();
    let (n, side) = id.split_at(id.len().checked_sub(1)?);
    let g: usize = n.parse().ok()?;
    let b = match side {
        "A" => false,
        "B" => true,
        _ => return None,
    };
    (1..=GROUPS.len()).contains(&g).then_some((g - 1, b))
}

/// The 16 steps of a loop.
pub fn pattern(id: &str) -> Option<Td3Pattern> {
    let (g, b) = parse_id(id)?;
    let grp = &GROUPS[g];
    let mut p = Td3Pattern::acid(grp.seed, ROOT);
    if b {
        // the answer: the A's first half, a new second half
        let alt = Td3Pattern::acid(grp.seed + 77.0, ROOT);
        p.steps[STEPS / 2..].copy_from_slice(&alt.steps[STEPS / 2..]);
    }
    for (i, s) in p.steps.iter_mut().enumerate() {
        match grp.flavor {
            Flavor::Classic => {}
            Flavor::Squelch => {
                s.slide |= i % 4 == 3;
                s.accent = i % 4 == 2 || (s.accent && i % 2 == 1);
            }
            Flavor::Rolling => {
                s.rest = false;
                if i % 4 == 2 {
                    s.transpose = Transpose::Up;
                }
            }
            Flavor::Hypno => {
                if i % 2 == 0 {
                    s.note = ROOT;
                    s.transpose = Transpose::None;
                    s.rest = false;
                    s.slide = false;
                }
            }
        }
    }
    p.steps[0].rest = false;
    Some(p)
}

/// The loop as a project to load, `drums`: with the acid genre's kick and offbeat hat.
pub fn project(id: &str, drums: bool) -> Option<(Project, Td3Loop)> {
    let id = normalize(id)?;
    let info = bank().into_iter().find(|l| l.id == id)?;
    let pat = pattern(&info.id)?;
    let spec = TrackSpec::parse("acid:303").ok()?;
    let mut proj = spec.project();
    let keep: &[&str] = if drums { &["kick", "hihat", "bass"] } else { &["bass"] };
    for k in proj.nets.keys().to_vec() {
        let n = proj.nets.get(&k).unwrap();
        let group = if n.riff_group.is_empty() { k.as_str() } else { n.riff_group.as_str() };
        if !keep.contains(&group) || (group == "bass" && k != "bass") {
            proj.nets.remove(&k);
        }
    }
    let bass = proj.nets.get_mut("bass")?;
    let step_ms = 60_000.0 / info.bpm / 4.0;
    let mut ring = NetBundle::ring(STEPS as i64);
    let mut beats = 0;
    for (i, s) in pat.steps.iter().enumerate() {
        if s.rest {
            continue;
        }
        let held = s.slide || s.tie;
        let dur = if held { step_ms * 1.15 } else { step_ms * 0.55 };
        let vel = if s.accent { 127 } else { 88 };
        ring.bind(i as i64, s.midi_note(BASE) as i64, bass.track.channel, vel, dur.round() as i64);
        beats += 1;
    }
    ring.track = bass.track.clone();
    ring.track.ring_size = Some(STEPS as f64);
    ring.track.beats = Some(beats as f64);
    ring.track.generator = Some("td3".into());
    ring.role = bass.role.clone();
    *bass = ring;
    proj.name = format!("TD-3 {} {}", info.id, info.name);
    proj.tempo = info.bpm;
    proj.swing = 0.0;
    proj.humanize = 0.0;
    proj.bars = Some(1);
    proj.structure.clear();
    proj.initial_mutes.clear();
    proj.stingers.clear();
    Some((proj, info))
}

/// "1A" or "1a" → "1A" when it is one of the bank's.
pub fn normalize(id: &str) -> Option<String> {
    let (g, b) = parse_id(id)?;
    Some(format!("{}{}", g + 1, if b { "B" } else { "A" }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_bank_has_four_groups_of_a_and_b() {
        let b = bank();
        assert_eq!(b.len(), 8);
        assert_eq!(b[0].id, "1A");
        assert_eq!(b[7].id, "4B");
        assert_eq!(normalize("3b").as_deref(), Some("3B"));
        assert!(normalize("5A").is_none() && normalize("1C").is_none() && normalize("").is_none());
    }

    #[test]
    fn b_answers_a() {
        let a = pattern("1A").unwrap();
        let b = pattern("1B").unwrap();
        assert_eq!(a.steps[..8], b.steps[..8]);
        assert_ne!(a.steps[8..], b.steps[8..]);
    }

    #[test]
    fn every_loop_builds_a_one_bar_project() {
        for l in bank() {
            for drums in [true, false] {
                let (p, info) = project(&l.id, drums).unwrap();
                assert_eq!(info.id, l.id);
                assert_eq!(p.tempo, l.bpm);
                assert!(p.structure.is_empty());
                let bass = p.nets.get("bass").expect("a bass net");
                assert_eq!(bass.transitions.len(), STEPS);
                assert!(!bass.bindings.is_empty());
                assert_eq!(bass.track.instrument, "acid");
                let keys: Vec<&str> = p.nets.keys().iter().map(|s| s.as_str()).collect();
                if drums {
                    assert!(keys.contains(&"kick") && keys.contains(&"hihat"), "{keys:?}");
                } else {
                    assert_eq!(keys, ["bass"], "{keys:?}");
                }
            }
        }
    }
}
