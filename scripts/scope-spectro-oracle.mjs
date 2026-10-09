#!/usr/bin/env node
// Oracle for Tests/DJCoreTests/Scopes/Spectro*Tests.swift and MeasuredReaderTests.swift: the pure
// numerics of beats' scope.js drawSpectro / freqLabels / ensureAnalyser / readMeasured (pinned at
// beats-bitwrap-io 095d030), copied verbatim, run on the synthetic inputs the Swift tests build,
// printed as JSON or as a Swift file. The Swift tests pin these literals.
//
//   node scripts/scope-spectro-oracle.mjs                 # all sections, as JSON
//   node scripts/scope-spectro-oracle.mjs bins            # one: lut | bins | power | labels | model | measured
//   node scripts/scope-spectro-oracle.mjs --swift > Tests/DJCoreTests/Scopes/SpectroOracleData.swift && make fmt
//   node scripts/scope-spectro-oracle.mjs --swift --only=lut,labels,model     # just those sections
//
// Nothing here touches the DOM: the blocks marked "verbatim" are character-for-character the JS,
// with the state object `s` and the canvas cut away. The synthetic inputs use only values that
// are exact in float32 and doubles (powers of two, multiples of a quarter), so that the only
// libm in play is log10/pow, whose last-digit differences between engines cannot move a result
// across a threshold the tests look at.

const BANDS = [[20, 80], [80, 250], [250, 2000], [2000, 6000], [6000, 16000]];
const NB = BANDS.length;
const NS = 28;
const SPEC_EDGES = new Float64Array(NS + 1);
for (let i = 0; i <= NS; i++) SPEC_EDGES[i] = 30 * Math.pow(16000 / 30, i / NS);
const NR = NB + NS;
const SPEC_CAP = 2048;
const FFT_SIZE = 4096;
const MSPEC_CAP = 512;
const WINDOW_STEPS = 64;

// --- verbatim: lut + MAGMA --------------------------------------------------------
function lut(stops) {
    const out = new Uint8Array(256 * 3);
    for (let i = 0; i < 256; i++) {
        const x = i / 255 * (stops.length - 1);
        const a = Math.min(stops.length - 2, Math.floor(x)), f = x - a;
        for (let c = 0; c < 3; c++) out[i * 3 + c] = Math.round(stops[a][c] + (stops[a + 1][c] - stops[a][c]) * f);
    }
    return out;
}
const MAGMA = lut([[0, 0, 4], [40, 11, 84], [101, 21, 110], [159, 42, 99], [212, 72, 66], [245, 125, 21], [250, 193, 39], [252, 253, 191]]);

// --- verbatim: ensureAnalyser's bin tables --------------------------------------------
function binTables(sr) {
    const binLo = new Int32Array(NR), binHi = new Int32Array(NR);
    const df = sr / FFT_SIZE, edges = [];
    for (const [lo, hi] of BANDS) edges.push([lo, hi]);
    for (let i = 0; i < NS; i++) edges.push([SPEC_EDGES[i], SPEC_EDGES[i + 1]]);
    edges.forEach(([lo, hi], j) => {
        const a = Math.max(1, Math.round(lo / df));
        binLo[j] = a; binHi[j] = Math.min(FFT_SIZE / 2, Math.max(a + 1, Math.round(hi / df)));
    });
    return { binLo: Array.from(binLo), binHi: Array.from(binHi) };
}

// --- verbatim: readMeasured's power sum ------------------------------------------------
function rowPower(fd, binLo, binHi) {
    const p = new Float32Array(NR);
    for (let j = 0; j < NR; j++) {
        let sum = 0;
        for (let k = binLo[j]; k < binHi[j]; k++) { const db = fd[k]; if (db > -200) sum += Math.pow(10, db / 10); }
        p[j] = sum;
    }
    return p;
}

// --- verbatim: freqLabels' placement -------------------------------------------------
function freqLabelYs(y0, h) {
    const lo = Math.log(SPEC_EDGES[0]), hi = Math.log(SPEC_EDGES[NS]);
    const out = [];
    for (const [f, label] of [[50, '50'], [200, '200'], [1000, '1k'], [4000, '4k'], [12000, '12k']]) {
        const y = y0 + h - (Math.log(f) - lo) / (hi - lo) * h;
        out.push([label, Math.max(y0, Math.min(y0 + h - 10, y - 5))]);
    }
    return out;
}

// --- verbatim: the model image's loops ----------------------------------------------------
function modelImage(s, first) {
    const cols = WINDOW_STEPS + 2;
    const d = new Uint8Array(cols * NS * 4), lv = new Uint8Array(cols * NS);   // lv: the LUT index, recorded
    let mx = -Infinity;
    for (let c = 0; c < cols; c++) {
        const st = first + c;
        if (st < 0 || st >= s.specCur || s.specStep[st % SPEC_CAP] !== st) continue;
        const o = (st % SPEC_CAP) * NS;
        for (let j = 0; j < NS; j++) { const v = s.specCol[o + j]; if (v > 0) { const db = 10 * Math.log10(v); if (db > mx) mx = db; } }
    }
    const floor = mx - 50;
    const fin = Number.isFinite;
    for (let c = 0; c < cols; c++) {
        const st = first + c;
        const valid = st >= 0 && st < s.specCur && s.specStep[st % SPEC_CAP] === st && fin(mx);
        const o = (st % SPEC_CAP) * NS;
        for (let j = 0; j < NS; j++) {
            const p = ((NS - 1 - j) * cols + c) * 4;
            let li = 0;
            if (valid) { const v = s.specCol[o + j]; li = v > 0 ? (10 * Math.log10(v) - floor) / 50 * 255 : 0; }
            li = Math.max(0, Math.min(255, li | 0)) * 3;
            d[p] = MAGMA[li]; d[p + 1] = MAGMA[li + 1]; d[p + 2] = MAGMA[li + 2]; d[p + 3] = 255;
            lv[p / 4] = li / 3;
        }
    }
    return { mx, d, lv, cols };
}

// --- verbatim: the measured image's loops (the ring as the JS keeps it) ---------------------
function measuredImage(s, ax) {
    const COLS = 160;
    const d = new Uint8Array(COLS * NS * 4), lv = new Uint8Array(COLS * NS);   // lv: the LUT index, recorded
    const fin = Number.isFinite;
    let mx = -Infinity;
    for (let k = 1; k <= s.mspCount; k++) {
        const i = (s.mspHead - k + MSPEC_CAP) % MSPEC_CAP;
        if (s.mspT[i] < ax.t0) break;
        for (let j = 0; j < NS; j++) if (s.mspV[i * NS + j] > mx) mx = s.mspV[i * NS + j];
    }
    const floor = mx - 50;
    let k = s.mspCount;
    for (let c = 0; c < COLS; c++) {
        const tc = ax.t0 + (c + 1) * ax.win / COLS;
        while (k > 1) {
            const nxt = (s.mspHead - (k - 1) + MSPEC_CAP) % MSPEC_CAP;
            if (s.mspT[nxt] <= tc) k--; else break;
        }
        const i = (s.mspHead - k + MSPEC_CAP) % MSPEC_CAP;
        const valid = s.mspCount > 0 && fin(mx) && s.mspT[i] <= tc && s.mspT[i] >= tc - 0.25;
        for (let j = 0; j < NS; j++) {
            const p = ((NS - 1 - j) * COLS + c) * 4;
            let li = valid ? (s.mspV[i * NS + j] - floor) / 50 * 255 : 0;
            li = Math.max(0, Math.min(255, li | 0)) * 3;
            d[p] = MAGMA[li]; d[p + 1] = MAGMA[li + 1]; d[p + 2] = MAGMA[li + 2]; d[p + 3] = 255;
            lv[p / 4] = li / 3;
        }
    }
    return { mx, d, lv, cols: COLS };
}

// --- the recorded LUT indices as rows of hex pairs, row 0 first ---------------------------------
function levels(img) {
    const rows = [];
    for (let y = 0; y < NS; y++) {
        let row = '';
        for (let x = 0; x < img.cols; x++) row += img.lv[y * img.cols + x].toString(16).padStart(2, '0');
        rows.push(row);
    }
    return rows;
}

// --- the synthetic scenarios (the Swift tests build the same) --------------------------------

// literal (dB, floor) pairs through the cell formula, including `| 0` truncation and the clamp
const cellPairs = [
    [-10, -60], [-35, -60], [-34.9, -60], [-59.99, -60], [-60, -60], [-60.01, -60], [-100, -60],
    [0, -50], [-25, -50], [-24.9, -50], [-0.01, -50], [5, -50], [2.5, -50], [-49.9, -50],
    [-12.345, -62.345], [30.1, -19.9], [-200, -150], [-150, -200],
];

// dB per FFT bin: exact in float32; -inf, exactly -200, and -199.75 sprinkled in
function powerDb() {
    const fd = new Float32Array(FFT_SIZE / 2);
    for (let k = 0; k < fd.length; k++) {
        let db = -150 + ((k * 37) % 101) * 0.75;
        if (k % 11 === 0) db = -Infinity;
        else if (k % 13 === 0) db = -200;
        else if (k % 17 === 0) db = -199.75;
        fd[k] = db;
    }
    return fd;
}

function modelScenario() {
    const specCol = new Float32Array(SPEC_CAP * NS), specStep = new Int32Array(SPEC_CAP).fill(-1);
    const cur = 200;
    for (let st = 0; st < cur; st++) {
        if (st === 150 || st === 151) continue;           // two columns whose slot was never written
        specStep[st % SPEC_CAP] = st;
        for (let j = 0; j < NS; j++) {
            const e = ((st * 13 + j * 7) % 40) - 20;
            specCol[(st % SPEC_CAP) * NS + j] = (st + j) % 23 === 0 ? 0 : Math.pow(2, e);
        }
    }
    // a stale slot: step 3's slot (3) is overwritten by step 3 + 2048 in the ring, not by a final one
    return { specCol, specStep, specCur: cur };
}

function measuredScenario() {
    const s = {
        mspT: new Float64Array(MSPEC_CAP), mspV: new Float32Array(MSPEC_CAP * NS), mspHead: 0, mspCount: 0,
    };
    for (let i = 0; i < 700; i++) {
        if (i >= 560 && i < 590) continue;                // a gap of 30 frames (1 s): older than 0.25 s
        const w = s.mspHead, o = w * NS;
        s.mspT[w] = 100 + i / 30;
        for (let j = 0; j < NS; j++) s.mspV[o + j] = -120 + ((i * 5 + j * 11) % 60);
        s.mspHead = (w + 1) % MSPEC_CAP;
        if (s.mspCount < MSPEC_CAP) s.mspCount++;
    }
    const tNow = 100 + 699 / 30 + 0.01, win = 8;
    return { s, ax: { t0: tNow - win, win } };
}

function run(only) {
    const want = (name) => !only || only.has(name);
    const out = {};
    if (want('lut')) {
        out.lutSamples = [0, 1, 2, 37, 63, 100, 127, 128, 200, 254, 255].map(i => [i, MAGMA[i * 3], MAGMA[i * 3 + 1], MAGMA[i * 3 + 2]]);
        out.cells = cellPairs.map(([db, floor]) => {
            const li = (db - floor) / 50 * 255;
            return [db, floor, Math.max(0, Math.min(255, li | 0))];
        });
    }
    if (want('bins')) {
        out.bins = {};
        for (const sr of [44100, 48000, 22050]) out.bins[sr] = binTables(sr);
    }
    if (want('power')) {
        const fd = powerDb();
        out.power = {};
        for (const sr of [44100, 22050]) {
            const t = binTables(sr);
            out.power[sr] = Array.from(rowPower(fd, t.binLo, t.binHi));
        }
    }
    if (want('labels')) {
        out.labels = { full: freqLabelYs(0, 318), second: freqLabelYs(162, 156), small: freqLabelYs(0, 40) };
    }
    if (want('model')) {
        const m = modelScenario();
        out.model = {};
        for (const first of [140, -3, 195]) {
            const img = modelImage(m, first);
            out.model[first] = { mx: img.mx, rows: levels(img) };
        }
    }
    if (want('measured')) {
        const { s, ax } = measuredScenario();
        const img = measuredImage(s, ax);
        out.measured = { mx: img.mx, rows: levels(img) };
    }
    return out;
}

function swiftFile(o) {
    const L = [];
    L.push('// GENERATED by scripts/scope-spectro-oracle.mjs --swift from the pinned beats sources (095d030).');
    L.push('// Do not edit: regenerate. These are what scope.js computes for the inputs the Spectro tests');
    L.push('// build (see the script for the vectors).');
    L.push('');
    L.push('enum SpectroOracle {');
    if (o.lutSamples) {
        L.push('  /// MAGMA bytes at an index: [index, r, g, b]');
        L.push(`  static let lutSamples: [[Int]] = ${JSON.stringify(o.lutSamples)}`);
        L.push('  /// (dB, floor, level)');
        L.push(`  static let cells: [[Double]] = ${JSON.stringify(o.cells)}`);
    }
    if (o.bins) {
        for (const sr of [44100, 48000, 22050]) {
            L.push(`  static let binLo${sr}: [Int] = ${JSON.stringify(o.bins[sr].binLo)}`);
            L.push(`  static let binHi${sr}: [Int] = ${JSON.stringify(o.bins[sr].binHi)}`);
        }
    }
    if (o.power) for (const sr of [44100, 22050]) L.push(`  static let power${sr}: [Double] = ${JSON.stringify(o.power[sr])}`);
    if (o.labels) for (const k of ['full', 'second', 'small']) L.push(`  static let labels${k[0].toUpperCase() + k.slice(1)}: [[Double]] = ${JSON.stringify(o.labels[k].map(([, y]) => [y]))}`);
    if (o.model) {
        for (const first of [140, -3, 195]) {
            const id = first < 0 ? 'Neg' + -first : String(first);
            L.push(`  static let modelPeak${id}: Double = ${o.model[first].mx}`);
            L.push(`  static let modelRows${id}: [String] = [`);
            for (const r of o.model[first].rows) L.push(`    "${r}",`);
            L.push('  ]');
        }
    }
    if (o.measured) {
        L.push(`  static let measuredPeak: Double = ${o.measured.mx}`);
        L.push('  static let measuredRows: [String] = [');
        for (const r of o.measured.rows) L.push(`    "${r}",`);
        L.push('  ]');
    }
    L.push('}');
    return L.join('\n') + '\n';
}

const args = process.argv.slice(2);
const swift = args.includes('--swift');
const onlyArg = args.find(a => a.startsWith('--only='));
const section = args.find(a => !a.startsWith('--'));
const only = onlyArg ? new Set(onlyArg.slice(7).split(',')) : section && !swift ? new Set([section]) : undefined;
const result = run(only);
process.stdout.write(swift ? swiftFile(result) : JSON.stringify(result, null, 1) + '\n');
