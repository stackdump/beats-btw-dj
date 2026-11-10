//! The performance tricks and the macros, as the desktop's TRICKS row and macro pads
//! (djrust docs/TRICKS.md, docs/AUX.md): the engine does the work, this names it for the app.

use djengine::fx::tricks::TrickKind;
use djengine::fx::{AuxMacro, MasterMacro};
use djengine::wave::macros::NetMacro;
use djhost::deck::tricks::TrickQuant;

/// One macro of the catalogue: its id (what [`crate::Player::fire_macro`] takes) and its group.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct MacroInfo {
    pub id: String,
    /// "Net" (the song's own), "FX"/"Pitch"/"Feel" (master), "Pan"/"Shape"/"FX" (aux)
    pub group: String,
    /// "net", "master" or "aux"
    pub kind: String,
}

/// Every trick that is audio (the TD-3 ones are MIDI gear and are left out).
pub const TRICKS: [TrickKind; 11] = [
    TrickKind::Stutter,
    TrickKind::Pump,
    TrickKind::Delay,
    TrickKind::Wash,
    TrickKind::VerbFreeze,
    TrickKind::TapeStop,
    TrickKind::SpinBack,
    TrickKind::HalfTime,
    TrickKind::DoubleTime,
    TrickKind::Filter,
    TrickKind::Riser,
];

pub fn trick_ids() -> Vec<String> {
    TRICKS.iter().map(|k| k.name().to_string()).collect()
}

pub fn parse_trick(id: &str) -> Option<TrickKind> {
    TRICKS.iter().copied().find(|k| k.name() == id)
}

pub fn quant() -> TrickQuant {
    TrickQuant::Default
}

pub fn catalogue() -> Vec<MacroInfo> {
    let mut v = Vec::new();
    for m in NetMacro::ALL {
        v.push(MacroInfo { id: m.id().into(), group: "Net".into(), kind: "net".into() });
    }
    for m in MasterMacro::ALL {
        v.push(MacroInfo { id: m.id().into(), group: m.group().into(), kind: "master".into() });
    }
    for m in AuxMacro::ALL {
        v.push(MacroInfo { id: m.id().into(), group: m.group().into(), kind: "aux".into() });
    }
    v
}
