//! Auto level: a slow leveller that keeps a signal's peaks near a target, so deck A, deck B and
//! the vocoder sit at the same loudness without riding their faders.
//!
//! It follows the signal's peaks in dB (quick to rise, slow to fall, silence ignored so a
//! breakdown does not pump the gain up) and walks a gain toward `target - envelope` at a few dB a
//! second, inside a range. The user's own fader stays theirs: the gain goes on the deck's trim
//! (djhost `gain`, ±6 dB) or multiplies the vocoder's level.

/// Below this a peak is silence (a break, a stopped deck): the envelope holds.
const FLOOR_DB: f64 = -50.0;

#[derive(Clone, Copy, Debug)]
pub struct LevelCfg {
    /// The peak level aimed at, dBFS.
    pub target_db: f64,
    /// The gain's range, ±dB.
    pub range_db: f64,
    /// How fast the gain may move, dB a second.
    pub rate_db_s: f64,
    /// The envelope's rise and fall, seconds.
    pub rise_s: f64,
    pub fall_s: f64,
    /// Signal needed before the gain starts to move, seconds.
    pub settle_s: f64,
}

/// The decks: peaks at -8 dBFS, ±6 dB (all the trim has).
pub const DECKS: LevelCfg = LevelCfg {
    target_db: -8.0,
    range_db: 6.0,
    rate_db_s: 2.0,
    rise_s: 0.4,
    fall_s: 4.0,
    settle_s: 1.0,
};

/// The vocoder: the same target as the decks, more range (a modulator can be anything), and
/// quicker (a chord is held for seconds, not minutes).
pub const VOCODER: LevelCfg = LevelCfg {
    target_db: -8.0,
    range_db: 12.0,
    rate_db_s: 6.0,
    rise_s: 0.15,
    fall_s: 2.0,
    settle_s: 0.3,
};

#[derive(Clone, Copy, Debug, Default)]
pub struct Leveler {
    env_db: Option<f64>,
    heard_s: f64,
    gain_db: f64,
}

pub fn db(lin: f64) -> f64 {
    if lin <= 1e-6 {
        -120.0
    } else {
        20.0 * lin.log10()
    }
}

pub fn lin(db: f64) -> f64 {
    10f64.powf(db / 20.0)
}

impl Leveler {
    /// The gain now, dB.
    pub fn gain_db(&self) -> f64 {
        self.gain_db
    }

    /// Back to 0 dB, the envelope forgotten (auto level off, a new track).
    pub fn reset(&mut self) {
        *self = Leveler::default();
    }

    /// Forget the envelope but keep the gain (a new track: its level is learnt again from the
    /// gain it starts at, so nothing jumps).
    pub fn relearn(&mut self) {
        self.env_db = None;
        self.heard_s = 0.0;
    }

    /// One step of `dt` seconds with the signal's latest `peak` (linear, before the gain).
    /// `active`: the signal is meant to sound (a playing deck, a held chord); inactive holds
    /// everything. Returns the gain, dB.
    pub fn step(&mut self, peak: f32, dt: f64, active: bool, cfg: &LevelCfg) -> f64 {
        let p = db(peak as f64);
        if !active || p < FLOOR_DB || dt <= 0.0 {
            return self.gain_db;
        }
        let env = match self.env_db {
            None => p,
            Some(e) => {
                let tau = if p > e { cfg.rise_s } else { cfg.fall_s };
                e + (p - e) * (1.0 - (-dt / tau).exp())
            }
        };
        self.env_db = Some(env);
        self.heard_s += dt;
        if self.heard_s >= cfg.settle_s {
            let want = (cfg.target_db - env).clamp(-cfg.range_db, cfg.range_db);
            let max = cfg.rate_db_s * dt;
            self.gain_db += (want - self.gain_db).clamp(-max, max);
        }
        self.gain_db
    }
}

/// djhost's deck `gain` (0..1, 0.5 = unity, `trim_for_gain`: 2^((g - 0.5) × 2)) for a gain in dB.
pub fn deck_gain_param(gain_db: f64) -> f64 {
    let octaves = gain_db / (20.0 * 2f64.log10());
    (0.5 + octaves / 2.0).clamp(0.0, 1.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(l: &mut Leveler, peak: f32, secs: f64, cfg: &LevelCfg) -> f64 {
        let mut g = 0.0;
        for _ in 0..(secs / 0.01) as usize {
            g = l.step(peak, 0.01, true, cfg);
        }
        g
    }

    #[test]
    fn a_quiet_deck_comes_up_and_a_loud_one_goes_down() {
        let mut q = Leveler::default();
        let g = run(&mut q, lin(-14.0) as f32, 10.0, &DECKS);
        assert!((g - 6.0).abs() < 0.2, "{g}");
        let mut l = Leveler::default();
        let g = run(&mut l, lin(-4.0) as f32, 10.0, &DECKS);
        assert!((g + 4.0).abs() < 0.2, "{g}");
    }

    #[test]
    fn the_gain_moves_slowly_and_stays_in_range() {
        let mut l = Leveler::default();
        let g = run(&mut l, lin(-40.0) as f32, 2.0, &DECKS);
        assert!(g <= 2.05, "{g}");
        let g = run(&mut l, lin(-40.0) as f32, 30.0, &DECKS);
        assert!((g - 6.0).abs() < 1e-9, "{g}");
    }

    #[test]
    fn silence_and_a_stopped_deck_hold_the_gain() {
        let mut l = Leveler::default();
        let g = run(&mut l, lin(-12.0) as f32, 10.0, &DECKS);
        assert!(run(&mut l, 0.0, 10.0, &DECKS) == g);
        assert!(l.step(1.0, 0.01, false, &DECKS) == g);
    }

    #[test]
    fn deck_gain_param_matches_djhost_trim() {
        assert!((deck_gain_param(0.0) - 0.5).abs() < 1e-12);
        for d in [-6.0, -3.0, 2.0, 6.0] {
            let g = deck_gain_param(d);
            let trim = 2f64.powf((g - 0.5) * 2.0);
            assert!((db(trim) - d).abs() < 1e-9, "{d}");
        }
        assert_eq!(deck_gain_param(20.0), 1.0);
    }
}
