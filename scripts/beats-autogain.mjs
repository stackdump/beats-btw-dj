#!/usr/bin/env node
// Scope auto-gain fixtures (ROADMAP 6). beats' scope.js is a DOM module that cannot be
// imported headless, so this script runs the SAME formulas, copied from
// public/lib/ui/scope.js (drawLive + readWaveform, commit 095d030), over a scripted
// sequence of block peaks and frame times. It first checks that the source file still
// contains those exact expressions, so a change in beats shows up here rather than as a
// silent drift.
//
//   BEATS_PUBLIC=~/Workspace/beats-bitwrap-io/public node scripts/beats-autogain.mjs
//
// Output: Tests/DJCoreTests/Fixtures/beats/autogain.json

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC = path.resolve(process.env.BEATS_PUBLIC || path.join(process.env.HOME, 'Workspace/beats-bitwrap-io/public'));
const outFile = path.resolve(process.argv[2] || path.join(here, '../Tests/DJCoreTests/Fixtures/beats/autogain.json'));

const src = readFileSync(path.join(PUBLIC, 'lib/ui/scope.js'), 'utf8');
for (const needle of [
    'const dt = Math.min(0.05, now - (s.lastT || now)); s.lastT = now;',
    's.peak = Math.max(0.05, s.peak * Math.exp(-dt / 7));',
    'const k = 120, c = 9;',
    'const a = k * (s.peak - s.disp) - c * s.vel;',
    's.vel += a * dt;',
    's.disp = Math.max(0.05, s.disp + s.vel * dt);',
    'if (pk > s.peak) s.peak = pk;',
    'peak: 0.1,',
]) {
    if (!src.includes(needle)) { console.error(`scope.js no longer contains: ${needle}`); process.exit(1); }
}
let beatsCommit = process.env.BEATS_COMMIT || '095d030 (reference copy)';
try { beatsCommit = execFileSync('git', ['-C', PUBLIC, 'rev-parse', 'HEAD'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); } catch {}

// state as scope.js `state()` builds it
const s = { peak: 0.1, disp: 0.1, vel: 0, lastT: 0 };

// readWaveform's per-block raise
function raise(pk) { if (pk > s.peak) s.peak = pk; }
// drawLive's per-frame step, with `now` standing in for performance.now() / 1000
function frame(now) {
    const dt = Math.min(0.05, now - (s.lastT || now)); s.lastT = now;
    s.peak = Math.max(0.05, s.peak * Math.exp(-dt / 7));
    const k = 120, c = 9;
    const a = k * (s.peak - s.disp) - c * s.vel;
    s.vel += a * dt;
    s.disp = Math.max(0.05, s.disp + s.vel * dt);
}

// Deterministic script: loud bursts, long silences (decay to the floor), frame gaps over
// the 0.05 clamp, and a first frame at a large `now` (dt 0).
let seed = 12345;
const rnd = () => (seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0) / 4294967296;
const ops = [];
let now = 1000.123;
for (let i = 0; i < 1200; i++) {
    const quiet = i > 400 && i < 800; // long silence: the peak decays to the floor
    const r = rnd(), pk = Math.round(rnd() * 1000) / 1000;
    if (!quiet && r < 0.08) ops.push({ op: 'raise', pk });
    now += rnd() < 0.05 ? 0.2 + rnd() : 0.008 + rnd() * 0.02;
    ops.push({ op: 'frame', now });
}
const trace = [];
for (const o of ops) {
    if (o.op === 'raise') raise(o.pk); else frame(o.now);
    trace.push([s.peak, s.disp, s.vel]);
}

mkdirSync(path.dirname(outFile), { recursive: true });
writeFileSync(outFile, JSON.stringify({ beatsCommit, ops, trace }));
console.log(`wrote ${outFile}: ${ops.length} ops, final peak ${s.peak.toFixed(4)} disp ${s.disp.toFixed(4)} (beats ${beatsCommit.slice(0, 7)})`);
