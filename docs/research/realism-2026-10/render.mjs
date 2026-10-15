// Render whole songs with beats' offline wave engine; measure spectrum, per-bar loudness.
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { writeFileSync, mkdirSync } from 'node:fs';
import os from 'node:os';

const PUBLIC = path.join(process.env.HOME, 'Workspace/beats-bitwrap-io/public');
const imp = (p) => import(pathToFileURL(path.join(PUBLIC, p)).href);
const { renderOffline, encodeWav, composeProject } = await imp('wave-engine/offline.js');

const SR = 48000;
const outDir = process.env.WAV_DIR || path.join(os.tmpdir(), 'realism-wav');
mkdirSync(outDir, { recursive: true });

function fft(re, im) {
  const n = re.length;
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) { [re[i], re[j]] = [re[j], re[i]]; [im[i], im[j]] = [im[j], im[i]]; }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const ang = (-2 * Math.PI) / len;
    for (let i = 0; i < n; i += len) {
      for (let k = 0; k < len / 2; k++) {
        const wr = Math.cos(ang * k), wi = Math.sin(ang * k);
        const ur = re[i + k], ui = im[i + k];
        const vr = re[i + k + len / 2] * wr - im[i + k + len / 2] * wi;
        const vi = re[i + k + len / 2] * wi + im[i + k + len / 2] * wr;
        re[i + k] = ur + vr; im[i + k] = ui + vi;
        re[i + k + len / 2] = ur - vr; im[i + k + len / 2] = ui - vi;
      }
    }
  }
}

function octaveBands(x) {
  const N = 8192, hop = N; const centers = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
  const pow = new Float64Array(N / 2);
  const win = Float64Array.from({ length: N }, (_, i) => 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / (N - 1)));
  let frames = 0;
  for (let off = 0; off + N <= x.length; off += hop) {
    const re = new Float64Array(N), im = new Float64Array(N);
    for (let i = 0; i < N; i++) re[i] = x[off + i] * win[i];
    fft(re, im);
    for (let k = 0; k < N / 2; k++) pow[k] += re[k] * re[k] + im[k] * im[k];
    frames++;
  }
  const bands = centers.map((c) => {
    const lo = c / Math.SQRT2, hi = c * Math.SQRT2; let s = 0;
    for (let k = 1; k < N / 2; k++) { const f = (k * SR) / N; if (f >= lo && f < hi) s += pow[k]; }
    return s / Math.max(1, frames);
  });
  const ref = bands[5] || 1e-30; // 1 kHz
  const db = bands.map((b) => +(10 * Math.log10(Math.max(b, 1e-30) / ref)).toFixed(1));
  // slope 63 Hz..8 kHz (least squares, dB per octave)
  const xs = [], ys = [];
  for (let i = 1; i <= 8; i++) { xs.push(i); ys.push(db[i]); }
  const mx = xs.reduce((a, b) => a + b) / xs.length, my = ys.reduce((a, b) => a + b) / ys.length;
  const slope = xs.reduce((a, x, i) => a + (x - mx) * (ys[i] - my), 0) / xs.reduce((a, x) => a + (x - mx) ** 2, 0);
  return { centers, db, slope: +slope.toFixed(2) };
}

const cases = (process.argv[2] || 'techno:42,house:42,dnb:42,trance:42,lofi:42,ambient:42,jazz:42,trap:42').split(',').map((s) => s.split(':'));
const results = [];
for (const [genre, seedS] of cases) {
  const seed = +seedS;
  const project = composeProject(genre, seed, 'standard');
  const totalSteps = project.structure.reduce((a, s) => a + s.steps, 0);
  const seconds = Math.min(240, (totalSteps * 60) / project.tempo / 4 + 1);
  const t0 = Date.now();
  const { left, right } = renderOffline({ project, seconds, sampleRate: SR });
  const ms = Date.now() - t0;
  const mono = new Float32Array(left.length); for (let i = 0; i < left.length; i++) mono[i] = 0.5 * (left[i] + right[i]);
  // per-bar RMS dB
  const barSamples = Math.round((4 * 60 * SR) / project.tempo);
  const barDb = [];
  for (let off = 0; off + barSamples <= mono.length; off += barSamples) {
    let s = 0; for (let i = off; i < off + barSamples; i++) s += mono[i] * mono[i];
    barDb.push(+(10 * Math.log10(s / barSamples + 1e-20)).toFixed(1));
  }
  // section mean dB
  let pos = 0; const secDb = [];
  for (const s of project.structure) { const b0 = pos / 16, b1 = (pos + s.steps) / 16; const v = barDb.slice(b0, b1); secDb.push(`${s.name}:${(v.reduce((a, b) => a + b, 0) / v.length).toFixed(1)}`); pos += s.steps; }
  // side/mid ratio
  let m2 = 0, s2 = 0; for (let i = 0; i < left.length; i++) { const m = left[i] + right[i], sd = left[i] - right[i]; m2 += m * m; s2 += sd * sd; }
  const spec = octaveBands(mono);
  const file = path.join(outDir, `${genre}-${seed}.wav`);
  writeFileSync(file, encodeWav([left, right], SR));
  results.push({ genre, seed, seconds: +seconds.toFixed(1), renderMs: ms, file, spectrum: spec, sideToMidDb: +(10 * Math.log10(s2 / m2 + 1e-20)).toFixed(1), secDb: secDb.join(' '), barDbRange: +(Math.max(...barDb) - Math.min(...barDb.filter((x) => x > -90))).toFixed(1) });
  console.log(genre, seed, `${seconds.toFixed(0)}s in ${ms}ms`, 'slope', spec.slope, 'bands', spec.db.join(','), 'S/M', results.at(-1).sideToMidDb, '|', secDb.join(' '));
}
writeFileSync(new URL('./audio.json', import.meta.url), JSON.stringify(results, null, 1));
