#!/usr/bin/env node
// Master-chain macro fixtures (ROADMAP 3.3, the FX / pitch / feel macros). Runs beats' REAL
// macro code — lib/macros/catalog.js, effects.js (fxSweep / fxHold / runCompound /
// clearLocalMacroState), runtime.js (executeMacro, feel snap / sweep / genre reset, panicMacros),
// lib/feel/axes.js, lib/ui/controllers.js (setFxByKey / setFxValue / applyFeel),
// lib/ui/mixer-sliders.js (hpFreq / lpFreq) and audio/tone-engine.js's master setters — against
// a stubbed Tone whose Transport runs in virtual seconds and whose context reports itself as an
// `OfflineAudioContext` (so audioAnimLoop takes its deterministic branch: dispatches on a fixed
// 120 ms / 200 ms audio-clock grid instead of requestAnimationFrame).
//
// The engine's parameters are REAL Tone.js `Param`s (the pinned Tone 15.1.22 that beats loads,
// verified against beats' own SRI hash) on recording fake AudioParams, so the fixture also holds
// Tone's own automation timeline: the Tone-level calls each setter makes and the parameter values
// read back at probe times while the run goes (`getValueAtTime(now)`, which is what the native
// AudioParam renders: Tone mirrors every call onto it).
//
// What is NOT beats code here, and why:
//   * `applyFx` and the FX slider `input` handler live inside build.js's DOM setup (a closure, not
//     importable): copied verbatim below and marked. The handler's 33 ms wall-clock throttle is
//     modelled as "flush at the end of the current audio instant" (every dispatch at one virtual
//     time coalesces, latest value per key, keys in first-dispatch order). Live, the flush lands
//     up to 33 ms of wall time later; the port applies it at once (zero latency).
//   * `setTempo` (lib/backend/index.js, which imports the stage / scope / perf UI): copied, marked.
//   * `<input type="range">` value sanitisation (HTML spec: clamp to [min, max], snap to step):
//     a tiny stand-in for the browser, with beats' slider min/max/step from build.js.
//   * `el._msPerBar` (petri-note.js): copied, marked.
//   * Tone.now() = the virtual time (lookAhead 0, as in an offline context); Transport events run
//     at exactly `now + seconds` (no 192-PPQ tick quantisation), equal times in scheduling order.
//     User steps (fire / panic / manual slider set) at time T run before the scheduled events at T.
//
// Cases: every ported macro × its duration options and 0 (permanent) × BPM {120, 174} × start
// state {defaults; mid (sliders moved by hand first); re-fire of the same macro at half its
// duration; panic at 30 % of it, from mid}, plus hand-written overlaps. Only what reaches wave
// audio in beats' `&fx=tone` routing is kept in the output (HP, LP, phaser, crusher, distortion,
// pitch shift — and tempo); the reverb / delay / master-volume sends are dropped (see ROADMAP 3.3).
//
//   BEATS_PUBLIC=~/Workspace/beats-bitwrap-io/public node scripts/beats-macro-fx.mjs
//
// Needs Tone.js 15.1.22 locally: $TONE_JS, or .build/tone/Tone-15.1.22.js (downloaded from unpkg
// on first run and checked against the integrity hash in beats' index.html).
//
// Output: Tests/DJCoreTests/Fixtures/beats/macro-fx.json

import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC = path.resolve(process.env.BEATS_PUBLIC || path.join(process.env.HOME, 'Workspace/beats-bitwrap-io/public'));
const outFile = path.resolve(process.argv[2] || path.join(here, '../Tests/DJCoreTests/Fixtures/beats/macro-fx.json'));
const imp = (p) => import(pathToFileURL(path.join(PUBLIC, p)).href);

let beatsCommit = 'unknown';
try { beatsCommit = execFileSync('git', ['-C', PUBLIC, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(); } catch {}

// --- Tone.js: the exact build beats loads -------------------------------------------------

const indexHtml = readFileSync(path.join(PUBLIC, 'index.html'), 'utf8');
const toneTag = /<script src="https:\/\/unpkg\.com\/tone@([0-9.]+)\/build\/Tone\.js"\s+integrity="(sha384-[A-Za-z0-9+/=]+)"/.exec(indexHtml);
if (!toneTag) throw new Error('could not find the pinned Tone.js <script> in beats index.html');
const [, toneVersion, toneIntegrity] = toneTag;
const toneFile = path.resolve(process.env.TONE_JS || path.join(here, `../.build/tone/Tone-${toneVersion}.js`));
if (!existsSync(toneFile)) {
  const url = `https://unpkg.com/tone@${toneVersion}/build/Tone.js`;
  console.error(`downloading ${url}`);
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
  mkdirSync(path.dirname(toneFile), { recursive: true });
  writeFileSync(toneFile, Buffer.from(await res.arrayBuffer()));
}
const toneSri = 'sha384-' + createHash('sha384').update(readFileSync(toneFile)).digest('base64');
if (toneSri !== toneIntegrity) throw new Error(`${toneFile}: ${toneSri} != beats' ${toneIntegrity}`);

// A recording stand-in for the browser's AudioParam: Tone only needs it to exist (`instanceof`)
// and to accept the calls it mirrors; Tone's own timeline is what we read.
class AudioParam {
  constructor(defaultValue) {
    this.defaultValue = defaultValue; this.value = defaultValue;
    this.minValue = -3.4028234663852886e38; this.maxValue = 3.4028234663852886e38;
  }
  setValueAtTime() {} linearRampToValueAtTime() {} exponentialRampToValueAtTime() {}
  cancelScheduledValues() {} cancelAndHoldAtTime() {} setTargetAtTime() {}
}
globalThis.AudioParam = AudioParam;
globalThis.window = globalThis;
const RealTone = createRequire(import.meta.url)(toneFile);

// --- virtual clock, Transport, context ------------------------------------------------------

class OfflineAudioContext {}          // name sniffed by sched.js isOfflineContext()
class Clock {
  constructor() { this.reset(); }
  reset() { this.now = 0; this.seq = 0; this.events = []; }
  schedule(time, fn, priority = 0) {
    const e = { time, seq: this.seq++, priority, fn, cancelled: false };
    this.events.push(e);
    return e;
  }
  next() {
    let best = null;
    for (const e of this.events) {
      if (e.cancelled) continue;
      if (!best || e.time < best.time || (e.time === best.time &&
          (e.priority < best.priority || (e.priority === best.priority && e.seq < best.seq)))) best = e;
    }
    return best;
  }
}
const clock = new Clock();
// Tone's context, as the real Tone.Param sees it (a class instance: Tone deep-copies plain objects).
class FakeToneContext {
  get currentTime() { return clock.now; }
  get lookAhead() { return 0; }
  get sampleTime() { return 1 / 48000; }
  now() { return clock.now; }
}
const toneCtx = new FakeToneContext();
const rawContext = new OfflineAudioContext();
let transportIds = 0;
const transportEvents = new Map();
globalThis.Tone = {
  now: () => clock.now,
  getContext: () => ({ rawContext }),
  Transport: {
    state: 'started',
    // "+N" = N seconds from transport now (sched.js passes `+${seconds}`).
    scheduleOnce(fn, when) {
      if (typeof when !== 'string' || when[0] !== '+') throw new Error(`unexpected time ${when}`);
      const id = ++transportIds;
      transportEvents.set(id, clock.schedule(clock.now + parseFloat(when.slice(1)), fn));
      return id;
    },
    clear(id) { const e = transportEvents.get(id); if (e) e.cancelled = true; },
    cancel() { for (const e of transportEvents.values()) e.cancelled = true; },
  },
};
// Wall-clock timers (UI bookkeeping only: markMacroRunning, button flashes) never fire here.
globalThis.setTimeout = () => 0;
globalThis.clearTimeout = () => {};
globalThis.localStorage = { getItem: () => null, setItem: () => {} };

// --- beats' modules -------------------------------------------------------------------------

const { MACROS } = await imp('lib/macros/catalog.js');
const effects = await imp('lib/macros/effects.js');
const runtime = await imp('lib/macros/runtime.js');
const controllers = await imp('lib/ui/controllers.js');
const { hpFreq, lpFreq } = await imp('lib/ui/mixer-sliders.js');
const { toneEngine } = await imp('audio/tone-engine.js');

// --- the master chain's parameters: real Tone Params, logged at the Tone API ---------------

// What reaches wave audio with `&fx=tone` (lib/backend/wave.js connectOutput): the master insert
// chain. Reverb / delay are sends fed by Tone channel strips only; master-vol is the chain's input
// gain, which no ported macro moves (feel-reset lerps it to its default, 80, from 80).
const AUDIBLE_KEYS = ['hp-freq', 'lp-freq', 'phaser-freq', 'phaser-depth', 'phaser-wet', 'crush-bits', 'distortion', 'master-pitch'];
const AUDIBLE_PARAMS = new Set(['hp.frequency', 'lp.frequency', 'phaser.frequency', 'phaser.wet', 'phaser.octaves',
  'crusher.wet', 'crusher.bits', 'distortion.wet', 'distortion.amount', 'pitch.pitch']);

let ops = [];        // [t, param, op, ...args]
let opsInert = 0;
const valueDescriptor = Object.getOwnPropertyDescriptor(RealTone.Param.prototype, 'value');
const params = new Map();
function makeParam(name, units, value) {
  const p = new RealTone.Param({ param: new AudioParam(units === 'frequency' ? 350 : 1), context: toneCtx, units, value });
  const record = (...a) => { if (AUDIBLE_PARAMS.has(name)) ops.push([clock.now, name, ...a]); else opsInert++; };
  const rampTo = p.rampTo.bind(p);
  const cancel = p.cancelScheduledValues.bind(p);
  p.rampTo = (v, d, s) => { if (s !== undefined) throw new Error('rampTo with a start time'); record('ramp', v, d); return rampTo(v, d); };
  let inner = false;              // Tone's own value setter cancels first: one 'set' in the log
  p.cancelScheduledValues = (t) => { if (!inner) record('cancel', t); return cancel(t); };
  Object.defineProperty(p, 'value', {
    get() { return valueDescriptor.get.call(p); },
    set(v) { record('set', v); inner = true; try { valueDescriptor.set.call(p, v); } finally { inner = false; } },
  });
  params.set(name, p);
  return p;
}
function plain(name, initial) {      // a non-Param property the setters assign
  let v = initial;
  return { get: () => v, set: (x) => { v = x; if (AUDIBLE_PARAMS.has(name)) ops.push([clock.now, name, 'set', x]); else opsInert++; } };
}
function buildEngine() {
  params.clear();
  // tone-engine.js init(): HP(20, -48) → Phaser(1 Hz, 3 oct, 350 Hz, wet 0) → LP(20000, -48) →
  // BitCrusher(16 bits, wet 0) → Distortion(0, wet 0) → PitchShift(0, window 0.03).
  toneEngine._hpFilter = { frequency: makeParam('hp.frequency', 'frequency', 20) };
  toneEngine._lpFilter = { frequency: makeParam('lp.frequency', 'frequency', 20000) };
  const oct = plain('phaser.octaves', 3);
  toneEngine._phaser = { frequency: makeParam('phaser.frequency', 'frequency', 1), wet: makeParam('phaser.wet', 'normalRange', 0) };
  Object.defineProperty(toneEngine._phaser, 'octaves', oct);
  toneEngine._crusher = { wet: makeParam('crusher.wet', 'normalRange', 0), bits: makeParam('crusher.bits', 'positive', 16) };
  const dist = plain('distortion.amount', 0);
  toneEngine._distortion = { wet: makeParam('distortion.wet', 'normalRange', 0) };
  Object.defineProperty(toneEngine._distortion, 'distortion', dist);
  const pitch = plain('pitch.pitch', 0);
  toneEngine._pitchShift = {};
  Object.defineProperty(toneEngine._pitchShift, 'pitch', pitch);
  toneEngine._reverb = { roomSize: makeParam('reverb.roomSize', 'normalRange', 0.5), wet: makeParam('reverb.wet', 'normalRange', 0.2) };
  toneEngine._delay = { delayTime: makeParam('delay.delayTime', 'time', 0.25), feedback: makeParam('delay.feedback', 'normalRange', 0.25), wet: makeParam('delay.wet', 'normalRange', 0.15) };
  toneEngine._masterVolume = { volume: makeParam('master.volume', 'number', -12) };
  toneEngine._channelFx = new Map();
  toneEngine._waveGain = null;
}

// ---- COPIED VERBATIM from lib/ui/build.js (applyFx, inside the FX panel's DOM setup) ----------
const applyFx = (fxName, val) => {
    switch (fxName) {
        case 'reverb-size':    toneEngine.setReverbSize(val / 100); break;
        case 'reverb-damp':    toneEngine.setReverbDampening(10000 - (val / 100) * 9800); break;
        case 'reverb-wet':     toneEngine.setReverbWet(val / 100); break;
        case 'delay-time':     toneEngine.setDelayTime(val / 100); break;
        case 'delay-feedback': toneEngine.setDelayFeedback(val / 100); break;
        case 'delay-wet':      toneEngine.setDelayWet(val / 100); break;
        case 'master-vol':     toneEngine.setMasterVolume(val === 0 ? -60 : -60 + (val / 100) * 60); break;
        case 'distortion':     toneEngine.setDistortion(val / 100); break;
        case 'master-pitch':   toneEngine.setMasterPitch(val); break;
        case 'hp-freq':        toneEngine.setHighpassFreq(hpFreq(val)); break;
        case 'lp-freq':        toneEngine.setLowpassFreq(lpFreq(val)); break;
        case 'phaser-freq':    toneEngine.setPhaserFreq(val === 0 ? 0 : 0.1 + (val / 100) * 9.9); break;
        case 'phaser-depth':   toneEngine.setPhaserDepth(val / 100); break;
        case 'phaser-wet':     toneEngine.setPhaserWet(val / 100); break;
        case 'crush-bits':     toneEngine.setCrush(val / 100); break;
    }
};
// ---- end of copy ----------------------------------------------------------------------------

// The FX slider `input` handler (build.js), with its setTimeout(33) flush replaced by a flush at
// the end of the current audio instant (see the header). MODIFIED COPY.
const _fxPending = new Map();
let _fxFlushQueued = false;
function onFxInput(slider) {
  const key = slider.dataset.fx;
  const val = parseInt(slider.value);
  _fxPending.set(key, val);
  _fxFlushQueued = true;
}
let log = [];        // [t, 'fx', key, value] | [t, 'tempo', bpm]
function flushFx() {
  if (!_fxFlushQueued) return;
  for (const [k, v] of _fxPending) {
    if (AUDIBLE_KEYS.includes(k)) log.push([clock.now, 'fx', k, v]);
    applyFx(k, v);
  }
  _fxPending.clear();
  _fxFlushQueued = false;
}

// <input type="range"> stand-in (HTML spec value sanitisation); min/max/step from build.js.
const SLIDERS = {
  'master-vol': [0, 100, 1, 80], 'reverb-size': [0, 100, 1, 50], 'reverb-damp': [0, 100, 1, 30],
  'reverb-wet': [0, 100, 1, 20], 'delay-time': [1, 100, 1, 25], 'delay-feedback': [0, 90, 1, 25],
  'delay-wet': [0, 100, 1, 15], 'distortion': [0, 100, 1, 0], 'master-pitch': [-12, 12, 1, 0],
  'hp-freq': [0, 100, 1, 0], 'lp-freq': [0, 100, 1, 100], 'phaser-freq': [0, 100, 1, 0],
  'phaser-depth': [0, 100, 1, 50], 'phaser-wet': [0, 100, 1, 0], 'crush-bits': [0, 100, 1, 0],
};
class RangeInput {
  constructor(key, [min, max, step, value]) {
    this.dataset = { fx: key }; this.min = min; this.max = max; this.step = step; this._v = value;
  }
  get value() { return String(this._v); }
  set value(raw) {
    let v = parseFloat(raw);
    if (!Number.isFinite(v)) v = this.max < this.min ? this.min : (this.min + this.max) / 2;
    v = Math.min(this.max, Math.max(this.min, v));
    const k = (v - this.min) / this.step;        // nearest step, the larger one on a tie
    const lo = Math.floor(k);
    v = this.min + (k - lo >= 0.5 ? lo + 1 : lo) * this.step;
    this._v = Math.min(this.max, v);
  }
  dispatchEvent(e) { if (e.type === 'input') onFxInput(this); return true; }
}
globalThis.Event = class Event { constructor(type) { this.type = type; } };

// ---- COPIED from lib/backend/index.js setTempo (DOM input and project sync dropped) ----------
function setTempo(el, bpm) {
    if (!Number.isFinite(bpm)) return;
    el._tempo = Math.max(20, Math.min(300, bpm));
    el._project.tempo = el._tempo;
    log.push([clock.now, 'tempo', el._tempo]);     // sendWs(el, { type: 'tempo', bpm: el._tempo })
}
// ---- end of copy ----------------------------------------------------------------------------

function makeEl(bpm, genreBpm) {
  const sliders = Object.fromEntries(Object.entries(SLIDERS).map(([k, s]) => [k, new RangeInput(k, s)]));
  const el = {
    isConnected: true,
    _tempo: bpm,
    _project: { tempo: bpm, nets: {}, initialMutes: [] },
    _genreData: { g: { bpm: genreBpm } },
    _mutedNets: new Set(),
    _manualMutedNets: new Set(),
    querySelector(sel) {
      if (sel === '.pn-genre-select') return { value: 'g' };
      const fx = /^\.pn-fx-slider\[data-fx="([^"]+)"\]$/.exec(sel);   // controllers.js fxSlider
      if (fx) return sliders[fx[1]] || null;
      return null;
    },
    querySelectorAll() { return []; },
    _sendWs() {},
    // ---- COPIED from petri-note.js _msPerBar ----
    _msPerBar() {
        const ppq = 4;
        const ticksPerBar = 16;
        return (60000 / ((this._tempo || 120) * ppq)) * ticksPerBar;
    },
    // ---- end of copy ----
    _setTempo(b) { return setTempo(el, b); },
    _fxSlider(k) { return sliders[k] || null; },
    _setFxValue(s, v) { return controllers.setFxValue(s, v); },
    _setFxByKey(k, v) { return controllers.setFxByKey(el, k, v); },
    _applyFeel(p) { return controllers.applyFeel(el, p); },
    _fxSweep(k, v, ms) { return effects.fxSweep(el, k, v, ms); },
    _fxHold(k, v, ms, tf) { return effects.fxHold(el, k, v, ms, tf); },
    _runCompound(m, d, u, mpt) { return effects.runCompound(el, m, d, u, mpt); },
    _runBeatRepeat() {}, _tempoHold() {}, _tempoSweep() {}, _tempoAnchor() {},
    _channelParamMove() { throw new Error('pan/decay macros are not ported'); },
    _macroPulse() {},
    _disengageFeel() {},
    _toggleMute() {},
  };
  return el;
}

// --- runs ---------------------------------------------------------------------------------

const PORTED = ['sweep-lp', 'sweep-hp', 'reverb-wash', 'riser', 'build-crush', 'phaser-drone', 'filter-res',
  'octave-up', 'octave-down', 'pitch-bend', 'vinyl-brake',
  'feel-chill', 'feel-drive', 'feel-ambient', 'feel-euphoric', 'feel-build', 'feel-wind-down', 'feel-reset'];
const MID = { 'lp-freq': 60, 'hp-freq': 25, 'distortion': 10, 'crush-bits': 30, 'phaser-wet': 40,
  'phaser-depth': 70, 'phaser-freq': 20, 'master-pitch': 3 };
const GENRE_BPM = 128;
// Probe offsets after every Tone-level call on a parameter (inside its 50 / 100 ms ramp). Probed in
// the 'defaults' and 'panic' runs and the overlaps, which also carry the Tone-level calls (the 'mid' and
// 're-fire' runs carry the slider / tempo log only, for size).
const PROBE_OFFSETS = [0.01, 0.05, 0.099];

function runCase(spec) {
  clock.reset();
  transportEvents.clear();
  _fxPending.clear();
  _fxFlushQueued = false;
  log = []; ops = []; opsInert = 0;
  buildEngine();
  const el = makeEl(spec.bpm, spec.genreBpm ?? GENRE_BPM);
  if (spec.puck) el._feelState = { puck: [...spec.puck] };
  const probes = [];
  const probeAt = new Map();       // time -> Set(param)
  // user steps run before scheduled events at the same time
  for (const s of spec.steps) {
    clock.schedule(s[0], () => {
      switch (s[1]) {
        case 'fire': runtime.executeMacro(el, s[2], s[3] == null ? undefined : { duration: s[3] }); break;
        case 'panic': runtime.panicMacros(el); break;
        case 'set': el._setFxByKey(s[2], s[3]); break;
        default: throw new Error(s[1]);
      }
    }, -1);
  }
  const readProbes = (t) => {
    const names = probeAt.get(t);
    if (!names) return;
    probeAt.delete(t);
    for (const n of [...names].sort()) probes.push([t, n, params.get(n).getValueAtTime(t)]);
  };
  const pendingProbeTimes = () => [...probeAt.keys()].sort((a, b) => a - b);
  let guard = 0;
  for (;;) {
    const e = clock.next();
    const pt = pendingProbeTimes();
    if (!e) { for (const t of pt) { clock.now = t; readProbes(t); } break; }
    for (const t of pt) if (t < e.time) { clock.now = t; readProbes(t); }
    const t = e.time;
    clock.now = t;
    const opsBefore = ops.length;
    // the whole instant: every event at t (new ones scheduled at t included), then the flush
    for (let ev = clock.next(); ev && ev.time === t; ev = clock.next()) {
      ev.cancelled = true;
      ev.fn();
      if (++guard > 1e6) throw new Error('runaway');
    }
    flushFx();
    for (let i = opsBefore; spec.probe && i < ops.length; i++) {
      const name = ops[i][1];
      if (!params.has(name)) continue;          // a plain property: no timeline to probe
      for (const d of PROBE_OFFSETS) {
        const pt2 = t + d;
        if (!probeAt.has(pt2)) probeAt.set(pt2, new Set());
        probeAt.get(pt2).add(name);
      }
    }
    readProbes(t);
  }
  for (const p of params.values()) if (p._events.length >= 1000) throw new Error('Tone timeline overflowed its memory');
  return { log, ...(spec.probe ? { ops, probes } : {}), end: clock.now, tempo: el._tempo, puck: el._feelState?.puck ?? null,
    sliders: Object.fromEntries(AUDIBLE_KEYS.map((k) => [k, parseInt(el._fxSlider(k).value)])) };
}

const cases = [];
const T0 = 1;
function add(name, spec) {
  const r = runCase(spec);
  cases.push({ name, bpm: spec.bpm, genreBpm: spec.genreBpm ?? GENRE_BPM, puck: spec.puck ?? null, steps: spec.steps, ...r });
}
// Hand moves at 0.5 s, not 0: Tone built the chain at time 0, and a cancel at 0 would also drop
// the construction-time value (an artifact no live set has).
const midSteps = () => Object.entries(MID).map(([k, v]) => [0.5, 'set', k, v]);
for (const id of PORTED) {
  const m = MACROS.find((x) => x.id === id);
  if (!m) throw new Error(`no macro ${id}`);
  for (const bpm of [120, 174]) {
    const msPerBar = (60000 / (bpm * 4)) * 16;
    for (const dur of [...m.durationOpts, 0]) {
      const ms = (dur === 0 ? m.defaultDuration : dur) * (m.durationUnit === 'tick' ? msPerBar / 16 : msPerBar);
      add(`${id} ${dur} @${bpm} defaults`, { bpm, probe: true, steps: [[T0, 'fire', id, dur]] });
      add(`${id} ${dur} @${bpm} mid`, { bpm, puck: [0.3, 0.7], steps: [...midSteps(), [T0, 'fire', id, dur]] });
      add(`${id} ${dur} @${bpm} refire`, { bpm, steps: [[T0, 'fire', id, dur], [T0 + ms / 2000, 'fire', id, dur]] });
      add(`${id} ${dur} @${bpm} panic`, { bpm, probe: true, puck: [0.3, 0.7], steps: [...midSteps(), [T0, 'fire', id, dur], [T0 + (0.3 * ms) / 1000, 'panic']] });
    }
  }
}
// Hand-written overlaps (different macros on the same slider, feel over FX, compound timing).
const combos = [
  ['sweep-lp under a feel snap', [[T0, 'fire', 'sweep-lp', 4], [T0 + 1, 'fire', 'feel-chill', 1]]],
  ['feel build, sweep-hp, panic', [[T0, 'fire', 'feel-build', 4], [T0 + 2, 'fire', 'sweep-hp', 2], [T0 + 5, 'panic']]],
  ['octave-up then pitch-bend', [[T0, 'fire', 'octave-up', 2], [T0 + 0.5, 'fire', 'pitch-bend', 1]]],
  ['build-crush then filter-res', [[T0, 'fire', 'build-crush', 2], [T0 + 1, 'fire', 'filter-res', 1]]],
  ['vinyl-brake then octave-up before its sub-fire', [[T0, 'fire', 'vinyl-brake', 1], [T0 + 0.03, 'fire', 'octave-up', 1]]],
  ['feel-sweep then a snap inside its restore window', [[T0, 'fire', 'feel-wind-down', 2], [T0 + 4.03, 'fire', 'feel-drive', 1]]],
  ['feel-reset from mid, panic', [...midSteps(), [T0, 'fire', 'feel-reset', 4], [T0 + 3.3, 'panic']]],
  ['permanent sweep-lp then a sweep', [[T0, 'fire', 'sweep-lp', 0], [T0 + 0.5, 'fire', 'sweep-lp', 2]]],
  ['riser and phaser-drone', [[T0, 'fire', 'riser', 4], [T0 + 1.5, 'fire', 'phaser-drone', 2]]],
  ['permanent euphoric then reset', [[T0, 'fire', 'feel-euphoric', 0], [T0 + 2, 'fire', 'feel-reset', 2]]],
  ['phaser-drone twice, then panic after it ends', [[T0, 'fire', 'phaser-drone', 1], [T0 + 2.5, 'fire', 'phaser-drone', 1], [T0 + 6, 'panic']]],
  ['manual LP mid-sweep', [[T0, 'fire', 'sweep-lp', 2], [T0 + 1.05, 'set', 'lp-freq', 30]]],
  ['octave-down mid pitch-bend, panic', [[T0, 'fire', 'pitch-bend', 2], [T0 + 1, 'fire', 'octave-down', 1], [T0 + 1.5, 'panic']]],
];
for (const [name, steps] of combos) {
  for (const bpm of [120, 174]) add(`combo: ${name} @${bpm}`, { bpm, probe: true, puck: [0.6, 0.4], steps });
}

const counts = { cases: cases.length, log: cases.reduce((s, c) => s + c.log.length, 0),
  ops: cases.reduce((s, c) => s + (c.ops?.length ?? 0), 0), probes: cases.reduce((s, c) => s + (c.probes?.length ?? 0), 0) };
mkdirSync(path.dirname(outFile), { recursive: true });
writeFileSync(outFile, JSON.stringify({
  meta: { generator: 'scripts/beats-macro-fx.mjs', beatsCommit, tone: { version: toneVersion, integrity: toneIntegrity },
    ported: PORTED, audibleKeys: AUDIBLE_KEYS, mid: MID, probeOffsets: PROBE_OFFSETS, counts,
    // the catalog entries as beats has them (the Swift catalog is checked against this)
    catalog: PORTED.map((id) => {
      const m = MACROS.find((x) => x.id === id);
      return { id, label: m.label, group: m.group, kind: m.kind, defaultDuration: m.defaultDuration,
        durationOpts: m.durationOpts, durationUnit: m.durationUnit, tailFrac: m.tailFrac ?? null,
        ops: m.ops ?? null, steps: m.steps ?? null, target: m.target ?? null };
    }) },
  cases,
}) + '\n');
console.log(`${path.relative(process.cwd(), outFile)}: ${JSON.stringify(counts)}`);
