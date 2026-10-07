// Physical layouts for the device diagrams. Positions are approximate (drawn
// from the hardware's general arrangement, not measured); MIDI numbers never
// live here — every shape points at profile controls by group + index or name.
//
// Shape: { id, kind, x, y, w?, h?, r?, label, refs: [{ g, i } | { g, n }], primary? }
//   kind: pad | button | knob | encoder | fader | hfader | jog | key | blackkey | joystick
//   refs: every control this physical thing can send (normal, shift layer,
//         other pad modes). The first ref sets the resting colour.

function apcMiniMk2() {
    const s = [];
    const P = 62;
    for (let r = 0; r < 8; r++) {
        for (let c = 0; c < 8; c++) {
            const i = r * 8 + c;
            s.push({ id: `pad${i}`, kind: 'pad', x: 20 + c * P, y: 20 + (7 - r) * P, w: 54, h: 54,
                label: `${i}`, refs: [{ g: 'pads', i }] });
        }
    }
    for (let i = 0; i < 8; i++) {
        s.push({ id: `scene${i}`, kind: 'button', x: 20 + 8 * P + 16, y: 32 + i * P, w: 46, h: 30,
            label: `S${i + 1}`, refs: [{ g: 'scene', i }] });
        s.push({ id: `track${i}`, kind: 'button', x: 24 + i * P, y: 20 + 8 * P + 6, w: 46, h: 22,
            label: `T${i + 1}`, refs: [{ g: 'track', i }] });
    }
    s.push({ id: 'shift', kind: 'button', x: 20 + 8 * P + 16, y: 20 + 8 * P + 6, w: 46, h: 22,
        label: 'SHIFT', refs: [{ g: 'shift', i: 0 }] });
    for (let i = 0; i < 9; i++) {
        const x = i < 8 ? 34 + i * P : 20 + 8 * P + 30;
        s.push({ id: `fader${i}`, kind: 'fader', x, y: 20 + 8 * P + 44, w: 26, h: 150,
            label: i < 8 ? `F${i + 1}` : 'MASTER', refs: [{ g: 'faders', i }] });
    }
    return { width: 20 + 9 * P + 30, height: 20 + 8 * P + 220, shapes: s };
}

function mpkMiniMk2() {
    const s = [];
    s.push({ id: 'joystick', kind: 'joystick', x: 70, y: 75, r: 45, label: 'JOY',
        refs: [{ g: 'joystickX', i: 0 }, { g: 'knobs', i: 0 }],
        note: 'X = pitch bend; Y = CC 1 (same CC as knob 1 in this preset)' });
    // Pads: 5-8 on the top row, 1-4 below (measured: pad n sends PC n-1).
    for (let i = 0; i < 8; i++) {
        const row = i < 4 ? 1 : 0, col = i % 4;
        s.push({ id: `pad${i}`, kind: 'pad', x: 150 + col * 80, y: 20 + row * 80, w: 70, h: 70,
            label: `PAD ${i + 1}`, refs: [{ g: 'pads', i }, { g: 'padNotes', i }, { g: 'padNotes', i: i + 8 }] });
    }
    // Knobs 1-4 top, 5-8 bottom. [UNVERIFIED] physical order — the capture
    // sweep produced CC 4,8,7,3,2,1,5,6; the live view will show the truth.
    for (let i = 0; i < 8; i++) {
        const row = i < 4 ? 0 : 1, col = i % 4;
        s.push({ id: `knob${i}`, kind: 'knob', x: 520 + col * 78, y: 46 + row * 66, r: 26,
            label: `K${i + 1}`, refs: [{ g: 'knobs', i }] });
    }
    // Buttons that change what the MPK sends but send no MIDI themselves.
    [['ARP ON/OFF', 16, 140], ['TAP TEMPO', 76, 140], ['OCTAVE ▼', 16, 168], ['OCTAVE ▲', 76, 168]]
        .forEach(([label, x, y]) => s.push({ id: label, kind: 'button', x, y, w: 54, h: 22, label, refs: [], noMidi: true }));
    [['BANK A/B', 480, 172], ['CC', 548, 172], ['PROG CHANGE', 616, 172], ['PROG SELECT', 700, 172]]
        .forEach(([label, x, y]) => s.push({ id: label, kind: 'button', x, y, w: 62, h: 20, label, refs: [], noMidi: true }));
    // 25 keys, C3 (48) .. C5 (72) at the default octave.
    const black = new Set([1, 3, 6, 8, 10]);
    let white = 0;
    const W = 34;
    for (let n = 48; n <= 72; n++) {
        if (!black.has(n % 12)) {
            s.push({ id: `key${n}`, kind: 'key', x: 20 + white * W, y: 200, w: W - 2, h: 150,
                label: n % 12 === 0 ? `C${n / 12 - 1}` : '', refs: [{ g: 'keys', i: n }] });
            white++;
        }
    }
    white = 0;
    for (let n = 48; n <= 72; n++) {
        if (black.has(n % 12)) {
            s.push({ id: `key${n}`, kind: 'blackkey', x: 20 + white * W - 11, y: 200, w: 22, h: 92,
                label: '', refs: [{ g: 'keys', i: n }] });
        } else white++;
    }
    return { width: 20 + 15 * W + 40 > 860 ? 20 + 15 * W + 40 : 860, height: 370, shapes: s };
}

function inpulse200Mk3() {
    // Proportions traced from the MK3 top-view photo (Sweetwater). Both decks
    // share one arrangement; deck 2 is deck 1 shifted right, not mirrored.
    const s = [];
    const rect = (id, kind, cx, cy, w, h, label, refs, extra = {}) =>
        s.push({ id, kind, x: cx - w / 2, y: cy - h / 2, w, h, label, refs, ...extra });
    const knob = (id, cx, cy, label, refs, kind = 'knob', r = 21) => s.push({ id, kind, x: cx, y: cy, r, label, refs });
    for (const [deck, dx] of [['A', 0], ['B', 753]]) {
        const d = `deck${deck}`;
        const btn = (n) => ({ g: `${d}.buttons`, n });
        const sh = (n) => ({ g: `${d}.shiftButtons`, n });
        s.push({ id: `${d}.jog`, kind: 'jog', x: 168 + dx, y: 217, r: 128, label: `JOG ${deck === 'A' ? 1 : 2}`, jogDeck: deck, refs: [] });
        rect(`${d}.btn03`, 'button', 40 + dx, 364, 52, 26, 'LOOP?', [btn('btn03')], { note: 'LOOP / STEMS — which one is 0x03?' });
        rect(`${d}.btn09`, 'button', 28 + dx, 413, 40, 24, '♫?', [btn('btn09'), sh('loopIn')], { note: 'STEMS music? (0x09)' });
        rect(`${d}.btn0A`, 'button', 74 + dx, 413, 40, 24, '🎤?', [btn('btn0A'), sh('loopOut')], { note: 'STEMS mic? (0x0A)' });
        rect(`${d}.shift`, 'button', 42 + dx, 466, 64, 22, 'SHIFT', [btn('shift')]);
        rect(`${d}.hotCueMode`, 'button', 130 + dx, 466, 64, 22, 'HOT CUE', [btn('hotCueMode')]);
        rect(`${d}.fxMode`, 'button', 217 + dx, 466, 64, 22, 'FX', [btn('fxMode')]);
        rect(`${d}.sync`, 'button', 42 + dx, 512, 64, 36, 'SYNC', [btn('sync'), sh('sync')]);
        rect(`${d}.cue`, 'button', 42 + dx, 565, 64, 36, 'CUE', [btn('cue'), sh('cue')]);
        rect(`${d}.play`, 'button', 42 + dx, 618, 64, 36, 'PLAY', [btn('play'), sh('play')]);
        [[130, 522], [217, 522], [130, 606], [217, 606]].forEach(([cx, cy], i) =>
            rect(`${d}.pad${i}`, 'pad', cx + dx, cy, 72, 72, `PAD ${i + 1}`,
                [{ g: `${d}.hotcuePads`, i }, { g: `${d}.hotcueClearPads`, i }, { g: `${d}.rollPads`, i },
                 { g: `${d}.fxPads`, i }, { g: `${d}.fxPads`, i: i + 4 }, { g: `${d}.samplerPads`, i }]));
        s.push({ id: `${d}.pitch`, kind: 'fader', x: 296 + dx, y: 470, w: 24, h: 168, label: 'TEMPO',
            refs: [{ g: `${d}.faders`, n: 'pitch' }] });
        rect(`${d}.padBend`, 'button', 268 + dx, 438, 1, 1, '', [{ g: `${d}.padBend`, i: 0 }], { hidden: true });
    }
    for (const [deck, cx] of [['A', 416], ['B', 672]]) {
        const d = `deck${deck}`;
        rect(`${d}.load`, 'button', cx, 30, 60, 22, 'LOAD', [{ g: `${d}.buttons`, n: 'load' }]);
        knob(`${d}.eqHigh`, cx, 80, 'HIGH/GAIN', [{ g: `${d}.faders`, n: 'eqHigh' }, { g: `${d}.shiftFaders`, n: 'gain' }]);
        knob(`${d}.eqMid`, cx, 162, 'MID', [{ g: `${d}.faders`, n: 'eqMid' }]);
        knob(`${d}.eqLow`, cx, 244, 'LOW', [{ g: `${d}.faders`, n: 'eqLow' }]);
        knob(`${d}.filter`, cx, 334, 'FILTER', [{ g: `${d}.faders`, n: 'filter' }]);
        rect(`${d}.pfl`, 'button', cx, 392, 54, 20, '🎧', [{ g: `${d}.buttons`, n: 'pfl' }]);
        s.push({ id: `${d}.volume`, kind: 'fader', x: cx - 12, y: 450, w: 24, h: 130, label: 'VOL',
            refs: [{ g: `${d}.faders`, n: 'volume' }] });
    }
    knob('browser', 544, 80, 'BROWSER', [{ g: 'mixer.browser', i: 0 }, { g: 'mixer.buttons', n: 'browserPush' },
        { g: 'mixer.shiftBrowser', i: 0 }, { g: 'mixer.shiftButtons', i: 0 }], 'encoder', 27);
    rect('centre01', 'button', 544, 166, 40, 24, 'ASSIST?', [{ g: 'mixer.buttons', n: 'centre01' }], { note: 'ASSIST / PREP, MASTER or BEATMATCH GUIDE?' });
    knob('master', 544, 244, 'MASTER', [{ g: 'mixer.faders', n: 'master' }]);
    knob('headphones', 544, 334, 'HEADPHONES', [{ g: 'mixer.faders', n: 'headphones' }]);
    rect('centre02', 'button', 544, 395, 60, 20, 'MASTER?', [{ g: 'mixer.buttons', n: 'centre02' }], { note: 'ASSIST / PREP, MASTER or BEATMATCH GUIDE?' });
    rect('centre03', 'button', 544, 452, 56, 20, 'GUIDE?', [{ g: 'mixer.buttons', n: 'centre03' }], { note: 'ASSIST / PREP, MASTER or BEATMATCH GUIDE?' });
    s.push({ id: 'crossfader', kind: 'hfader', x: 484, y: 612, w: 120, h: 22, label: 'CROSSFADER',
        refs: [{ g: 'mixer.faders', n: 'crossfader' }] });
    return { width: 1100, height: 670, shapes: s };
}

export const DEVICES = [
    { id: 'inpulse', title: 'Hercules DJControl Inpulse 200 MK3', profile: 'inpulse-200-mk3-surface',
      jog: 'inpulse-200-mk3', geometry: inpulse200Mk3() },
    { id: 'apc', title: 'Akai APC mini mk2', profile: 'apc-mini-mk2', geometry: apcMiniMk2() },
    { id: 'mpk', title: 'Akai MPK Mini Mk II', profile: 'mpk-mini-mk2', geometry: mpkMiniMk2() },
];
