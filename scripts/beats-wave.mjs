#!/usr/bin/env node
// Wave-engine parity fixtures (ROADMAP 2.6). Runs beats' real net.js / runner.js:
//   * executor traces: per-tick checksum of everything a tick can change (fired
//     transitions, control firings, marking, mute tables) for whole songs, plus the
//     first ticks in full — the Swift port must match tick for tick, exactly;
//   * audio renders: float32 samples from WaveRunner.process in 128-frame blocks,
//     with scripted tempo / mute / load operations — the Swift port must match
//     within 1e-5 (libm may differ in the last ulp; the arithmetic is the same).
//
//   BEATS_PUBLIC=~/Workspace/beats-bitwrap-io/public node scripts/beats-wave.mjs
//
// Output: Tests/DJCoreTests/Fixtures/beats/wave.json

import { writeFileSync, mkdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC = path.resolve(process.env.BEATS_PUBLIC || path.join(process.env.HOME, 'Workspace/beats-bitwrap-io/public'));
const outFile = path.resolve(process.argv[2] || path.join(here, '../Tests/DJCoreTests/Fixtures/beats/wave.json'));
const imp = (p) => import(pathToFileURL(path.join(PUBLIC, p)).href);

const net = await imp('wave-engine/net.js');
const { WaveRunner } = await imp('wave-engine/runner.js');
const { composeProject, BLOCK } = await imp('wave-engine/offline.js');
const synth = await imp('wave-engine/synth.js');

let beatsCommit = 'unknown';
try { beatsCommit = execFileSync('git', ['-C', PUBLIC, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(); } catch {}

// --- executor traces ---------------------------------------------------------

function fnv(h, v) { return Math.imul(h ^ (v | 0), 16777619) >>> 0; }

function tickChecksum(g) {
  let h = 2166136261;
  h = fnv(h, g.tick);
  for (let i = 0; i < g.firedCount; i++) h = fnv(h, g.fired[i]);
  h = fnv(h, 0x7fff);
  for (let i = 0; i < g.controlCount; i++) h = fnv(h, g.controls[i]);
  h = fnv(h, g.overflow);
  for (const n of g.nets) for (let p = 0; p < n.P; p++) h = fnv(h, Math.round(n.state[p] * 1000));
  for (let i = 0; i < g.muted.length; i++) h = fnv(h, g.muted[i] + 2 * i);
  for (let i = 0; i < g.mutedNotes.length; i++) if (g.mutedNotes[i]) h = fnv(h, i + 100000);
  for (let i = 0; i < g.mutedGroups.length; i++) h = fnv(h, g.mutedGroups[i] + 3 * i);
  h = fnv(h, g.stopRequested ? 1 : 0);
  return h;
}

const traceSpecs = [
  { genre: 'techno', seed: 42, structure: 'standard' },
  { genre: 'jazz', seed: 7, structure: 'extended' },
  { genre: 'ambient', seed: 3, structure: 'minimal' },
  { genre: 'edm', seed: 11, structure: 'standard' },
  { genre: 'dnb', seed: 5, structure: 'jam' },
  { genre: 'techno', seed: 42, structure: 'loop' },
  { genre: 'bossa', seed: 9, structure: 'ab' },
  { genre: 'metal', seed: 2, structure: 'drop' },
];
const traces = traceSpecs.map((spec) => {
  const project = composeProject(spec.genre, spec.seed, spec.structure);
  const g = net.compileProject(project);
  const total = (project.structure || []).reduce((s, x) => s + x.steps, 0);
  const ticks = spec.structure === 'loop' ? 400 : total + 24;
  const sums = [], head = [];
  for (let k = 0; k < ticks; k++) {
    net.tick(g, null);
    sums.push(tickChecksum(g));
    if (k < 48) head.push({ fired: Array.from(g.fired.subarray(0, g.firedCount)), controls: Array.from(g.controls.subarray(0, g.controlCount)) });
  }
  return { ...spec, ticks, nets: g.nets.length, netIds: g.nets.map((n) => n.id), checksums: sums, head,
    stopRequested: g.stopRequested, mutedAtEnd: Array.from(g.muted), groups: g.groups };
});

// incidence matrices / P-invariants of a few nets
const invariantSpec = { genre: 'techno', seed: 42, structure: 'standard' };
const invG = net.compileProject(composeProject(invariantSpec.genre, invariantSpec.seed, invariantSpec.structure));
const invariants = invG.nets.map((n) => {
  const C = net.incidenceMatrix(n);
  const ys = net.pInvariants(C);
  const cs = C.map((row) => Array.from(row));
  return { id: n.id, P: n.P, T: n.T, incidence: cs.length ? cs.map((r) => r.reduce((a, b, i) => a + b * (i + 1), 0)) : [],
    invariants: ys.length, ones: ys.length === 1 && Array.from(ys[0]).every((v) => Math.abs(v - 1) < 1e-9) };
});

// --- audio renders -------------------------------------------------------------

const f32b64 = (a) => Buffer.from(a.buffer, a.byteOffset, a.byteLength).toString('base64');

function render(c) {
  const sr = c.sr;
  const runner = new WaveRunner(sr, c.runner || {});
  const projectOf = (s) => composeProject(s.genre, s.seed, s.structure);
  runner.load(projectOf(c.project));
  if (c.tempo) runner.setTempo(c.tempo);
  runner.play();
  const frames = Math.round(c.seconds * sr);
  const left = new Float32Array(frames), right = new Float32Array(frames);
  const ops = (c.ops || []).slice().sort((a, b) => a.block - b.block);
  let oi = 0, blk = 0;
  const events = [];
  for (let off = 0; off < frames; off += BLOCK, blk++) {
    while (oi < ops.length && ops[oi].block <= blk) {
      const op = ops[oi++];
      if (op.op === 'tempo') runner.setTempo(op.bpm);
      else if (op.op === 'mute') runner.setMute(op.netId, op.muted);
      else if (op.op === 'load') runner.load(projectOf(op.project));
      else if (op.op === 'pause') runner.pause();
      else if (op.op === 'play') runner.play();
      else if (op.op === 'stop') runner.stop();
    }
    const n = Math.min(BLOCK, frames - off);
    runner.process(left.subarray(off, off + n), right.subarray(off, off + n), n);
  }
  let identical = true;
  for (let i = 0; i < frames; i++) if (left[i] !== right[i]) { identical = false; break; }
  let peak = 0;
  for (let i = 0; i < frames; i++) peak = Math.max(peak, Math.abs(left[i]));
  return { ...c, frames, tempoAtEnd: runner.tempo, stopped: runner.stopped, samplesCounted: runner.samples,
    graphTick: runner.graph.tick, peak, stereoIdentical: identical, audio: f32b64(left) };
}

const audioCases = [
  { tag: 'techno-loop', sr: 8000, seconds: 3, project: { genre: 'techno', seed: 42, structure: 'loop' } },
  { tag: 'techno-loop-44k', sr: 44100, seconds: 0.8, project: { genre: 'techno', seed: 42, structure: 'loop' } },
  { tag: 'dnb-minimal-fast', sr: 8000, seconds: 4, tempo: 600, project: { genre: 'dnb', seed: 3, structure: 'minimal' } },
  { tag: 'jazz-standard-fast', sr: 8000, seconds: 4, tempo: 560, project: { genre: 'jazz', seed: 7, structure: 'standard' } },
  { tag: 'ambient-loop-pads', sr: 11025, seconds: 3, project: { genre: 'ambient', seed: 5, structure: 'loop' } },
  { tag: 'edm-linear', sr: 8000, seconds: 1.5, runner: { master: 'linear' }, project: { genre: 'edm', seed: 8, structure: 'loop' } },
  { tag: 'gain-and-mute', sr: 8000, seconds: 3, runner: { masterGain: 0.5 }, project: { genre: 'house', seed: 4, structure: 'loop' },
    ops: [{ block: 30, op: 'mute', netId: 'kick', muted: true }, { block: 80, op: 'tempo', bpm: 200 }, { block: 150, op: 'mute', netId: 'kick', muted: false }] },
  { tag: 'mods-am-fm', sr: 8000, seconds: 2.5, project: { genre: 'techno', seed: 42, structure: 'loop' },
    runner: { mods: [{ target: 'bass', source: 'kick', kind: 'am', depth: 0.6 }, { target: 'melody', source: 'hihat', kind: 'fm', depth: 0.02, silentSource: false },
      { target: 'kick', source: 'snare', kind: 'fm', depth: 0.3 }, { target: 'nope', source: 'kick', kind: 'am', depth: 1 }] } },
  { tag: 'voice-overrides', sr: 8000, seconds: 2.5, project: { genre: 'house', seed: 4, structure: 'loop' },
    runner: { voices: { melody: { kind: 'tonal', carrier: 'table', wave: 'sine', attack: 0.01, decayScale: 0.6, maxDecay: 2, level: 0.3 },
      hihat: { kind: 'hat', carrier: 'dc', pulse: { alpha: [1], tau: [0.02] }, level: 0.5 } },
      mods: [{ target: 'bass', source: 'hihat', kind: 'am', depth: 0.5, silentSource: true }] } },
  { tag: 'swap-at-bar', sr: 8000, seconds: 3.5, project: { genre: 'techno', seed: 42, structure: 'loop' },
    ops: [{ block: 40, op: 'load', project: { genre: 'house', seed: 4, structure: 'loop' } }] },
  { tag: 'pause-resume', sr: 8000, seconds: 2.5, project: { genre: 'trap', seed: 6, structure: 'loop' },
    ops: [{ block: 40, op: 'pause' }, { block: 70, op: 'play' }] },
  { tag: 'stop-transport', sr: 8000, seconds: 3.6, tempo: 1500, project: { genre: 'lofi', seed: 2, structure: 'minimal' } },
];
const renders = audioCases.map(render);

// voice specs, for the pure synth tests
const instruments = ['drums', 'drums-808', 'drums-v8', 'drums-cr78', 'drums-breakbeat', 'drums-lofi', 'nope'];
const voices = {
  drums: instruments.flatMap((i) => ['kick', 'snare', 'clap', 'hat', 'openhat'].map((k) => ({ instrument: i, kind: k, voice: synth.drumVoice(k, i) }))),
  tonal: ['warm-pad', 'strings', 'choir', 'organ', 'sub-bass', '808-bass', 'reese', 'acid', 'fm-bell', 'vibes', 'marimba', 'kalimba',
    'music-box', 'steel-drum', 'glass-pad', 'square-lead', 'chiptune', 'pwm-lead', 'clavinet', 'bright-pluck', 'edm-stab', 'piano',
    'acoustic-guitar', 'harpsichord', 'supersaw', '', undefined].flatMap((i) => ['melody', 'bass', 'harmony', 'pad', 'arp', undefined].map((g) => (
    { instrument: i ?? null, group: g ?? null, voice: synth.tonalVoice(i, g) }))),
};
const biquads = [['highpass', 7000, 0.7, 8000], ['highpass', 7000, 0.7, 44100], ['bandpass', 3000, 0.9, 44100], ['bandpass', 1400, 1.2, 11025], ['lowpass', 1000, 0.5, 48000]]
  .map(([t, fc, q, sr]) => ({ type: t, fc, q, sr, coeffs: Array.from(synth.biquad(t, fc, q, sr)) }));
const tables = ['sine', 'saw', 'square', 'soft', 'bell', 'nope'].map((w) => {
  const t = synth.buildTable(w);
  return { wave: w, sum: Array.from({ length: 8 }, (_, k) => t[k * 251]), last: t[synth.TABLE_SIZE] };
});
const seeds = Array.from({ length: 12 }, (_, i) => ({ i, seed: synth.noiseSeed(i) }));
const hashes = ['', 'p0', 'p_delay_12', 'kick-3', 'struct-stop'].map((s) => ({ s, h: net.strHash(s) }))
  .concat([{ s: 'é😀', h: net.strHash('é😀') }]);
const rands = [];
for (const tick of [0, 1, 15, 16, 929, 100000]) for (const salt of [0, 1, -1, 123456789, 2147483647])
  rands.push({ tick, salt, bits: (() => { const dv = new DataView(new ArrayBuffer(8)); dv.setFloat64(0, net.deterministicRand(tick, salt)); return dv.getBigUint64(0).toString(16).padStart(16, '0'); })() });

mkdirSync(path.dirname(outFile), { recursive: true });
writeFileSync(outFile, JSON.stringify({ meta: { generator: 'scripts/beats-wave.mjs', beatsCommit, block: BLOCK },
  traces, invariants, renders, voices, biquads, tables, noiseSeeds: seeds, strHashes: hashes, rands }) + '\n');
console.log('wrote', path.relative(process.cwd(), outFile));
