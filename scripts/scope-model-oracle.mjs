#!/usr/bin/env node
// Oracle for Tests/DJCoreTests/Scopes/ModelEngine*Tests.swift: the pure numerics of beats'
// scope-model.js / scope.js (pinned at beats-bitwrap-io 095d030), copied verbatim, run on the
// synthetic inputs the Swift tests build, printed as JSON. The Swift tests pin these literals.
//
//   node scripts/scope-model-oracle.mjs                 # all sections, as JSON
//   node scripts/scope-model-oracle.mjs analyse         # one section: analyse | biquad | fx | kernelFor | specs | deposit
//   node scripts/scope-model-oracle.mjs --swift > Tests/DJCoreTests/Scopes/ModelEngineOracleData.swift && make fmt
//   (the literals are written on long lines; `make fmt` wraps them the way swift-format wants)
//
// Nothing here touches the DOM or Tone: the functions below are the DSP and bookkeeping of the
// two files with the browser plumbing cut away (module-level arrays become locals). Where a
// block is marked "verbatim" it is character-for-character the JS.

const BANDS = [[20, 80], [80, 250], [250, 2000], [2000, 6000], [6000, 16000]];
const NB = BANDS.length;
const NS = 28;
const SPEC_EDGES = new Float64Array(NS + 1);
for (let i = 0; i <= NS; i++) SPEC_EDGES[i] = 30 * Math.pow(16000 / 30, i / NS);
const NR = NB + NS;
const EDGES = [];
for (const [lo, hi] of BANDS) EDGES.push([lo, hi]);
for (let i = 0; i < NS; i++) EDGES.push([SPEC_EDGES[i], SPEC_EDGES[i + 1]]);
const SR = 44100;
const FFT_N = 32768;
const SPEC_CAP = 2048;
const MAX_BARS = 1024;
const ROWS = NB + 1;

// --- verbatim: FFT + analyseHit ------------------------------------------------
let fftRe = null, fftIm = null, fftCos = null, fftSin = null, fftRev = null;
function fftInit() {
    if (fftRe) return;
    fftRe = new Float64Array(FFT_N); fftIm = new Float64Array(FFT_N);
    fftCos = new Float64Array(FFT_N / 2); fftSin = new Float64Array(FFT_N / 2);
    for (let i = 0; i < FFT_N / 2; i++) {
        fftCos[i] = Math.cos(2 * Math.PI * i / FFT_N);
        fftSin[i] = -Math.sin(2 * Math.PI * i / FFT_N);
    }
    fftRev = new Uint32Array(FFT_N);
    const bits = Math.log2(FFT_N);
    for (let i = 0; i < FFT_N; i++) {
        let r = 0;
        for (let b = 0; b < bits; b++) r |= ((i >> b) & 1) << (bits - 1 - b);
        fftRev[i] = r;
    }
}
function fft() {
    const re = fftRe, im = fftIm, n = FFT_N;
    for (let i = 0; i < n; i++) {
        const j = fftRev[i];
        if (j > i) { let t = re[i]; re[i] = re[j]; re[j] = t; t = im[i]; im[i] = im[j]; im[j] = t; }
    }
    for (let size = 2; size <= n; size <<= 1) {
        const half = size >> 1, step = n / size;
        for (let start = 0; start < n; start += size) {
            for (let k = 0; k < half; k++) {
                const c = fftCos[k * step], s = fftSin[k * step];
                const a = start + k, b = a + half;
                const tr = re[b] * c - im[b] * s, ti = re[b] * s + im[b] * c;
                re[b] = re[a] - tr; im[b] = im[a] - ti;
                re[a] += tr; im[a] += ti;
            }
        }
    }
}
function analyseHit(data, start, sr) {
    fftInit();
    let e = 0, et = 0;
    for (let i = 0; i < FFT_N; i++) {
        const x = start + i < data.length ? data[start + i] : 0;
        fftRe[i] = x; fftIm[i] = 0;
        const x2 = x * x;
        e += x2; et += x2 * i;
    }
    const tau = e > 0 ? Math.max(0.02, et / e / sr) : 0.1;
    fft();
    const r = new Float32Array(NR);
    const df = sr / FFT_N;
    for (let j = 0; j < NR; j++) {
        const k0 = Math.max(1, Math.floor(EDGES[j][0] / df));
        const k1 = Math.min(FFT_N / 2, Math.max(k0 + 1, Math.floor(EDGES[j][1] / df)));
        let p = 0;
        for (let k = k0; k < k1; k++) p += fftRe[k] * fftRe[k] + fftIm[k] * fftIm[k];
        r[j] = 2 * p / FFT_N;
    }
    return { r, tau };
}

// --- verbatim: FX response -----------------------------------------------------
const PROBES = 4;
const PROBE_F = new Float64Array(NR * PROBES);
for (let j = 0; j < NR; j++) {
    const [lo, hi] = EDGES[j];
    for (let p = 0; p < PROBES; p++) PROBE_F[j * PROBES + p] = lo * Math.pow(hi / lo, (p + 0.5) / PROBES);
}
function biquadMag2(type, fc, qDb, f, sr) {
    if (!(fc > 0) || !(fc < sr / 2)) return 1;
    const w0 = 2 * Math.PI * fc / sr;
    const cw = Math.cos(w0), alpha = Math.sin(w0) / (2 * Math.pow(10, (Number.isFinite(qDb) ? qDb : 0) / 20));
    let b0, b1;
    if (type === 'lowpass') { b0 = (1 - cw) / 2; b1 = 1 - cw; }
    else { b0 = (1 + cw) / 2; b1 = -(1 + cw); }
    const b2 = b0, a0 = 1 + alpha, a1 = -2 * cw, a2 = 1 - alpha;
    const w = 2 * Math.PI * f / sr;
    const c1 = Math.cos(w), s1 = Math.sin(w), c2 = Math.cos(2 * w), s2 = Math.sin(2 * w);
    const nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2);
    const dr = a0 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2);
    const d = dr * dr + di * di;
    return d > 0 ? (nr * nr + ni * ni) / d : 1;
}
function applyFilter(out, off, st, sr) {
    if (!st) return;
    if (st.type === 'lowpass' && st.fc >= 19000) return;
    if (st.type === 'highpass' && st.fc <= 25) return;
    for (let j = 0; j < NR; j++) {
        let m = 0;
        for (let p = 0; p < PROBES; p++) m += biquadMag2(st.type, st.fc, st.q, PROBE_F[j * PROBES + p], sr);
        out[off + j] *= Math.pow(m / PROBES, st.stages);
    }
}

// --- verbatim: per-lane kernel sets -------------------------------------------
function laneKernelSpecsNotes(lane) {
    const notes = [...lane.notes].sort((a, b) => a - b);
    if (!notes.length) notes.push(lane.drum ? 36 : 60);
    let reps;
    if (lane.drum) reps = notes.slice(0, 8);
    else reps = [...new Set([notes[0], notes[notes.length >> 1], notes[notes.length - 1]])];
    const durs = [...lane.durs].sort((a, b) => a - b);
    let dur = durs.length ? durs[durs.length >> 1] : 200;
    dur = Math.max(40, Math.min(700, Math.round(dur / 10) * 10));
    return { reps, dur };
}
function laneKernelTable(ks, notesArr, drum, durMs) {
    const n = ks.length;
    const notes = new Int16Array(n);
    const logR = new Float32Array(n * NR);
    let tau = 0;
    for (let i = 0; i < n; i++) {
        const k = ks[i];
        notes[i] = notesArr[i];
        for (let j = 0; j < NR; j++) logR[i * NR + j] = Math.log(Math.max(1e-20, k.r[j]));
        tau += k.tau;
    }
    return { notes, logR, n, drum, durMs, tau: Math.max(0.03, tau / Math.max(1, n)) };
}
function kernelFor(table, note, out) {
    const { notes, logR, n } = table;
    if (n === 1 || note <= notes[0]) { for (let j = 0; j < NR; j++) out[j] = Math.exp(logR[j]); return; }
    if (note >= notes[n - 1]) { const o = (n - 1) * NR; for (let j = 0; j < NR; j++) out[j] = Math.exp(logR[o + j]); return; }
    if (table.drum) {
        let best = 0, bd = Infinity;
        for (let i = 0; i < n; i++) { const d = Math.abs(notes[i] - note); if (d < bd) { bd = d; best = i; } }
        const o = best * NR;
        for (let j = 0; j < NR; j++) out[j] = Math.exp(logR[o + j]);
        return;
    }
    let i = 0;
    while (i < n - 2 && note > notes[i + 1]) i++;
    const w = (note - notes[i]) / Math.max(1, notes[i + 1] - notes[i]);
    const a = i * NR, b = (i + 1) * NR;
    for (let j = 0; j < NR; j++) out[j] = Math.exp(logR[a + j] + (logR[b + j] - logR[a + j]) * w);
}

// --- verbatim (scope.js): model deposit + spectrogram state --------------------
function newState(lanes) {
    const L = lanes.length;
    return {
        lanes, laneTables: new Array(L).fill(null), kbuf: new Float32Array(NR), fx: new Float32Array(32 * NR).fill(1),
        modelBars: new Float64Array(MAX_BARS * ROWS), maxBar: -1, modelFrom: Infinity,
        laneState: new Float32Array(L * NS), laneDecay: new Float32Array(L), laneMean: new Float32Array(L),
        specTickSec: 0, specCol: new Float32Array(SPEC_CAP * NS), specStep: new Int32Array(SPEC_CAP).fill(-1), specCur: -1,
    };
}
function modelDeposit(s, li, kt, note, vel, durMs, step, tickSec) {
    const k = s.kbuf;
    kernelFor(kt, note, k);
    let e = (vel / 100) * (vel / 100);
    if (!kt.drum) e *= Math.max(0.25, Math.min(4, durMs / kt.durMs));
    const off = (s.lanes[li].channel & 31) * NR;
    const fx = s.fx;
    const bar = Math.floor(step / 16);
    if (bar >= 0 && bar < MAX_BARS) {
        let sum = 0;
        const o = bar * ROWS;
        for (let b = 0; b < NB; b++) {
            const v = e * k[b] * fx[off + b];
            s.modelBars[o + b] += v; sum += v;
        }
        s.modelBars[o + NB] += sum;
        if (bar > s.maxBar) s.maxBar = bar;
        if (step < s.modelFrom) s.modelFrom = step;
    }
    specAdvance(s, step, tickSec);
    const lo = li * NS, inv = 1 / kt.tau;
    for (let j = 0; j < NS; j++) s.laneState[lo + j] += e * k[NB + j] * fx[off + NB + j] * inv;
}
function specAdvance(s, step, tickSec) {
    const L = s.lanes.length;
    if (s.specTickSec !== tickSec) {
        for (let l = 0; l < L; l++) {
            const tau = s.laneTables[l]?.tau || 0.1;
            const d = Math.exp(-tickSec / tau);
            s.laneDecay[l] = d;
            s.laneMean[l] = tau / tickSec * (1 - d);
        }
        s.specTickSec = tickSec;
    }
    if (s.specCur >= 0 && (step < s.specCur - 8 || step > s.specCur + SPEC_CAP)) {
        s.laneState.fill(0); s.specCur = -1;
    }
    if (s.specCur < 0) { s.specCur = step; return; }
    while (s.specCur < step) {
        const c = s.specCur, o = (c % SPEC_CAP) * NS;
        for (let j = 0; j < NS; j++) s.specCol[o + j] = 0;
        for (let l = 0; l < L; l++) {
            const m = s.laneMean[l], d = s.laneDecay[l], lo = l * NS;
            for (let j = 0; j < NS; j++) { s.specCol[o + j] += s.laneState[lo + j] * m; s.laneState[lo + j] *= d; }
        }
        s.specStep[c % SPEC_CAP] = c;
        s.specCur++;
    }
}

// --- the synthetic inputs (the Swift tests build the same vectors) -------------
const HIT_AT = 0.02;
const fr = Math.fround;
/** A decaying 1 kHz sine, hit at 20 ms into the segment. */
function sigSine() {
    const x = new Float32Array(FFT_N);
    const off = Math.round(HIT_AT * SR);
    for (let i = off; i < FFT_N; i++) {
        const n = i - off;
        x[i] = fr(Math.exp(-n / (0.05 * SR)) * Math.sin(2 * Math.PI * 1000 * n / SR));
    }
    return x;
}
/** Decaying LCG noise (time constant 20 ms), hit at 20 ms. */
function sigNoise() {
    const x = new Float32Array(FFT_N);
    const off = Math.round(HIT_AT * SR);
    let s = 12345;
    for (let i = off; i < FFT_N; i++) {
        const n = i - off;
        s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
        const u = s / 4294967296 - 0.5;
        x[i] = fr(u * Math.exp(-n / (0.02 * SR)));
    }
    return x;
}

const out = {};
const swiftOut = process.argv.includes('--swift');
const want = process.argv.slice(2).find(a => !a.startsWith('--'));
const on = (k) => !want || want === k;

if (on('analyse')) {
    const a = analyseHit(sigSine(), 0, SR);
    const b = analyseHit(sigNoise(), 0, SR);
    const c = analyseHit(new Float32Array(FFT_N), 0, SR);
    const sine = sigSine();
    let e = 0;
    for (const v of sine) e += v * v;
    out.analyse = {
        sine: { tau: a.tau, r: Array.from(a.r), energy: e },
        noise: { tau: b.tau, r: Array.from(b.r) },
        silent: { tau: c.tau, r: Array.from(c.r) },
        // The same noise read 100 samples later: the window start moves the centroid by 100/sr.
        noiseShifted: (() => { const k = analyseHit(sigNoise(), 100, SR); return { tau: k.tau, r: Array.from(k.r) }; })(),
    };
}

if (on('biquad')) {
    const qB = 20 * Math.log10(Math.SQRT1_2);
    const cases = [];
    for (const [type, fc, qDb, f, sr] of [
        ['lowpass', 1000, qB, 1000, 44100], ['lowpass', 1000, qB, 500, 44100], ['lowpass', 1000, qB, 2000, 44100],
        ['highpass', 1000, qB, 1000, 44100], ['highpass', 1000, qB, 500, 44100], ['highpass', 1000, qB, 2000, 44100],
        ['lowpass', 1000, 6, 1000, 44100], ['lowpass', 1000, 6, 800, 44100], ['lowpass', 1000, -6, 1000, 44100],
        ['highpass', 200, 6, 200, 48000], ['highpass', 200, 0, 100, 48000], ['lowpass', 5000, 12, 4000, 48000],
        ['lowpass', 0, 0, 1000, 44100], ['lowpass', 22050, 0, 1000, 44100], ['lowpass', 30000, 0, 1000, 44100],
        ['highpass', -5, 0, 1000, 44100], ['highpass', 1000, NaN, 1000, 44100], ['lowpass', 12000, qB, 16000, 48000],
    ]) cases.push({ type, fc, qDb: Number.isNaN(qDb) ? null : qDb, f, sr, mag2: biquadMag2(type, fc, qDb, f, sr) });
    out.biquad = cases;
}

if (on('fx')) {
    const qB = 20 * Math.log10(Math.SQRT1_2);
    const resp = (g2, filters, sr) => {
        const o = new Float32Array(NR).fill(g2);
        for (const st of filters) applyFilter(o, 0, st, sr);
        return Array.from(o);
    };
    out.fx = {
        probes: Array.from(PROBE_F).filter((_, i) => [0, 1, 2, 3, 4 * NB, 4 * NB + 3, 4 * (NR - 1) + 3].includes(i)),
        lp800: resp(1, [{ type: 'lowpass', fc: 800, q: qB, stages: 1 }], 44100),
        hp400: resp(0.5, [{ type: 'highpass', fc: 400, q: qB, stages: 1 }], 48000),
        both: resp(0.25, [{ type: 'highpass', fc: 120, q: qB, stages: 1 }, { type: 'lowpass', fc: 6000, q: qB, stages: 1 }], 48000),
        parkedLp: resp(1, [{ type: 'lowpass', fc: 19000, q: qB, stages: 1 }], 44100),
        parkedHp: resp(1, [{ type: 'highpass', fc: 25, q: qB, stages: 1 }], 44100),
        stages2: resp(1, [{ type: 'lowpass', fc: 1000, q: 0, stages: 2 }], 44100),
        edges: EDGES.map(([lo, hi]) => [lo, hi]),
    };
}

if (on('kernelFor')) {
    // Three tonal kernels with simple distinct logs, one drum table of three notes.
    const mk = (base, tau) => ({ r: Float32Array.from({ length: NR }, (_, j) => base * (1 + j)), tau });
    const ks = [mk(1, 0.1), mk(4, 0.2), mk(16, 0.3)];
    const tonal = laneKernelTable(ks, [40, 60, 80], false, 200);
    const drum = laneKernelTable(ks, [36, 38, 42], true, 200);
    const probe = (t, note) => { const o = new Float32Array(NR); kernelFor(t, note, o); return [o[0], o[1], o[NB], o[NR - 1]]; };
    out.kernelFor = {
        tonalTau: tonal.tau,
        tonal: [30, 40, 50, 60, 65, 70, 80, 100].map(n => [n, probe(tonal, n)]),
        drum: [30, 36, 37, 38, 39, 40, 41, 42, 60].map(n => [n, probe(drum, n)]),
        one: probe(laneKernelTable([ks[1]], [60], false, 200), 99),
        silentLog: Math.log(1e-20),
    };
}

if (on('specs')) {
    out.specs = [
        { notes: [60, 64, 67], durs: [100, 120, 400], drum: false },
        { notes: [60], durs: [], drum: false },
        { notes: [], durs: [], drum: true },
        { notes: [36, 38, 39, 42, 44, 46, 49, 51, 53, 55], durs: [10, 5000, 200], drum: true },
        { notes: [48, 50, 52, 53, 55, 57], durs: [45, 44, 46, 55, 65, 75], drum: false },
        { notes: [48, 48 + 24], durs: [142.5, 143, 144], drum: false },
    ].map(l => ({ ...l, ...laneKernelSpecsNotes(l) }));
}

if (on('deposit')) {
    // Two lanes: a drum (channel 10) and a tonal (channel 1), distinct fx per channel.
    const mkTable = (drum, notes, durMs, base, tau) => laneKernelTable(
        notes.map((_, i) => ({ r: Float32Array.from({ length: NR }, (_, j) => base * (i + 1) * (1 + j % 7) * 0.5), tau })),
        notes, drum, durMs);
    const lanes = [{ channel: 10, drum: true }, { channel: 1, drum: false }];
    const s = newState(lanes);
    s.laneTables = [mkTable(true, [36], 200, 2, 0.12), mkTable(false, [48, 72], 200, 1, 0.25)];
    for (let j = 0; j < NR; j++) { s.fx[(10 & 31) * NR + j] = 0.5; s.fx[(1 & 31) * NR + j] = 2 - j * 0.01; }
    const tickSec = 0.125;
    const steps = [];
    const dep = (li, note, vel, durMs, step) => { modelDeposit(s, li, s.laneTables[li], note, vel, durMs, step, tickSec); };
    dep(0, 36, 100, 200, 0);
    dep(1, 48, 100, 200, 0);
    dep(1, 60, 50, 800, 3);        // dur factor 4 (clamped), interpolated note, vel^2 = .25
    dep(0, 36, 127, 200, 4);
    dep(1, 72, 100, 10, 17);       // dur factor .05 -> clamped .25, next bar
    dep(1, 48, 100, 200, 40);      // skips ahead 23 steps: columns 17..39 finalised
    out.deposit = {
        tau: s.laneTables.map(t => t.tau),
        bars: Array.from(s.modelBars.slice(0, 3 * ROWS)),
        maxBar: s.maxBar, modelFrom: s.modelFrom, specCur: s.specCur,
        decay: Array.from(s.laneDecay), mean: Array.from(s.laneMean),
        col0: Array.from(s.specCol.slice(0, NS)),
        col1: Array.from(s.specCol.slice(1 * NS, 2 * NS)),
        col3: Array.from(s.specCol.slice(3 * NS, 4 * NS)),
        col5: Array.from(s.specCol.slice(5 * NS, 6 * NS)),
        col20: Array.from(s.specCol.slice(20 * NS, 21 * NS)),
        steps: Array.from(s.specStep.slice(0, 45)),
        laneState: Array.from(s.laneState.slice(0, 2 * NS)),
    };
}

if (!swiftOut) {
    console.log(JSON.stringify(out));
    process.exit(0);
}

// --- Swift literals for the tests ----------------------------------------------
const num = (x) => (Number.isFinite(x) ? String(x) : 'Double.nan');
const arr = (a) => '[' + Array.from(a, num).join(', ') + ']';
let swift = `// GENERATED by scripts/scope-model-oracle.mjs --swift from the pinned beats sources (095d030).
// Do not edit: regenerate. These are what scope-model.js / scope.js compute for the inputs the
// ModelEngine tests build (see the script for the vectors).

enum ModelOracle {
`;
const a = out.analyse, f = out.fx;
swift += `  static let sineTau = ${num(a.sine.tau)}
  static let sineEnergy = ${num(a.sine.energy)}
  static let sineR: [Double] = ${arr(a.sine.r)}
  static let noiseTau = ${num(a.noise.tau)}
  static let noiseR: [Double] = ${arr(a.noise.r)}
  static let noiseShiftedTau = ${num(a.noiseShifted.tau)}
  static let noiseShiftedR: [Double] = ${arr(a.noiseShifted.r)}
  static let silentTau = ${num(a.silent.tau)}

  /// type ("lowpass"/"highpass"), fc, qDb (nan = not finite), f, sr, |H|^2
  static let biquad: [(String, Double, Double, Double, Double, Double)] = [
${out.biquad.map(c => `    ("${c.type}", ${num(c.fc)}, ${c.qDb === null ? 'Double.nan' : num(c.qDb)}, ${num(c.f)}, ${num(c.sr)}, ${num(c.mag2)}),`).join('\n')}
  ]

  static let probeSubset: [Double] = ${arr(f.probes)}
  static let fxLp800: [Double] = ${arr(f.lp800)}
  static let fxHp400Gain05: [Double] = ${arr(f.hp400)}
  static let fxBoth: [Double] = ${arr(f.both)}
  static let fxParkedLp: [Double] = ${arr(f.parkedLp)}
  static let fxParkedHp: [Double] = ${arr(f.parkedHp)}
  static let fxTwoStages: [Double] = ${arr(f.stages2)}
  static let edges: [(Double, Double)] = [
${f.edges.map(e => `    (${num(e[0])}, ${num(e[1])}),`).join('\n')}
  ]

  static let tonalTau = ${num(out.kernelFor.tonalTau)}
  /// note, [out[0], out[1], out[NB], out[NR-1]]
  static let tonalKernelFor: [(Int, [Double])] = [
${out.kernelFor.tonal.map(([n, v]) => `    (${n}, ${arr(v)}),`).join('\n')}
  ]
  static let drumKernelFor: [(Int, [Double])] = [
${out.kernelFor.drum.map(([n, v]) => `    (${n}, ${arr(v)}),`).join('\n')}
  ]
  static let singleKernelFor: [Double] = ${arr(out.kernelFor.one)}

  /// notes, durations, drum, representative notes, duration
  static let specs: [([Int], [Double], Bool, [Int], Int)] = [
${out.specs.map(s => `    (${JSON.stringify(s.notes)}, ${arr(s.durs)}, ${s.drum}, ${JSON.stringify(s.reps)}, ${s.dur}),`).join('\n')}
  ]

  static let depositTau: [Double] = ${arr(out.deposit.tau)}
  static let depositBars: [Double] = ${arr(out.deposit.bars)}
  static let depositMaxBar = ${out.deposit.maxBar}
  static let depositModelFrom = ${out.deposit.modelFrom}
  static let depositSpecCur = ${out.deposit.specCur}
  static let depositDecay: [Double] = ${arr(out.deposit.decay)}
  static let depositMean: [Double] = ${arr(out.deposit.mean)}
  static let depositCol0: [Double] = ${arr(out.deposit.col0)}
  static let depositCol1: [Double] = ${arr(out.deposit.col1)}
  static let depositCol3: [Double] = ${arr(out.deposit.col3)}
  static let depositCol5: [Double] = ${arr(out.deposit.col5)}
  static let depositCol20: [Double] = ${arr(out.deposit.col20)}
  static let depositSteps: [Int] = ${JSON.stringify(out.deposit.steps)}
  static let depositLaneState: [Double] = ${arr(out.deposit.laneState)}
}
`;
console.log(swift);
