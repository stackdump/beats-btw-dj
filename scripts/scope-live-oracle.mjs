#!/usr/bin/env node
// Oracle for Tests/DJCoreTests/Scopes/LiveBandsOracleTests.swift: two pieces of beats' scope.js
// (pinned at beats-bitwrap-io 095d030) run as the JS runs them, on inputs the Swift tests replay:
//
//   gain      the Scope/Live auto-gain (`readWaveform`'s attack, `drawLive`'s release and spring);
//   residual  the Bands residual (`scopeStats` means, `drawBands` D, its colour-scale limit and
//             the RdBu index).
//
//   node scripts/scope-live-oracle.mjs                 # as JSON
//   node scripts/scope-live-oracle.mjs gain            # one section: gain | residual
//   node scripts/scope-live-oracle.mjs --swift > Tests/DJCoreTests/Scopes/LiveBandsOracleData.swift && make fmt
//
// Nothing here touches the DOM. The statements marked "verbatim" are character-for-character the
// JS; the only change is where the JS reads the clock (`performance.now()` minus the last frame's)
// and the drawing around them. The gain is run with the frame's REAL dt handed in (the JS mixes
// performance.now with audio time: a documented deviation of the port, SCOPES.md), through the
// JS's own clamp `Math.min(0.05, dt)`.

const NB = 5;
const ROWS = NB + 1;
const LEVEL_DB = 4;
const fin = (v) => Number.isFinite(v);

// --- LCG shared with BandsOracleData.make / the Swift tests -------------------------------
function lcg(seed) {
    let x = seed;
    return () => { x = (x * 1664525 + 1013904223) % 4294967296; return x; };
}

// --- gain ---------------------------------------------------------------------------------
// state as `state()` makes it: peak 0.1, disp 0.1, vel 0
function runGain(start, dts, attacks) {
    const s = { peak: start[0], disp: start[1], vel: start[2] };
    const att = new Map(attacks.map(([f, v]) => [f, v]));
    const out = [];
    for (let i = 0; i < dts.length; i++) {
        // verbatim (readWaveform): a block's peak raises the peak at once
        if (att.has(i)) { const pk = att.get(i); if (pk > s.peak) s.peak = pk; }
        // verbatim (drawLive), `now - s.lastT` being the frame's real dt
        const dt = Math.min(0.05, dts[i]);
        s.peak = Math.max(0.05, s.peak * Math.exp(-dt / 7));
        const k = 120, c = 9;
        const a = k * (s.peak - s.disp) - c * s.vel;
        s.vel += a * dt;
        s.disp = Math.max(0.05, s.disp + s.vel * dt);
        if (i % 5 === 0 || i === dts.length - 1) out.push([i, s.peak, s.disp, s.vel]);
    }
    return out;
}

function gainSection() {
    const runs = [];
    const add = (name, start, dts, attacks) =>
        runs.push({ name, start, dts, attacks, samples: runGain(start, dts, attacks) });
    // a step to full scale at 60 fps: the underdamped bounce (~24 % overshoot)
    add('step', [0.1, 0.1, 0], Array(600).fill(1 / 60), [[0, 1.0]]);
    // a loud signal that stops: the 7 s release and the spring following it down, at 30 fps
    add('release', [1, 1, 0], Array(1200).fill(1 / 30), []);
    // frames of every length, stalls past the 50 ms clamp included, with blocks of varying peak
    const next = lcg(777);
    const dts = [], attacks = [];
    for (let i = 0; i < 500; i++) {
        dts.push((next() >>> 16) % 121 / 1000);                    // 0 ... 0.12 s
        if (i % 37 === 0) attacks.push([i, 0.05 + (next() >>> 16) % 100 / 80]);
    }
    add('stall', [0.1, 0.1, 0], dts, attacks);
    // silence from the start: both floor at 0.05
    add('floor', [0.1, 0.1, 0], Array(3000).fill(0.05), []);
    return runs;
}

// --- residual -----------------------------------------------------------------------------
const modelDb = (s, bar, r) => { const v = s.modelBars[bar * ROWS + r]; return v > 0 ? 10 * Math.log10(v) : NaN; };
const measDb = (s, bar, r) => { const n = s.measCnt[bar]; const v = n ? s.measBars[bar * ROWS + r] / n : 0; return v > 0 ? 10 * Math.log10(v) : NaN; };
const fullBar = (s, b) => b * 16 >= Math.max(s.modelFrom, s.measFrom) && (b + 1) * 16 <= s.measAt;

// the same generator as Tests/DJCoreTests/Scopes/BandsTestData.swift (see its header)
function bandsData(kind, modelFrom, measFrom, measAt) {
    const next = lcg(12345);
    const offsets = [-12, -5, 3, 8, -20];
    const bars = 14;
    const modelBars = new Float64Array(1024 * ROWS), measBars = new Float64Array(1024 * ROWS);
    const measCnt = new Float32Array(1024);
    for (let b = 0; b < bars; b++) {
        const reads = 1 + b % 3;
        measCnt[b] = reads;
        let em = 0, ex = 0;
        for (let r = 0; r < NB; r++) {
            const dm = -40 + 0.25 * ((next() >>> 16) % 160);
            const nz = 0.25 * ((next() >>> 16) % 24 - 12);
            const dx = kind === 'main' ? dm * 0.8 + offsets[r] + nz
                : kind === 'same' ? dm + offsets[r] : -dm + offsets[r];
            const pm = Math.pow(10, dm / 10), px = Math.pow(10, dx / 10);
            modelBars[b * ROWS + r] = pm; em += pm;
            measBars[b * ROWS + r] = px * reads; ex += px * reads;
        }
        modelBars[b * ROWS + NB] = em;
        measBars[b * ROWS + NB] = ex;
    }
    return { modelBars, measBars, measCnt, maxBar: bars - 1, modelFrom, measFrom, measAt };
}

function residualFor(kind, modelFrom, measFrom, measAt) {
    const s = bandsData(kind, modelFrom, measFrom, measAt);
    // verbatim (scopeStats): the per-row means over the full bars where both sides have a level
    const meanM = new Float64Array(ROWS), meanX = new Float64Array(ROWS), cntR = new Float64Array(ROWS);
    for (let b = 0; b <= s.maxBar; b++) {
        if (!fullBar(s, b)) continue;
        for (let r = 0; r < ROWS; r++) {
            const m = modelDb(s, b, r), x = measDb(s, b, r);
            if (fin(m) && fin(x)) { meanM[r] += m; meanX[r] += x; cntR[r]++; }
        }
    }
    // verbatim (drawBands)
    const D = (b, r) => {
        if (!fullBar(s, b)) return NaN;
        const m = modelDb(s, b, r), x = measDb(s, b, r);
        if (!fin(m) || !fin(x) || cntR[r] < 1) return NaN;
        return (x - meanX[r] / cntR[r]) - (m - meanM[r] / cntR[r]);
    };
    const limFor = (b0, nBars) => {
        let lim = 6;
        for (let b = b0; b < nBars; b++) for (let r = 0; r < ROWS; r++) { const v = Math.abs(D(b, r)); if (fin(v) && v > lim) lim = v; }
        return Math.min(lim, 24);
    };
    const index = (v, lim) => Math.max(0, Math.min(32, Math.round((v / lim + 1) * 16)));
    const nBars = s.maxBar + 1;
    const ranges = [[0, nBars], [6, nBars], [nBars - 1, nBars], [nBars, nBars], [3, 9]];
    const limits = ranges.map(([b0, n]) => [b0, n, limFor(b0, n)]);
    const lim0 = limits[0][2];
    const cells = [];
    for (let b = 0; b < nBars; b++) for (let r = 0; r < ROWS; r++) {
        const d = D(b, r);
        cells.push([b, r, d, fin(d) ? index(d, lim0) : -1]);
    }
    return { kind, modelFrom, measFrom, measAt, limits, cells };
}

function residualSection() {
    const runs = [
        residualFor('main', 0, 5, 215),
        residualFor('same', 0, 5, 215),
        residualFor('inverted', 0, 5, 215),
        residualFor('main', 0, 20, 200),
    ];
    // the colour index at exact ties: (D / lim + 1) * 16 = n + 0.5, binary-exact for lim 8
    const ties = [];
    for (let n = -2; n <= 34; n++) {
        const v = 8 * ((n + 0.5) / 16 - 1);
        ties.push([v, 8, index2(v, 8)]);
    }
    return { runs, ties };
    function index2(v, lim) { return Math.max(0, Math.min(32, Math.round((v / lim + 1) * 16))); }
}

// --- output -------------------------------------------------------------------------------
const sections = { gain: gainSection, residual: residualSection };

function num(v) {
    if (Number.isNaN(v)) return 'Double.nan';
    return Number.isInteger(v) ? v.toFixed(1) : String(v);
}
const arr = (xs) => '[' + xs.map(num).join(', ') + ']';

function swift() {
    const g = gainSection();
    const r = residualSection();
    const o = [];
    o.push('// GENERATED by scripts/scope-live-oracle.mjs --swift from the pinned beats sources (095d030).');
    o.push('// Do not edit: regenerate. What scope.js computes for the inputs LiveBandsOracleTests replays.');
    o.push('');
    o.push('struct GainOracleRun {');
    o.push('  var name: String');
    o.push('  var start: [Double]');
    o.push('  var dts: [Double]');
    o.push('  /// (frame, block peak)');
    o.push('  var attacks: [[Double]]');
    o.push('  /// (frame, peak, disp, vel) after the frame');
    o.push('  var samples: [[Double]]');
    o.push('}');
    o.push('');
    o.push('struct ResidualOracleRun {');
    o.push('  var kind: String');
    o.push('  var modelFrom: Int');
    o.push('  var measFrom: Double');
    o.push('  var measAt: Double');
    o.push('  /// (first bar, bar count, scale limit)');
    o.push('  var limits: [[Double]]');
    o.push('  /// (bar, row, D or NaN, RdBu index at the first limit or -1)');
    o.push('  var cells: [[Double]]');
    o.push('}');
    o.push('');
    o.push('enum LiveBandsOracle {');
    o.push('  static let gain: [GainOracleRun] = [');
    for (const run of g) {
        o.push(`    GainOracleRun(name: "${run.name}", start: ${arr(run.start)}, dts: ${arr(run.dts)},`);
        o.push(`      attacks: [${run.attacks.map(arr).join(', ')}],`);
        o.push(`      samples: [${run.samples.map(arr).join(', ')}]),`);
    }
    o.push('  ]');
    o.push('  static let residual: [ResidualOracleRun] = [');
    for (const run of r.runs) {
        o.push(`    ResidualOracleRun(kind: "${run.kind}", modelFrom: ${run.modelFrom}, measFrom: ${num(run.measFrom)}, measAt: ${num(run.measAt)},`);
        o.push(`      limits: [${run.limits.map(arr).join(', ')}],`);
        o.push(`      cells: [${run.cells.map(arr).join(', ')}]),`);
    }
    o.push('  ]');
    o.push('  /// (D, limit, index)');
    o.push(`  static let ties: [[Double]] = [${r.ties.map(arr).join(', ')}]`);
    o.push('}');
    return o.join('\n') + '\n';
}

const args = process.argv.slice(2);
if (args.includes('--swift')) {
    process.stdout.write(swift());
} else {
    const which = args.find((a) => !a.startsWith('--'));
    const out = {};
    for (const [name, fn] of Object.entries(sections)) if (!which || which === name) out[name] = fn();
    console.log(JSON.stringify(out, null, 1));
}
