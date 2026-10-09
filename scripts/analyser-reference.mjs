#!/usr/bin/env node
// Reference numbers for Sources/DJCore/Scopes/AnalyserFFT.swift (Tests/DJCoreTests/Scopes/
// AnalyserFFTTests.swift pins the literals this prints).
//
// This is the Web Audio spec's AnalyserNode algorithm written the slowest, plainest way, in
// double precision, with NO FFT: a naive O(N^2) DFT. Nothing here is shared with the Swift
// implementation (vDSP FFT, float32), so agreement between them is a real check of the
// scaling (|X_k|/N, vDSP's factor of 2), the window, the bin set and the smoothing.
//
//   node scripts/analyser-reference.mjs
//
// Spec text (Web Audio API, AnalyserNode):
//   window     w[n] = 0.5(1-a) - 0.5 cos(2 pi n/N) + 0.5 a cos(4 pi n/N), a = 0.16, n = 0..N-1
//   FFT        X[k] = (1/N) sum_n x[n] w[n] e^{-j 2 pi k n/N}
//   smoothing  Xs[k] = tau Xs_prev[k] + (1-tau) |X[k]|     (state starts at 0)
//   dB         Y[k] = 20 log10 Xs[k]                      (-Infinity for 0)
//   bytes      b[k] = clamp(floor(255 (Y[k]-dBmin)/(dBmax-dBmin)), 0, 255)
//   bins       frequencyBinCount = N/2

import { pathToFileURL } from 'node:url';

const ALPHA = 0.16;

export function blackman(N) {
  const a0 = 0.5 * (1 - ALPHA), a2 = 0.5 * ALPHA;
  return Array.from({ length: N }, (_, n) =>
    a0 - 0.5 * Math.cos((2 * Math.PI * n) / N) + a2 * Math.cos((4 * Math.PI * n) / N));
}

// |X[k]|/N for k = 0..N/2-1, naive DFT of the windowed frame.
export function magnitudes(x, N) {
  const w = blackman(N);
  const out = [];
  for (let k = 0; k < N / 2; k++) {
    let re = 0, im = 0;
    for (let n = 0; n < N; n++) {
      const v = x[n] * w[n], ph = (-2 * Math.PI * k * n) / N;
      re += v * Math.cos(ph);
      im += v * Math.sin(ph);
    }
    out.push(Math.hypot(re, im) / N);
  }
  return out;
}

export class SpecAnalyser {
  constructor(N, tau) { this.N = N; this.tau = tau; this.s = new Array(N / 2).fill(0); }
  // `window` may be shorter (front zero-padded) or longer (newest N) than N, like the Swift class.
  analyse(window) {
    const N = this.N, have = Math.min(window.length, N);
    const x = new Array(N - have).fill(0).concat(window.slice(window.length - have));
    const m = magnitudes(x, N);
    this.s = this.s.map((p, k) => this.tau * p + (1 - this.tau) * m[k]);
    return this.s;
  }
  dB() { return this.s.map((v) => 20 * Math.log10(v)); }
  bytes(dmin = -100, dmax = -30) {
    return this.dB().map((db) => {
      const v = Math.floor((255 * (db - dmin)) / (dmax - dmin));
      return Math.max(0, Math.min(255, Number.isNaN(v) ? 0 : v));
    });
  }
}

// Importing this file gives the spec model (blackman, magnitudes, SpecAnalyser); running it
// prints the numbers the Swift tests pin.
const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;

const fmt = (v) => (Number.isFinite(v) ? Number(v.toPrecision(12)).toString() : String(v));
const arr = (a) => '[' + a.map(fmt).join(', ') + ']';

if (isMain) {
  // ---- closed forms ---------------------------------------------------------------------
  console.log('// --- window (periodic Blackman, alpha 0.16) ---');
  for (const N of [256, 4096]) {
    const w = blackman(N);
    const at = (n) => fmt(w[n]);
    console.log(`N=${N}: w[0]=${at(0)} w[1]=${at(1)} w[N/8]=${at(N / 8)} w[N/4]=${at(N / 4)} w[N/2]=${at(N / 2)} w[3N/4]=${at(3 * N / 4)} w[N-1]=${at(N - 1)} mean=${fmt(w.reduce((a, b) => a + b, 0) / N)}`);
  }

  console.log('\n// --- bin-centred sine, N=256, k=16, amplitude 1, tau 0 (non-zero bins 14..18 only) ---');
  {
    const N = 256, k0 = 16, x = Array.from({ length: N }, (_, n) => Math.sin((2 * Math.PI * k0 * n) / N));
    const m = magnitudes(x, N);
    console.log('bins 12..20:', arr(m.slice(12, 21)));
    console.log('dB   14..18:', arr(m.slice(14, 19).map((v) => 20 * Math.log10(v))));
    const rest = m.filter((_, k) => k < 14 || k > 18);
    console.log('largest outside 14..18 (double, so ~1e-17: true value is exactly 0):', fmt(Math.max(...rest)));
    console.log('analytic: 0.21 =', fmt(0.21), ' 0.125, 0.02 ; dB', fmt(20 * Math.log10(0.21)), fmt(20 * Math.log10(0.125)), fmt(20 * Math.log10(0.02)));
  }

  console.log('\n// --- DC, N=256, c=1 (bins 0,1,2 = 0.42, 0.25, 0.04) ---');
  {
    const N = 256, m = magnitudes(new Array(N).fill(1), N);
    console.log('bins 0..4:', arr(m.slice(0, 5)), ' dB 0..2:', arr(m.slice(0, 3).map((v) => 20 * Math.log10(v))));
  }

  // ---- 3-frame smoothing, three of tau, bin-centred sine k=16 of N=256, amplitudes 1, .5, 0 ----
  console.log('\n// --- smoothing hand check: bin 16 of N=256, raw 0.21, 0.105, 0 ---');
  for (const tau of [0.4, 0.78]) {
    const N = 256, a = new SpecAnalyser(N, tau), out = [];
    for (const A of [1, 0.5, 0]) {
      const x = Array.from({ length: N }, (_, n) => A * Math.sin((2 * Math.PI * 16 * n) / N));
      a.analyse(x);
      out.push(a.s[16]);
    }
    console.log(`tau ${tau}: s16 after frames =`, arr(out), ' dB =', arr(out.map((v) => 20 * Math.log10(v))));
  }

  // ---- N=32, pseudo-random frames (exact binary fractions, so no input rounding at all) ----
  // frame f: x[n] = ((n*a + b) % m - c) / d, all exactly representable in float32.
  const FRAMES32 = [
    { a: 37, b: 11, m: 17, c: 8, d: 16 },
    { a: 29, b: 5, m: 13, c: 6, d: 8 },
    { a: 13, b: 3, m: 11, c: 5, d: 32 },
  ];
  const frame32 = ({ a, b, m, c, d }) => Array.from({ length: 32 }, (_, n) => (((n * a + b) % m) - c) / d);

  console.log('\n// --- N=32, three frames, 16 bins ---');
  for (const tau of [0, 0.4, 0.78]) {
    const a = new SpecAnalyser(32, tau);
    FRAMES32.forEach((f, i) => {
      a.analyse(frame32(f));
      if (i === 0 || i === 2) {
        console.log(`tau ${tau} after frame ${i + 1}:`);
        console.log('  linear', arr(a.s));
        console.log('  dB    ', arr(a.dB()));
        if (i === 2) console.log('  bytes ', JSON.stringify(a.bytes()));
      }
    });
  }
  console.log('raw first frame magnitudes (tau 0):', arr(magnitudes(frame32(FRAMES32[0]), 32)));

  // ---- N=4096: two-tone signal, selected bins ----
  // x[n] = fround(0.5 sin(2 pi 300.37 n/N + 0.4) + 0.25 sin(2 pi 1234.5 n/N)), tau 0.
  console.log('\n// --- N=4096, off-bin two-tone, tau 0, selected bins ---');
  {
    const N = 4096;
    const x = Array.from({ length: N }, (_, n) =>
      Math.fround(0.5 * Math.sin((2 * Math.PI * 300.37 * n) / N + 0.4) + 0.25 * Math.sin((2 * Math.PI * 1234.5 * n) / N)));
    const m = magnitudes(x, N);
    const bins = [0, 5, 100, 298, 299, 300, 301, 302, 500, 1233, 1234, 1235, 1236, 1500, 2047];
    console.log('bins', JSON.stringify(bins));
    console.log('linear', arr(bins.map((k) => m[k])));
    console.log('dB    ', arr(bins.map((k) => 20 * Math.log10(m[k]))));
    console.log('peak', fmt(Math.max(...m)));
  }

  // ---- padding: 100 samples into N=256 ----
  console.log('\n// --- 100-sample window into N=256 (front zero padded), tau 0, bins 0..7 ---');
  {
    const x = Array.from({ length: 100 }, (_, n) => Math.fround(Math.sin(n * 0.3) * 0.5));
    const a = new SpecAnalyser(256, 0);
    a.analyse(x);
    console.log('linear', arr(a.s.slice(0, 8)));
  }

  // ---- byte conversion at known dB ----
  console.log('\n// --- bytes: dB -> byte at (-100, -30) ---');
  for (const db of [-Infinity, -120, -100, -99.9, -65, -30.5, -30, -10]) {
    const v = Math.floor((255 * (db - -100)) / 70);
    console.log(db, '->', Math.max(0, Math.min(255, v)));
  }
}
