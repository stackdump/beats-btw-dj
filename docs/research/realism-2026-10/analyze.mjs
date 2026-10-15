// Symbolic realism audit: every genre × a few seeds, standard structure.
// Reproduce: node docs/research/realism-2026-10/analyze.mjs (reads ~/Workspace/beats-bitwrap-io/public, read-only).
import { deflateSync } from 'node:zlib';
import { writeFileSync } from 'node:fs';
import { songEvents, GENRES } from './events.mjs';

const SEEDS = [42, 7, 2026];
const BAR = 16;
const mean = (a) => (a.length ? a.reduce((x, y) => x + y, 0) / a.length : 0);
const std = (a) => { const m = mean(a); return Math.sqrt(mean(a.map((x) => (x - m) ** 2))); };
const entropy = (counts) => {
  const tot = counts.reduce((a, b) => a + b, 0);
  return -counts.filter((c) => c > 0).reduce((h, c) => h + (c / tot) * Math.log2(c / tot), 0);
};
const DRUMS = new Set(['kick', 'snare', 'hihat', 'clap', 'drums']);

function intendedSwitches(json) {
  // phrase starts per role, as structure.js means them
  const out = {};
  let pos = 0;
  for (const s of json.structure) {
    for (const [role, ph] of Object.entries(s.phrases || {})) {
      const len = s.steps / ph.length;
      for (let i = 0; i < ph.length; i++) (out[role] ||= []).push(pos + i * len);
    }
    pos += s.steps;
  }
  return out;
}

// minimal voice-leading distance between two pitch-class sets of equal size placed near prev
function optimalVL(prev, nextPcs) {
  const perms = (a) => (a.length <= 1 ? [a] : a.flatMap((x, i) => perms([...a.slice(0, i), ...a.slice(i + 1)]).map((p) => [x, ...p])));
  let best = Infinity;
  if (prev.length !== nextPcs.length) return null;
  for (const p of perms(nextPcs)) {
    let d = 0;
    for (let i = 0; i < prev.length; i++) {
      const diff = (((p[i] - prev[i]) % 12) + 12) % 12;
      d += Math.min(diff, 12 - diff);
    }
    best = Math.min(best, d);
  }
  return best;
}

function analyse(genre, seed) {
  const { json, events, ticks, slotActivations, ringSize } = songEvents(genre, seed);
  const bars = Math.ceil(ticks / BAR);
  const secs = [];
  let pos = 0;
  for (const s of json.structure) { secs.push({ name: s.name, start: pos, steps: s.steps, phrases: s.phrases }); pos += s.steps; }
  const secOf = (t) => secs.findIndex((s) => t >= s.start && t < s.start + s.steps);

  // --- form
  const secBars = secs.map((s) => s.steps / BAR);
  const phraseBars = secs.flatMap((s) => { const ph = s.phrases?.melody || s.phrases?.bass || s.phrases?.kick; return ph ? [s.steps / BAR / ph.length] : []; });

  // --- control-net lateness
  const intended = intendedSwitches(json);
  const lateness = [];
  for (const [t, target] of slotActivations) {
    const role = target.replace(/-\d+$/, '');
    const want = (intended[role] || []).filter((x) => x <= t).pop();
    if (want !== undefined) lateness.push(t - want);
  }

  // --- density per section
  const perSec = secs.map((s) => ({ name: s.name, notes: 0, roles: new Set(), bars: s.steps / BAR }));
  for (const e of events) { const i = secOf(e.tick); if (i >= 0) { perSec[i].notes++; perSec[i].roles.add(e.role); } }
  const dens = perSec.map((s) => s.notes / s.bars);

  // --- velocities
  const velBy = {};
  for (const e of events) (velBy[e.role] ||= []).push(e.vel);
  const velStats = Object.fromEntries(Object.entries(velBy).map(([r, v]) => [r, { n: v.length, distinct: new Set(v).size, std: +std(v).toFixed(1), min: Math.min(...v), max: Math.max(...v) }]));

  // --- melody
  const mel = events.filter((e) => e.role === 'melody').sort((a, b) => a.tick - b.tick);
  const iv = [];
  for (let i = 1; i < mel.length; i++) if (mel[i].tick - mel[i - 1].tick <= 8) iv.push(Math.abs(mel[i].note - mel[i - 1].note));
  const ivh = { rep: 0, step: 0, skip: 0, leap: 0 };
  for (const d of iv) ivh[d === 0 ? 'rep' : d <= 2 ? 'step' : d <= 4 ? 'skip' : 'leap']++;
  const pcCounts = new Array(12).fill(0);
  for (const e of mel) pcCounts[e.note % 12]++;
  const melOnBeat = mel.filter((e) => e.tick % 4 === 0).length / (mel.length || 1);
  const melStarts = slotActivations.filter(([, t]) => t.startsWith('melody-'));
  const motifPhaseOff = melStarts.filter(([t, id]) => t % (ringSize[id] || 1) !== 0).length;

  // --- harmony / voice leading / consonance
  const harm = events.filter((e) => e.role === 'harmony');
  const chordsByBar = new Map();
  for (const e of harm) { const b = Math.floor(e.tick / BAR); (chordsByBar.get(b) || chordsByBar.set(b, []).get(b)).push(e.note); }
  const chordSeq = [...chordsByBar.entries()].sort((a, b) => a[0] - b[0]).map(([b, ns]) => ({ b, ns: ns.slice().sort((x, y) => x - y) }));
  let vlActual = [], vlOpt = [];
  for (let i = 1; i < chordSeq.length; i++) {
    const a = chordSeq[i - 1].ns, c = chordSeq[i].ns;
    if (a.length !== c.length || a.join() === c.join()) continue;
    vlActual.push(a.reduce((s, x, k) => s + Math.abs(c[k] - x), 0));
    vlOpt.push(optimalVL(a, c.map((x) => x % 12)));
  }
  const distinctChords = new Set(chordSeq.map((c) => c.ns.map((x) => x % 12).sort((x, y) => x - y).join('.'))).size;
  const chordAt = (t) => chordsByBar.get(Math.floor(t / BAR));
  let cons = 0, consN = 0;
  for (const e of mel) { const ch = chordAt(e.tick); if (!ch || e.tick % 4 !== 0) continue; consN++; if (ch.some((x) => x % 12 === e.note % 12)) cons++; }
  // harmonic rhythm: bars per chord change
  let changes = 0; for (let i = 1; i < chordSeq.length; i++) if (chordSeq[i].ns.join() !== chordSeq[i - 1].ns.join()) changes++;

  // --- bass
  const bass = events.filter((e) => e.role === 'bass');
  const bassPitches = new Set(bass.map((e) => e.note)).size;
  let bassRoot = 0, bassN = 0;
  for (const e of bass) { const ch = chordAt(e.tick); if (!ch) continue; bassN++; if (ch[0] % 12 === e.note % 12 || Math.min(...ch) % 12 === e.note % 12) bassRoot++; }
  const bassInterval = []; for (let i = 1; i < bass.length; i++) bassInterval.push(Math.abs(bass[i].note - bass[i - 1].note));

  // --- repetition (bar fingerprints)
  const fp = (filter) => {
    const m = new Map();
    for (const e of events) if (filter(e)) { const b = Math.floor(e.tick / BAR); (m.get(b) || m.set(b, []).get(b)).push(`${e.role}:${e.tick % BAR}:${e.note}:${e.vel}`); }
    const seq = []; for (let b = 0; b < bars; b++) seq.push((m.get(b) || []).sort().join('|'));
    const nonEmpty = seq.filter((s) => s);
    const sameAsPrev = seq.filter((s, i) => i > 0 && s && s === seq[i - 1]).length;
    const sameAs4 = seq.filter((s, i) => i >= 4 && s && s === seq[i - 4]).length;
    return { distinct: new Set(nonEmpty).size, bars: nonEmpty.length, sameAsPrev: sameAsPrev / (nonEmpty.length || 1), sameAs4Back: sameAs4 / (nonEmpty.length || 1) };
  };
  const repMix = fp(() => true), repDrums = fp((e) => DRUMS.has(e.role)), repMel = fp((e) => e.role === 'melody'), repBass = fp((e) => e.role === 'bass');
  const text = events.map((e) => `${e.tick}:${e.role}:${e.note}:${e.vel}`).join('\n');
  // compression ratio on tick-relative-to-bar stream (pure content repetition)
  const text2 = events.map((e) => `${e.tick % BAR}:${e.role}:${e.note}:${e.vel}`).join('\n');
  const cr = deflateSync(Buffer.from(text2)).length / Buffer.from(text2).length;

  // drums: kick velocities pattern + hats
  const hat = events.filter((e) => e.role === 'hihat');
  const hatVelPerPos = {}; for (const e of hat) (hatVelPerPos[e.tick % BAR] ||= new Set()).add(e.vel);
  const hatVelVariantsPerPos = mean(Object.values(hatVelPerPos).map((s) => s.size));

  // polyphony
  const perTick = new Map(); for (const e of events) perTick.set(e.tick, (perTick.get(e.tick) || 0) + 1);

  return {
    genre, seed, tempo: json.tempo, swing: json.swing ?? 0, humanize: json.humanize ?? 0,
    cohesion: json.cohesion || 'v1', seconds: +(ticks * 60 / json.tempo / 4).toFixed(1), bars,
    form: secs.map((s, i) => `${s.name}:${secBars[i]}`).join(' '),
    secBarsPow2: secBars.filter((b) => b % 8 === 0).length / secBars.length,
    phraseBars: [...new Set(phraseBars)].sort((a, b) => a - b),
    latenessMax: Math.max(0, ...lateness), latenessMean: +mean(lateness).toFixed(1), switches: lateness.length,
    density: perSec.map((s, i) => `${s.name}:${dens[i].toFixed(0)}/${s.roles.size}r`).join(' '),
    densContrast: +(Math.max(...dens) / Math.max(1e-9, Math.min(...dens.filter((d) => d > 0)))).toFixed(2),
    velStats,
    melody: mel.length ? { n: mel.length, range: Math.max(...mel.map((e) => e.note)) - Math.min(...mel.map((e) => e.note)), pcEntropy: +entropy(pcCounts).toFixed(2), distinctPitches: new Set(mel.map((e) => e.note)).size, intervals: Object.fromEntries(Object.entries(ivh).map(([k, v]) => [k, +(v / (iv.length || 1)).toFixed(2)])), onBeatShare: +melOnBeat.toFixed(2), motifPhaseOff: `${motifPhaseOff}/${melStarts.length}`, durMs: [...new Set(mel.map((e) => e.durMs))].length } : null,
    harmony: harm.length ? { chordsPerSong: distinctChords, chordChanges: changes, notesPerChord: +mean(chordSeq.map((c) => c.ns.length)).toFixed(1), vlActual: +mean(vlActual).toFixed(1), vlOptimal: +mean(vlOpt).toFixed(1), melConsonanceOnBeat: +(cons / (consN || 1)).toFixed(2) } : null,
    bass: { n: bass.length, distinctPitches: bassPitches, rootShare: +(bassRoot / (bassN || 1)).toFixed(2), meanInterval: +mean(bassInterval).toFixed(1) },
    repetition: { mix: repMix, drums: repDrums, melody: repMel, bass: repBass, deflateRatio: +cr.toFixed(3) },
    hatVelVariantsPerPos: +hatVelVariantsPerPos.toFixed(2),
    polyMean: +mean([...perTick.values()]).toFixed(2), onGrid: 1.0,
  };
}

const rows = [];
for (const g of GENRES) for (const s of SEEDS) {
  try { rows.push(analyse(g, s)); } catch (e) { rows.push({ genre: g, seed: s, error: String(e) }); }
}
writeFileSync(new URL('./symbolic.json', import.meta.url), JSON.stringify(rows, null, 1));
for (const r of rows) {
  if (r.error) { console.log(r.genre, r.seed, 'ERR', r.error); continue; }
  console.log([r.genre, r.seed, r.cohesion, r.tempo, `sw${r.swing}`, `${r.bars}b`, `pow8=${r.secBarsPow2.toFixed(2)}`, `ph=${r.phraseBars}`, `late=${r.latenessMax}`, `contrast=${r.densContrast}`,
    `mixRep=${r.repetition.mix.sameAsPrev.toFixed(2)}/${r.repetition.mix.distinct}d`, `drumDistinct=${r.repetition.drums.distinct}`, `melDistinct=${r.repetition.melody.distinct}`, `defl=${r.repetition.deflateRatio}`,
    `mel=${JSON.stringify(r.melody?.intervals)} rng${r.melody?.range} phaseOff${r.melody?.motifPhaseOff}`,
    `harm=${r.harmony ? `${r.harmony.chordsPerSong}ch vl${r.harmony.vlActual}/${r.harmony.vlOptimal} cons${r.harmony.melConsonanceOnBeat}` : '-'}`,
    `bass=${r.bass.distinctPitches}p root${r.bass.rootShare}`].join(' '));
}
