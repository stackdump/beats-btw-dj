//! The vocoder's chord pads: the diatonic triads of a genre's key (its root and scale from the
//! beats tables), so the synth the deck shapes plays in the track's key.

/// One pad: a triad of MIDI notes and its name ("Am", "C", "B°") and degree ("i", "III").
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ChordPad {
    pub name: String,
    pub degree: String,
    pub notes: Vec<u8>,
}

/// A key's pads, i to vii.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ChordSet {
    /// "A minor".
    pub key: String,
    pub pads: Vec<ChordPad>,
}

const NAMES: [&str; 12] = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"];
const ROMAN: [&str; 7] = ["i", "ii", "iii", "iv", "v", "vi", "vii"];

/// The seven-note scale chords are stacked from: a pentatonic or blues scale borrows its
/// parent's (major or minor), whose triads it sits in.
fn heptatonic(scale_name: &str) -> (&'static [i64], &'static str) {
    use djengine::gen::core::scale_intervals;
    match scale_name {
        "MinPentatonicScale" | "BluesScale" => (scale_intervals("MinorScale"), "minor"),
        "PentatonicScale" => (scale_intervals("MajorScale"), "major"),
        "MinorScale" => (scale_intervals(scale_name), "minor"),
        "DorianScale" => (scale_intervals(scale_name), "dorian"),
        "MixolydianScale" => (scale_intervals(scale_name), "mixolydian"),
        "PhrygianScale" => (scale_intervals(scale_name), "phrygian"),
        "HarmonicMinScale" => (scale_intervals(scale_name), "harmonic minor"),
        _ => (scale_intervals("MajorScale"), "major"),
    }
}

/// The triads of `root_note`'s key in `scale_name`, voiced from the octave of middle C's
/// below (C3, MIDI 48) so the pads sit in a vocoder's sweet spot whatever octave the genre's
/// root is written in.
pub fn chord_set(root_note: i64, scale_name: &str) -> ChordSet {
    let (iv, mode) = heptatonic(scale_name);
    let pc = root_note.rem_euclid(12);
    let base = 48 + pc;
    let step = |k: usize| -> i64 { iv[k % 7] + 12 * (k / 7) as i64 };
    let pads = (0..7)
        .map(|d| {
            let (r, t, f) = (step(d), step(d + 2), step(d + 4));
            let (third, fifth) = (t - r, f - r);
            let root_pc = (pc + r).rem_euclid(12) as usize;
            let (suffix, upper) = match (third, fifth) {
                (3, 6) => ("°", false),
                (3, _) => ("m", false),
                (4, 8) => ("+", true),
                _ => ("", true),
            };
            let roman = if upper { ROMAN[d].to_uppercase() } else { ROMAN[d].to_string() };
            ChordPad {
                name: format!("{}{}", NAMES[root_pc], suffix),
                degree: format!("{roman}{}", if suffix == "°" || suffix == "+" { suffix } else { "" }),
                notes: [r, t, f].iter().map(|n| (base + n).clamp(0, 127) as u8).collect(),
            }
        })
        .collect();
    ChordSet {
        key: format!("{} {}", NAMES[pc as usize], mode),
        pads,
    }
}

/// A genre's pads (C major for an unknown genre).
pub fn chords_for_genre(genre: &str) -> ChordSet {
    match djengine::gen::BeatsTables::shared().genres.get(genre) {
        Some(g) => chord_set(g.root_note, &g.scale_name),
        None => chord_set(60, "MajorScale"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_minor_triads() {
        let s = chord_set(57, "MinorScale"); // A3
        assert_eq!(s.key, "A minor");
        let names: Vec<_> = s.pads.iter().map(|p| p.name.as_str()).collect();
        assert_eq!(names, ["Am", "B°", "C", "Dm", "Em", "F", "G"]);
        let degrees: Vec<_> = s.pads.iter().map(|p| p.degree.as_str()).collect();
        assert_eq!(degrees, ["i", "ii°", "III", "iv", "v", "VI", "VII"]);
        assert_eq!(s.pads[0].notes, vec![57, 60, 64]); // A3 C4 E4
    }

    #[test]
    fn c_major_and_pentatonic_borrows_major() {
        let s = chord_set(36, "PentatonicScale");
        assert_eq!(s.key, "C major");
        assert_eq!(s.pads[0].notes, vec![48, 52, 55]);
        let names: Vec<_> = s.pads.iter().map(|p| p.name.as_str()).collect();
        assert_eq!(names, ["C", "Dm", "Em", "F", "G", "Am", "B°"]);
    }

    #[test]
    fn every_genre_has_seven_pads_in_range() {
        for g in djengine::gen::BeatsTables::shared().genres.keys() {
            let s = chords_for_genre(g);
            assert_eq!(s.pads.len(), 7, "{g}");
            for p in &s.pads {
                assert_eq!(p.notes.len(), 3);
                assert!(p.notes.iter().all(|&n| (48..=84).contains(&n)), "{g} {p:?}");
            }
        }
    }
}
