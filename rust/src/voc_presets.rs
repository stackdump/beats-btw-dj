//! The vocoder's sounds as the phone offers them: a whole setting in one tap, named for what it
//! sounds like. Each is one of the synth's factory presets (djengine `eurosynth::FACTORY_PRESETS`:
//! classic, acid, pad, sync lead, ring bell, noise sweep) plus the vocoder's own knobs (bands,
//! formant shift, attack / release, noise, vowel) and a few synth knobs on top.
//!
//! Loading one first puts the vocoder's own knobs back to their defaults, so a sound is the same
//! whatever was set before it; the level (`volume`) is the user's and is never touched.

use djengine::fx::vocoder::{VocoderParam, VocoderSettings};

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct VocoderPreset {
    pub id: String,
    /// "Desktop" (djapp's factory synth presets, by their names) or "More".
    pub group: String,
    pub name: String,
    pub description: String,
}

pub struct Def {
    pub id: &'static str,
    pub group: &'static str,
    pub name: &'static str,
    pub description: &'static str,
    /// The synth's factory preset it starts from.
    pub synth: &'static str,
    /// Knobs on top, by `VocoderParam` name.
    pub knobs: &'static [(&'static str, f64)],
}

// osc waves: 0 saw, 1 square, 2 triangle, 3 sine, 4 noise
pub const PRESETS: &[Def] = &[
    // the desktop's (djapp's Vocoder window preset menu): the synth's factory presets as they
    // are, the vocoder's knobs at their defaults
    Def {
        group: "Desktop",
        id: "classic",
        name: "classic",
        description: "The default patch: two saws 12 cents apart, the filter open.",
        synth: "classic",
        knobs: &[],
    },
    Def {
        group: "Desktop",
        id: "acid",
        name: "acid",
        description: "One saw into a resonant low-pass with a snappy envelope.",
        synth: "acid",
        knobs: &[],
    },
    Def {
        group: "Desktop",
        id: "pad",
        name: "pad",
        description: "Wide detune, a triangle on osc 3, slow attack and long release.",
        synth: "pad",
        knobs: &[],
    },
    Def {
        group: "Desktop",
        id: "sync lead",
        name: "sync lead",
        description: "A square, osc 2 an octave up and hard-synced: bright and cutting.",
        synth: "sync lead",
        knobs: &[],
    },
    Def {
        group: "Desktop",
        id: "ring bell",
        name: "ring bell",
        description: "Two sines ring-modulated: metallic bells with a long tail.",
        synth: "ring bell",
        knobs: &[],
    },
    Def {
        group: "Desktop",
        id: "noise sweep",
        name: "noise sweep",
        description: "Noise through a resonant filter swept by the envelope.",
        synth: "noise sweep",
        knobs: &[],
    },
    Def {
        group: "More",
        id: "talking-drums",
        name: "Talking drums",
        description: "The deck's beat plays the chord: punchy and rhythmic.",
        synth: "classic",
        knobs: &[("attack", 3.0), ("release", 60.0)],
    },
    Def {
        group: "More",
        id: "robot",
        name: "Robot",
        description: "The classic robot voice: few bands, quick and buzzy.",
        synth: "classic",
        knobs: &[
            ("bands", 10.0),
            ("attack", 1.0),
            ("release", 35.0),
            ("noise", 0.5),
            ("synth_detune", 3.0),
            ("cutoff", 9000.0),
        ],
    },
    Def {
        group: "More",
        id: "triple-osc",
        name: "Triple oscillator",
        description: "All three oscillators stacked and detuned, a sub saw an octave down: huge.",
        synth: "classic",
        knobs: &[
            ("osc3_wave", 0.0),
            ("osc3_oct", -1.0),
            ("osc3_level", 0.8),
            ("osc2_fine", 9.0),
            ("synth_detune", 28.0),
            ("drift", 0.25),
            ("bands", 20.0),
            ("release", 90.0),
        ],
    },
    Def {
        group: "More",
        id: "choir",
        name: "Choir",
        description: "A soft pad sung through an \"o\": slow, warm, human.",
        synth: "pad",
        knobs: &[
            ("vowel", 3.0),
            ("vowel_mix", 0.55),
            ("attack", 15.0),
            ("release", 350.0),
            ("bands", 24.0),
            ("noise", 0.12),
        ],
    },
    Def {
        group: "More",
        id: "acid-talk",
        name: "Acid talk",
        description: "The acid synth's squelch, opened and closed by the beat.",
        synth: "acid",
        knobs: &[("bands", 12.0), ("attack", 2.0), ("release", 50.0)],
    },
    Def {
        group: "More",
        id: "sync-lead",
        name: "Sync lead",
        description: "A bright hard-sync lead that cuts through any mix.",
        synth: "sync lead",
        knobs: &[("shift", 2.0), ("release", 80.0)],
    },
    Def {
        group: "More",
        id: "bells",
        name: "Bells",
        description: "Ring-mod bells that ring on after each hit.",
        synth: "ring bell",
        knobs: &[("bands", 20.0), ("release", 400.0)],
    },
    Def {
        group: "More",
        id: "whisper",
        name: "Whisper",
        description: "Mostly breath: airy, ghostly, the chord barely there.",
        synth: "classic",
        knobs: &[("noise", 1.0), ("bands", 24.0), ("release", 120.0), ("synth_level", 0.35)],
    },
    Def {
        group: "More",
        id: "deep",
        name: "Deep voice",
        description: "Formants down, a sine sub beneath: big and dark.",
        synth: "classic",
        knobs: &[
            ("shift", -5.0),
            ("osc3_wave", 3.0),
            ("osc3_oct", -1.0),
            ("osc3_level", 1.0),
            ("cutoff", 1800.0),
            ("resonance", 0.2),
        ],
    },
    Def {
        group: "More",
        id: "tiny",
        name: "Tiny voice",
        description: "Formants up: small, bright, cartoonish.",
        synth: "classic",
        knobs: &[("shift", 7.0), ("bands", 16.0), ("release", 45.0)],
    },
];

pub fn list() -> Vec<VocoderPreset> {
    PRESETS
        .iter()
        .map(|d| VocoderPreset {
            id: d.id.into(),
            group: d.group.into(),
            name: d.name.into(),
            description: d.description.into(),
        })
        .collect()
}

pub fn find(id: &str) -> Option<&'static Def> {
    PRESETS.iter().find(|d| d.id == id)
}

/// The vocoder's own knobs (not the synth's, not the level) at their defaults: what a sound
/// starts from.
pub fn base_knobs() -> Vec<(VocoderParam, f64)> {
    let d = VocoderSettings::default();
    [
        VocoderParam::Bands,
        VocoderParam::Shift,
        VocoderParam::Attack,
        VocoderParam::Release,
        VocoderParam::Mix,
        VocoderParam::Noise,
        VocoderParam::Vowel,
        VocoderParam::VowelMix,
        VocoderParam::SynthLevel,
        VocoderParam::SynthDetune,
    ]
    .into_iter()
    .map(|p| (p, d.get(p)))
    .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use djengine::fx::eurosynth::FACTORY_PRESETS;

    #[test]
    fn every_preset_names_real_knobs_and_a_factory_synth() {
        for d in PRESETS {
            assert!(FACTORY_PRESETS.iter().any(|(n, _)| *n == d.synth), "{}", d.synth);
            for (k, v) in d.knobs {
                let p = VocoderParam::parse(k).unwrap_or_else(|| panic!("{}: {k}", d.id));
                assert_ne!(p, VocoderParam::Volume, "{}: the level is the user's", d.id);
                let (lo, hi) = p.range();
                assert!((lo..=hi).contains(v), "{}: {k} {v}", d.id);
            }
        }
        let ids: std::collections::BTreeSet<_> = PRESETS.iter().map(|d| d.id).collect();
        assert_eq!(ids.len(), PRESETS.len());
    }
}
