#!/usr/bin/env node
// Parity harness for the deferred composer features (ROADMAP 2.8): arrangeWithOpts,
// the overlay directives (fadeIn, drumBreak, feelCurve, macroCurve, counterMelody) and
// the share `tracks` / `fx` / `initialMutes` overrides. Same rules as beats-parity.mjs:
// the JS is the oracle and is only ever imported (or, for module-private bits, lifted
// verbatim from the source text so it cannot drift); nothing is re-implemented.
//
//   BEATS_PUBLIC=~/Workspace/beats-bitwrap-io/public node scripts/beats-arrange.mjs [outDir]
//   node scripts/beats-arrange.mjs --dump <section>:<index>   (debug, writes nothing)
//
// Output: Tests/DJCoreTests/Fixtures/beats/arrange.json. Deterministic: rerunning against
// the same beats commit is a no-op diff.
//
// --dump prints the full JS document (JSON.stringify(projectToJSON(parsed)), the bytes behind
// `docSha`) of case <index> in <section> (overlays, arranges, docs, shares, overrides) and
// exits. The Swift side writes its own on a mismatch when DJ_ARRANGE_DUMP=<dir> is set
// (BeatsArrangeTests), so a failing case can be diffed field by field.

import { readFileSync, writeFileSync, writeSync, mkdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC = path.resolve(process.env.BEATS_PUBLIC || path.join(process.env.HOME, 'Workspace/beats-bitwrap-io/public'));
const argv = process.argv.slice(2);
const dumpAt = argv.indexOf('--dump');
const DUMP = dumpAt >= 0 ? (() => { const [section, index] = argv[dumpAt + 1].split(':'); return { section, index: Number(index) }; })() : null;
if (dumpAt >= 0) argv.splice(dumpAt, 2);
const outDir = path.resolve(argv[0] || path.join(here, '../Tests/DJCoreTests/Fixtures/beats'));
const lib = (p) => import(pathToFileURL(path.join(PUBLIC, 'lib', p)).href);

const codec = await lib('share/codec.js');
const pflow = await lib('pflow.js');
const gen = await lib('generator/index.js');
const composerMod = await lib('generator/composer.js');
const arrange = await lib('generator/arrange.js');
const url = await lib('share/url.js');

const sha256hex = (s) => createHash('sha256').update(s, 'utf8').digest('hex');
const clone = (x) => JSON.parse(JSON.stringify(x));
let beatsCommit = 'unknown';
try { beatsCommit = execFileSync('git', ['-C', PUBLIC, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(); } catch {}
const meta = { generator: 'scripts/beats-arrange.mjs', beatsCommit };

// --- lifted source -------------------------------------------------------

const arrangeSrc = readFileSync(path.join(PUBLIC, 'lib/generator/arrange.js'), 'utf8');
function liftConst(name) {
  const m = arrangeSrc.match(new RegExp(`const ${name} = (\\{[\\s\\S]*?\\n\\});`));
  if (!m) throw new Error(`${name} not found in arrange.js`);
  return new Function(`return (${m[1]});`)();
}
const tables = {
  families: liftConst('FAMILIES'),
  blueprints: liftConst('BLUEPRINTS'),
  archetypes: liftConst('ARCHETYPES'),
  archetypesByFamily: liftConst('ARCHETYPES_BY_FAMILY'),
};

// share/apply.js: strip the browser-only imports and run the real functions on a stub
// element. `toneEngine`/feel helpers are never reached by the cases below.
const applySrc = readFileSync(path.join(PUBLIC, 'lib/share/apply.js'), 'utf8')
  .replace(/^import .*$/gm, '').replace(/^export function/gm, 'function');
const applyShareOverrides = new Function('toneEngine', 'sanitizePuck', 'applyFeelGrid',
  `${applySrc}; return applyShareOverrides;`)({}, (x) => x, () => {});
function stubEl(project) {
  const noop = () => {};
  const el = { _project: project, _channelInstruments: {}, _toneStarted: false,
    querySelector: () => null, querySelectorAll: () => [], _sendWs: noop, _renderMixer: noop };
  return el;
}

// petri-note.js deriveShareName (module-private), with composer's generateTrackName in scope.
const petriSrc = readFileSync(path.join(PUBLIC, 'petri-note.js'), 'utf8');
const dm = petriSrc.match(/function deriveShareName\(share\) \{[\s\S]*?\n\}\n/);
if (!dm) throw new Error('deriveShareName not found');
const deriveShareName = new Function('generateTrackName', `${dm[0]}; return deriveShareName;`)(composerMod.generateTrackName);

// --- digests -------------------------------------------------------------

const normalized = (proj) => {
  for (const [id, nb] of Object.entries(proj.nets)) if (!(nb instanceof pflow.NetBundle)) proj.nets[id] = pflow.parseNetBundle(nb);
  return proj;
};
let lastDoc = null;
const digest = (proj) => {
  // What the worker does with a project-load: parse. (initialMutes etc. ride along.)
  const parsed = pflow.parseProject(clone(pflow.projectToJSON(normalized(proj))));
  const canonical = pflow.canonicalProjectJSON(parsed);
  lastDoc = JSON.stringify(pflow.projectToJSON(parsed));
  return { nets: Object.keys(parsed.nets).length, counter: Object.keys(parsed.nets).filter((id) => id.startsWith('counter-melody-')).length, canonicalBytes: Buffer.byteLength(canonical), modelCID: sha256hex(canonical),
    docSha: sha256hex(lastDoc) };
};
// A throw (the JS arrange has real ones) is part of the oracle.
const attempt = (fn) => { lastDoc = null; try { return fn(); } catch (e) { return { error: String(e && e.message || e).slice(0, 80) }; } };
// Every fixture row goes through here, so --dump can stop at the one asked for.
function record(list, section, row) {
  list.push(row);
  if (DUMP && DUMP.section === section && DUMP.index === list.length - 1) {
    if (row.result && row.result.error) console.error(`JS threw: ${row.result.error}`);
    writeSync(1, (lastDoc ?? 'null') + '\n'); // sync: process.exit would cut a piped write short
    process.exit(0);
  }
}

const baseCache = new Map();
function composeBase(genre, seed, structure, cohesion) {
  const o = { seed, cohesion };
  if (structure) o.structure = structure;
  return normalized(gen.compose(genre, o));
}
const wireOf = (proj) => ({ name: proj.name, tempo: proj.tempo, swing: proj.swing, humanize: proj.humanize,
  nets: clone(pflow.projectToJSON(normalized(clone2(proj))).nets) });
// projectToJSON needs NetBundles; rebuild an independent copy via the doc.
function clone2(proj) { return pflow.parseProject(clone(pflow.projectToJSON(proj))); }

// --- A. overlays on composed projects (the share composer path) -----------

const overlays = [];
function runOverlay(b, opts) {
  const proj = composeBase(b.genre, b.seed, b.structure, b.cohesion);
  return attempt(() => { arrange.arrangeWithOpts(proj, b.genre, '', { overlayOnly: true, ...clone(opts) }); return digest(proj); });
}
const GEN8 = ['techno', 'house', 'jazz', 'ambient', 'edm', 'synthwave', 'trance', 'funk'];
const bases = [];
for (const genre of GEN8) for (const seed of [1, 42]) for (const structure of ['minimal', 'standard', 'extended']) for (const cohesion of ['v1', 'v2'])
  bases.push({ genre, seed, structure, cohesion });

const netIds = (proj, re) => Object.keys(proj.nets).filter((id) => re.test(id) && proj.nets[id].role !== 'control');
const directiveSets = [
  (p) => ({ fadeIn: ['bass'] }),
  (p) => ({ fadeIn: ['kick', 'melody', 'hihat', 'nonesuch'] }),
  (p) => ({ fadeIn: ['melody', 'melody'] }),
  (p) => ({ fadeIn: [] }),
  (p) => ({ drumBreak: 1 }), (p) => ({ drumBreak: 2 }), (p) => ({ drumBreak: 0.25 }), (p) => ({ drumBreak: 0.3 }),
  (p) => ({ drumBreak: 100 }), (p) => ({ drumBreak: -1 }), (p) => ({ drumBreak: 0 }), (p) => ({ drumBreak: 4.5 }),
  (p) => { const s = p.structure.map((x) => x.name); return { feelCurve: [{ section: s[0], x: 0.2, y: 0.9 }, { section: s[Math.floor(s.length / 2)], x: 1, y: 0.1 }, { section: s[s.length - 1], x: 0.5, y: 0.5 }] }; },
  (p) => { const s = p.structure.map((x) => x.name); return { feelCurve: [{ section: s[0], x: 0.3 }, { section: 'nope', x: 1, y: 1 }, { section: s[0], x: 0.9, y: 0.9 }, { section: s[1], y: null }, { section: s[s.length - 1], x: 'hi', y: 0.25 }] }; },
  (p) => ({ feelCurve: [] }),
  (p) => { const s = p.structure.map((x) => x.name); return { macroCurve: [{ section: s[0], macro: 'fade', bars: 4 }, { section: s[1], macro: 'riser' }, { section: s[1], macro: 0 }, { section: 'nope', macro: 'x' }] }; },
  (p) => { const s = p.structure.map((x) => x.name); return { fadeIn: ['bass', 'melody'], drumBreak: 2, feelCurve: [{ section: s[0], x: 0.1, y: 0.2 }], macroCurve: [{ section: s[0], macro: 'fade', bars: 2 }] }; },
];
const counterSets = [
  (p) => { const s = p.structure.map((x) => x.name); return { counterMelody: [{ section: s[0], mode: 'answer' }] }; },
  (p) => { const s = p.structure.map((x) => x.name); return { counterMelody: [{ section: s[Math.floor(s.length / 2)], mode: 'harmony', density: 0.8, register: 'below', of: netIds(p, /^melody/)[0] }] }; },
  (p) => { const s = p.structure.map((x) => x.name); return { counterMelody: [{ section: s[s.length - 1], mode: 'shadow', density: 0.0078125, instrument: 'vibes' }] }; },
  (p) => { const s = p.structure.map((x) => x.name); return { counterMelody: [{ section: s[0], mode: 'answer', density: 0.9, of: netIds(p, /^melody/)[0] }, { section: s[1], mode: 'shadow', density: 1, register: 'below', of: netIds(p, /^bass/)[0] }] }; },
  (p) => { const s = p.structure.map((x) => x.name); return { counterMelody: [{ section: s[0], mode: 'answer' }, { section: s[1], mode: 'harmony' }] }; },
  (p) => ({ counterMelody: [{ section: 'nope', mode: 'answer' }] }),
  (p) => { const s = p.structure.map((x) => x.name); return { counterMelody: [{ section: s[1], mode: 'bogus', density: 0 }, { section: s[1], mode: 'answer', density: 7, register: 'sideways', of: 'struct-stop' }] }; },
  (p) => { const s = p.structure.map((x) => x.name); return { counterMelody: [{ section: s[0], mode: 'harmony', density: 0.33333333, of: netIds(p, /^kick/)[0] }, { section: s[s.length - 1], mode: 'answer', density: 0.123456789, of: 'harmony' }] }; },
  (p) => { const s = p.structure.map((x) => x.name); return { fadeIn: ['melody'], drumBreak: 1, counterMelody: [{ section: s[0], mode: 'answer', density: 0.5, of: netIds(p, /^melody/)[0] }] }; },
];
bases.forEach((b, bi) => {
  const key = `${b.genre}/${b.seed}/${b.structure}/${b.cohesion}`;
  const probe = composeBase(b.genre, b.seed, b.structure, b.cohesion);
  baseCache.set(key, true);
  directiveSets.forEach((mk, k) => {
    if ((bi + k) % 9 !== 0) return;
    const opts = mk(probe);
    record(overlays, 'overlays', { ...b, opts, result: runOverlay(b, opts) });
  });
  counterSets.forEach((mk, k) => {
    if ((bi + k * 5) % 19 !== 0) return;
    const opts = mk(probe);
    record(overlays, 'overlays', { ...b, opts, result: runOverlay(b, opts) });
  });
});
// A loop project has no structure: overlayOnly must be a no-op.
for (const genre of ['techno', 'jazz']) {
  const proj = composeBase(genre, 5, '', 'v2');
  const before = digest(clone2(proj));
  const opts = { fadeIn: ['bass'], drumBreak: 2, counterMelody: [{ section: 'x', mode: 'answer' }] };
  arrange.arrangeWithOpts(proj, genre, '', { overlayOnly: true, ...opts });
  record(overlays, 'overlays', { genre, seed: 5, structure: '', cohesion: 'v2', opts, result: digest(proj), noop: before.modelCID });
}

// Coverage: every overlay directive completes in at least one v1 and one v2 case per genre
// (a counter-melody one must also add a net). Added deterministically after the rotation above.
const OVERLAY_KEYS = ['fadeIn', 'drumBreak', 'feelCurve', 'macroCurve', 'counterMelody'];
const overlayCovered = (genre, cohesion, key) => overlays.some((o) => o.genre === genre && o.cohesion === cohesion
  && o.opts[key] !== undefined && !o.result.error && (key !== 'counterMelody' || o.result.counter > 0));
for (const genre of GEN8) for (const cohesion of ['v1', 'v2']) for (const key of OVERLAY_KEYS) {
  if (overlayCovered(genre, cohesion, key)) continue;
  const sets = [...directiveSets, ...counterSets];
  search: for (const b of bases.filter((x) => x.genre === genre && x.cohesion === cohesion)) {
    const probe = composeBase(b.genre, b.seed, b.structure, b.cohesion);
    for (const mk of sets) {
      const opts = mk(probe);
      if (opts[key] === undefined || (Array.isArray(opts[key]) && opts[key].length === 0)) continue;
      const result = runOverlay(b, opts);
      if (result.error || (key === 'counterMelody' && !(result.counter > 0))) continue;
      record(overlays, 'overlays', { ...b, opts, result });
      break search;
    }
  }
  if (!overlayCovered(genre, cohesion, key)) throw new Error(`no overlay case covers ${key} for ${genre}/${cohesion}`);
}

// Object.prototype names: in a plain-object lookup they find an inherited function, not
// undefined. resolveCurvePoints keeps such a point (so the net is built) at a tick that never
// matches a transition. And JS TypeErrors on null entries.
for (const b of [bases.find((x) => x.genre === 'techno' && x.seed === 42 && x.structure === 'standard' && x.cohesion === 'v2'),
                 bases.find((x) => x.genre === 'jazz' && x.seed === 1 && x.structure === 'minimal' && x.cohesion === 'v1')]) {
  const s = composeBase(b.genre, b.seed, b.structure, b.cohesion).structure.map((x) => x.name);
  for (const opts of [
    { feelCurve: [{ section: 'toString', x: 0.1, y: 0.2 }] },
    { feelCurve: [{ section: s[0], x: 0.3, y: 0.3 }, { section: '__proto__', x: 1, y: 1 }, { section: s[1], x: 0.5, y: 0.6 }, { section: 'constructor' }, { section: s[0], x: 0.9, y: 0.1 }] },
    { macroCurve: [{ section: 'constructor', macro: 'fade', bars: 2 }] },
    { macroCurve: [{ section: 'valueOf', macro: 'riser' }, { section: s[1], macro: 'fade' }, { section: 'hasOwnProperty', macro: 'x' }] },
    { counterMelody: [{ section: 'toString', mode: 'answer' }] },
    { fadeIn: ['constructor', 'bass'] },
    { feelCurve: [null] },
    { macroCurve: [{ section: s[0], macro: 'fade' }, null] },
    { fadeIn: [null, 'bass'] },
    { fadeIn: ['bass'], drumBreak: 1, counterMelody: [null] },
    { fadeIn: [5, ['melody'], 'bass'] },
  ]) record(overlays, 'overlays', { ...b, opts, result: runOverlay(b, opts) });
}

// --- B. the JS counterMelody reality check on unparsed (wire) projects ----

const wireProbe = [];
for (const [genre, seed] of [['techno', 42], ['house', 7]]) {
  const wire = { ...wireOf(composeBase(genre, seed, 'standard', 'v2')) };
  const proj = { ...wire, nets: clone(wire.nets) };
  proj.structure = composeBase(genre, seed, 'standard', 'v2').structure;
  const threw = attempt(() => { arrange.arrangeWithOpts(proj, genre, '', { overlayOnly: true, counterMelody: [{ section: proj.structure[0].name, mode: 'answer' }] }); return {}; });
  wireProbe.push({ genre, seed, error: threw.error || null });
}

// --- C. full arrangeWithOpts on loop projects -----------------------------

const arranges = [];
// `genre` defaults to the source's; a row with `genre` arranges under that name instead.
function runArrange(src, size, form, opts, genre = src.genre) {
  const base = composeBase(src.genre, src.seed, '', src.cohesion);
  const input = form === 'parsed' ? base : (() => { const w = wireOf(base); w.initialMutes = base.initialMutes; return w; })();
  return attempt(() => { arrange.arrangeWithOpts(input, genre, size, clone(opts)); return digest(input); });
}
const sources = [];
for (const genre of ['techno', 'jazz', 'ambient', 'edm', 'funk', 'synthwave']) for (const seed of [1, 42]) sources.push({ genre, seed, cohesion: seed === 1 ? 'v1' : 'v2' });
const sizes = ['minimal', 'standard', 'extended', 'ab', 'drop', 'build', 'jam', '', 'bogus'];
const optSets = [
  () => ({ seed: 3 }),
  () => ({ seed: 7, velocityDeltas: { A: 0, B: 30, C: -40, D: 5, E: 200 } }),
  () => ({ seed: 11, maxVariants: 1 }),
  () => ({ seed: 12, maxVariants: 2 }),
  () => ({ seed: 13, fadeIn: ['bass', 'melody'], drumBreak: 2 }),
  () => ({ seed: 14, sections: [{ name: 'intro', steps: 64, active: ['kick', 'hihat'] }, { name: 'drop', steps: 128, active: ['kick', 'snare', 'bass', 'melody', 'ghost'] }, { name: 'outro', steps: 0, active: ['melody'] }] }),
  () => ({ seed: 15, feelCurve: [{ section: 'intro', x: 0.2, y: 0.8 }, { section: 'drop', x: 1, y: 0 }], macroCurve: [{ section: 'intro', macro: 'fade', bars: 4 }, { section: 'drop', macro: 'riser' }] }),
  () => ({}),
  () => ({ seed: 16, counterMelody: [{ section: 'drop', mode: 'answer', density: 0.7, of: 'melody-0' }, { section: 'intro', mode: 'harmony', of: 'bass-0' }] }),
  () => ({ seed: 17, counterMelody: [{ section: 'drop', mode: 'shadow' }, { section: 'verse', mode: 'answer', density: 0.4, register: 'below' }] }),
  () => ({ seed: 19, counterMelody: [{ section: 'verse', mode: 'shadow', density: 0.9, of: 'snare' }, { section: 'drop', mode: 'harmony', of: 'snare' }, { section: 'intro', of: 'snare', density: 0.75 }] }),
  () => ({ seed: 18, counterMelody: [{ section: 'intro', mode: 'harmony', density: 0.6, instrument: 'strings' }] }),
  () => ({ seed: 4294967299, velocityDeltas: {}, maxVariants: 3, fadeIn: ['kick'], drumBreak: 1 }),
  () => ({ seed: -9, overlayOnly: false, sections: [{ name: 'verse', steps: 96, active: ['bass'] }, { name: 'chorus', active: ['bass', 'melody', 'harmony'] }] }),
];
sources.forEach((src, si) => sizes.forEach((size, zi) => {
  for (const pick of [(si * 5 + zi * 3 + zi) % optSets.length]) {
    for (const form of ['parsed', 'wire']) {
      const opts = optSets[pick]();
      record(arranges, 'arranges', { source: src, size, form, opts, result: runArrange(src, size, form, opts) });
    }
  }
}));

// Counter-melody scoped to a net that arrange never clones (`snare` keeps one slot): the only
// full-arrange shape where the JS counter-melody completes. Parsed and wire input both.
for (const src of sources.slice(0, 8)) for (const size of ['standard', 'extended']) for (const form of ['parsed', 'wire']) {
  const opts = { seed: 21, counterMelody: [{ section: 'verse', mode: 'shadow', density: 0.9, of: 'snare' }, { section: 'drop', mode: 'harmony', of: 'snare' }, { section: 'chorus', mode: 'answer', density: 0.75, of: 'snare' }] };
  record(arranges, 'arranges', { source: src, size, form, opts, result: runArrange(src, size, form, opts) });
}

// maxVariants 1 keeps every role in one slot, so nothing is cloned and an unscoped
// counter-melody can simulate the parsed nets (later entries are scoped to original nets: an
// unscoped second entry would reach the first counter net, a plain object, and throw).
const counterArrange = { seed: 22, maxVariants: 1, counterMelody: [{ section: 'verse', mode: 'answer' },
  { section: 'drop', mode: 'harmony', of: 'bass', density: 0.8 }, { section: 'chorus', mode: 'shadow', of: 'melody' },
  { section: 'solo', mode: 'answer', of: 'melody', register: 'below' }, { section: 'intro', mode: 'harmony', of: 'hihat' }] };

// Coverage: every option completes in at least one v1 and one v2 case per genre, in both
// input forms where the JS can (a counter-melody on wire input always throws: plain nets).
const ARRANGE_KEYS = ['velocityDeltas', 'maxVariants', 'fadeIn', 'drumBreak', 'sections', 'feelCurve', 'macroCurve', 'counterMelody'];
const arrangeCovered = (src, key, form) => arranges.some((a) => a.source === src && a.form === form && a.opts[key] !== undefined
  && !a.result.error && (key !== 'counterMelody' || a.result.counter > 0));
for (const src of sources) for (const key of ARRANGE_KEYS) for (const form of key === 'counterMelody' ? ['parsed'] : ['parsed', 'wire']) {
  if (arrangeCovered(src, key, form)) continue;
  search: for (const mk of [...optSets, () => counterArrange]) {
    const opts = mk();
    if (opts[key] === undefined) continue;
    for (const size of ['standard', 'extended', 'minimal', 'ab', 'drop', 'build', 'jam']) {
      const result = runArrange(src, size, form, opts);
      if (result.error || (key === 'counterMelody' && !(result.counter > 0))) continue;
      record(arranges, 'arranges', { source: src, size, form, opts, result });
      break search;
    }
  }
  if (!arrangeCovered(src, key, form)) throw new Error(`no arrange case covers ${key} for ${src.genre}/${src.cohesion}/${form}`);
}

// Object.prototype names as size (blueprint.map of undefined: throws), as genre (a function
// family: song blueprints, no family archetypes) and as authored section names; null entries.
for (const src of [sources.find((x) => x.genre === 'techno' && x.cohesion === 'v2'), sources.find((x) => x.genre === 'jazz' && x.cohesion === 'v1')]) {
  for (const form of ['parsed', 'wire']) {
    for (const size of ['constructor', 'toString', '__proto__']) record(arranges, 'arranges', { source: src, size, form, opts: { seed: 3 }, result: runArrange(src, size, form, { seed: 3 }) });
    for (const [genre, size, opts] of [['constructor', 'standard', { seed: 5 }], ['toString', 'extended', { seed: 6, fadeIn: ['bass'] }], ['__proto__', 'minimal', { seed: 7 }],
      ['hasOwnProperty', 'standard', { seed: 9, maxVariants: 2, drumBreak: 1 }]]) {
      record(arranges, 'arranges', { source: src, genre, size, form, opts, result: runArrange(src, size, form, opts, genre) });
    }
    for (const opts of [
      { seed: 8, maxVariants: 1, sections: [{ name: 'intro', steps: 32, active: ['kick', 'hihat'] }, { name: 'constructor', steps: 64, active: ['kick', 'bass', 'melody', 'snare'] },
        { name: 'toString', steps: 64, active: ['bass'] }, { name: 'outro', steps: 32, active: ['melody'] }],
        feelCurve: [{ section: 'constructor', x: 0.5, y: 0.5 }, { section: 'outro', x: 0, y: 1 }], macroCurve: [{ section: 'toString', macro: 'fade' }, { section: 'intro', macro: 'riser', bars: 2 }],
        counterMelody: [{ section: 'constructor', mode: 'answer' }] },
      { seed: 10, sections: [null] },
      { seed: 11, fadeIn: [null, 'bass'], drumBreak: 2 },
      { seed: 12, maxVariants: 1, counterMelody: [{ section: 'verse', mode: 'answer' }, null] },
      { seed: 13, velocityDeltas: { A: 2.5, B: -0.5, C: 0.5, D: 1e9 } },
    ]) record(arranges, 'arranges', { source: src, size: 'standard', form, opts, result: runArrange(src, 'standard', form, opts) });
  }
}

// Hand-authored wire documents: no durations, sparse bindings, odd names, a stinger.
const handDocs = [
  { name: 'Hand A', tempo: 100, nets: {
      kick: { track: { channel: 10, instrument: 'drums-808' }, places: { p0: { initial: [1] }, p1: {}, p2: {}, p3: {} },
        transitions: { t0: { midi: { note: 36 } }, t1: {}, t2: { midi: { note: 36, velocity: 80 } }, t3: {} },
        arcs: [{ source: 'p0', target: 't0' }, { source: 't0', target: 'p1' }, { source: 'p1', target: 't1' }, { source: 't1', target: 'p2' },
          { source: 'p2', target: 't2' }, { source: 't2', target: 'p3' }, { source: 'p3', target: 't3' }, { source: 't3', target: 'p0' }] },
      lead: { track: { channel: 2, instrument: 'lead', defaultVelocity: 90 }, places: { p0: { initial: [1] }, p1: {} },
        transitions: { t0: { midi: { note: 64, duration: 250 } }, t1: { midi: { note: 67, durationSteps: 3, velocity: 70 } } },
        arcs: [{ source: 'p0', target: 't0' }, { source: 't0', target: 'p1' }, { source: 'p1', target: 't1' }, { source: 't1', target: 'p0' }] },
      'lead-pad': { track: { channel: 3 }, places: { p0: { initial: [1] } }, transitions: { t0: { midi: { note: 50, duration: 100.4 } } }, arcs: [{ source: 'p0', target: 't0' }, { source: 't0', target: 'p0' }] },
    } },
  { name: 'Hand B', tempo: 133.5, swing: 0.2, initialMutes: ['hit1'], nets: {
      bass: { track: { channel: 1 }, riffGroup: 'bass', places: { p0: { initial: [1] }, p1: {} },
        transitions: { t0: { midi: { note: 40, duration: 120 } }, t1: { midi: { note: 43 } } },
        arcs: [{ source: 'p0', target: 't0' }, { source: 't0', target: 'p1' }, { source: 'p1', target: 't1' }, { source: 't1', target: 'p0' }] },
      hit1: { track: { channel: 12, group: 'stinger' }, places: { p0: { initial: [1] } }, transitions: { t0: { midi: { note: 60 } } }, arcs: [{ source: 'p0', target: 't0' }, { source: 't0', target: 'p0' }] },
      hat: { track: { channel: 11 }, places: { p0: { initial: [1] } }, transitions: { t0: { midi: { note: 42, velocity: 60, duration: 50 } } }, arcs: [{ source: 'p0', target: 't0' }, { source: 't0', target: 'p0' }] },
    } },
  // The stamp reads the raw JSON: 224.6 ms at 100 bpm is 1.497 steps (1), the parsed 225 would
  // be 1.5 (2); a positive raw durationSteps blocks it even when the parse drops it ("3", 0.4).
  { name: 'Hand C', tempo: 100, nets: {
      keys: { track: { channel: 4, instrument: 'piano' }, places: { p0: { initial: [1] }, p1: {}, p2: {}, p3: {} },
        transitions: { t0: { midi: { note: 60, duration: 224.6 } }, t1: { midi: { note: 62, duration: 300, durationSteps: '3' } },
          t2: { midi: { note: 64, duration: 300, durationSteps: 0.4 } }, t3: { midi: { note: 65, duration: -5 } } },
        arcs: [{ source: 'p0', target: 't0' }, { source: 't0', target: 'p1' }, { source: 'p1', target: 't1' }, { source: 't1', target: 'p2' },
          { source: 'p2', target: 't2' }, { source: 't2', target: 'p3' }, { source: 'p3', target: 't3' }, { source: 't3', target: 'p0' }] },
      pad: { track: { channel: 5 }, places: { p0: { initial: [1] } }, transitions: { t0: {} }, arcs: [{ source: 'p0', target: 't0' }, { source: 't0', target: 'p0' }],
        bindings: { t0: { note: 48, duration: 2400.5 } } },
    } },
];
const docs = [];
for (const doc of handDocs) for (const [size, opts] of [
  ['standard', { seed: 1 }], ['extended', { seed: 2, velocityDeltas: { A: 10, B: 20, C: 30 }, fadeIn: ['bass', 'lead'], drumBreak: 1 }],
  ['minimal', { seed: 3, maxVariants: 1, feelCurve: [{ section: 'intro', x: 0.4, y: 0.6 }] }], ['jam', { seed: 4, sections: [{ name: 'verse', steps: 64, active: ['kick', 'lead', 'bass'] }, { name: 'solo', steps: 64, active: ['lead', 'bass', 'hat'] }] }],
]) {
  const proj = clone(doc);
  const result = attempt(() => { arrange.arrangeWithOpts(proj, 'house', size, clone(opts)); return digest(proj); });
  record(docs, 'docs', { doc, genre: 'house', size, opts, result });
}

// --- D. whole share envelopes (the pipeline petri-note.js builds) ---------

function runShare(payloadIn, cid, netsFrom) {
  const payload = clone(payloadIn);
  if (netsFrom) payload.nets = wireOf(composeBase(netsFrom.genre, netsFrom.seed, '', netsFrom.cohesion)).nets;
  const share = url.shareFromPayload(payload, cid);
  const hasOverrides = !!share.overrides;
  if (share.nets) {
    const proj = { name: share.name || deriveShareName(share), tempo: share.overrides?.tempo ?? 120,
      swing: share.overrides?.swing ?? 0, humanize: share.overrides?.humanize ?? 0, nets: share.nets };
    if (share.overrides?.initialMutes) proj.initialMutes = share.overrides.initialMutes;
    if (share.overrides?.fx) proj.fx = share.overrides.fx;
    if (share.structure && share.structure !== 'loop') {
      const opts = { seed: share.arrangeSeed ?? 0, velocityDeltas: share.velocityDeltas || undefined, maxVariants: share.maxVariants || 0,
        fadeIn: share.fadeIn || undefined, drumBreak: share.drumBreak || 0, sections: share.sections || undefined,
        feelCurve: share.feelCurve || undefined, macroCurve: share.macroCurve || undefined };
      try { arrange.arrangeWithOpts(proj, share.genre || 'wrapped', share.structure, opts); } catch { /* console.warn, carry on */ }
    }
    const parsed = pflow.parseProject(clone(proj));            // worker project-load
    if (hasOverrides) applyShareOverrides(stubEl(parsed), share.overrides);
    return digest(parsed);
  }
  const proj = normalized(gen.compose(share.genre, clone(share.params)));
  if (hasOverrides) applyShareOverrides(stubEl(proj), share.overrides);
  // The overlay runs on the parsed project (function-level behaviour; see the ROADMAP for the
  // browser's plain-JSON overlay). A throw is caught and the half-built project never reaches
  // the worker: the composed one plays.
  if (share.fadeIn || share.drumBreak || share.feelCurve || share.counterMelody) {
    const overlaid = clone2(proj);
    try {
      arrange.arrangeWithOpts(overlaid, share.genre || 'wrapped', '', { overlayOnly: true, fadeIn: share.fadeIn || undefined,
        drumBreak: share.drumBreak || undefined, feelCurve: share.feelCurve || undefined, counterMelody: share.counterMelody || undefined });
      return digest(overlaid);
    } catch { /* console.warn('overlay arrange failed') */ }
  }
  return digest(proj);
}
const shareCases = [
  { payload: { genre: 'techno', seed: 42, structure: 'standard', cohesion: 'v2', fadeIn: ['bass'], drumBreak: 2 } },
  { payload: { genre: 'house', seed: 7, structure: 'extended', cohesion: 'v2', feelCurve: [{ section: 'intro', x: 0.2, y: 0.7 }, { section: 'drop', x: 1, y: 0.2 }] } },
  { payload: { genre: 'trance', seed: 8, structure: 'standard', cohesion: 'v2', counterMelody: [{ section: 'drop', mode: 'answer', density: 0.6, of: 'melody-0' }] } },
  { payload: { genre: 'edm', seed: 9, structure: 'standard', cohesion: 'v2', counterMelody: [{ section: 'drop', mode: 'harmony', density: 0.9 }], fadeIn: ['melody'] } },
  { payload: { genre: 'techno', seed: 10, structure: 'standard', cohesion: 'v2', initialMutes: ['hit1', 'kick-0'], fadeIn: ['melody'], drumBreak: 1,
      tracks: { 10: { mix: { vol: 0.5, pan: -0.25 } }, 1: { instrument: 'vibes', instrumentSet: ['vibes', 'marimba'] }, abc: { instrument: 'x' } },
      fx: { reverbWet: 0.3, _bypassed: true }, note: 'a note' } },
  { payload: { genre: 'jazz', seed: 3, structure: 'minimal', cohesion: 'v1', drumBreak: 1, feelCurve: [{ section: 'intro', x: 0.1, y: 0.2 }],
      macroCurve: [{ section: 'intro', macro: 'fade', bars: 2 }] } },
  { payload: { genre: 'techno', seed: 5, cohesion: 'v2', fadeIn: ['bass'], drumBreak: 2, counterMelody: [{ section: 'x' }] } },
  { payload: { genre: 'ambient', seed: 6, structure: 'standard', cohesion: 'v2', fadeIn: [], drumBreak: 0 } },
  { payload: { genre: 'funk', seed: 11, structure: 'standard', cohesion: 'v1', tracks: { 12: { mix: { vol: 0.9 } } }, fx: { delayWet: 0.1 }, tempo: 99, swing: 0.5, humanize: 0.3 } },
  { netsFrom: { genre: 'techno', seed: 42, cohesion: 'v2' }, payload: { genre: 'techno', structure: 'standard', arrangeSeed: 5 } },
  { netsFrom: { genre: 'house', seed: 7, cohesion: 'v1' }, payload: { genre: 'house', structure: 'extended', arrangeSeed: 6, name: 'Raw <&> "named"', velocityDeltas: { A: 5, B: 25 }, maxVariants: 2,
      fadeIn: ['bass', 'melody'], drumBreak: 2, feelCurve: [{ section: 'intro', x: 0.3, y: 0.4 }], macroCurve: [{ section: 'intro', macro: 'fade', bars: 4 }] } },
  { netsFrom: { genre: 'jazz', seed: 3, cohesion: 'v2' }, payload: { genre: 'jazz', structure: 'loop', tempo: 140, swing: 0.3, humanize: 0.2, initialMutes: ['hit2'],
      tracks: { 2: { instrument: 'piano', mix: { vol: 0.4 } } }, fx: { reverbWet: 0.2 } } },
  { netsFrom: { genre: 'ambient', seed: 8, cohesion: 'v2' }, payload: { genre: 'ambient', structure: 'minimal', arrangeSeed: 2, sections: [
      { name: 'intro', steps: 64, active: ['kick', 'bass'] }, { name: 'verse', steps: 128, active: ['bass', 'melody', 'harmony'] }] } },
  { netsFrom: { genre: 'techno', seed: 1, cohesion: 'v1' }, payload: { structure: 'extended', arrangeSeed: 77 } },
  { netsFrom: { genre: 'techno', seed: 2, cohesion: 'v2' }, payload: { genre: 'techno', structure: 'standard', arrangeSeed: 4, counterMelody: [{ section: 'drop', mode: 'answer' }] } },
  { netsFrom: { genre: 'edm', seed: 3, cohesion: 'v2' }, payload: { genre: 'edm', arrangeSeed: 4, fadeIn: ['bass'] } },
  // A structure naming an Object.prototype property: arrange throws before it changes anything
  // but the stamp (finally); the browser catches it and loads the nets as they are.
  { netsFrom: { genre: 'techno', seed: 4, cohesion: 'v2' }, payload: { genre: 'techno', structure: 'constructor', arrangeSeed: 1, fadeIn: ['bass'] } },
  { netsFrom: { genre: 'house', seed: 5, cohesion: 'v1' }, payload: { genre: 'toString', structure: 'standard', arrangeSeed: 2, drumBreak: 1 } },
  // Overlay throws after the song structure (null fadeIn role): caught, the arranged project loads.
  { netsFrom: { genre: 'funk', seed: 6, cohesion: 'v2' }, payload: { genre: 'funk', structure: 'standard', arrangeSeed: 3, fadeIn: [null, 'bass'], drumBreak: 2 } },
  { netsFrom: { genre: 'jazz', seed: 7, cohesion: 'v1' }, payload: { genre: 'jazz', structure: 'extended', arrangeSeed: 4, initialMutes: ['bass-0'], tracks: { 6: { instrument: 'vibes' } },
      feelCurve: [{ section: 'toString', x: 1, y: 1 }, { section: 'intro', x: 0.2, y: 0.4 }], macroCurve: [{ section: 'constructor', macro: 'fade' }] } },
  { payload: { genre: 'techno', seed: 12, structure: 'standard', cohesion: 'v2', feelCurve: [{ section: 'toString', x: 0.5, y: 0.5 }] } },
  { payload: { genre: 'house', seed: 13, structure: 'standard', cohesion: 'v1', fadeIn: ['bass'], counterMelody: [{ section: 'intro', mode: 'answer' }, null] } },
  { payload: { genre: 'synthwave', seed: 14, structure: 'extended', cohesion: 'v2', initialMutes: [], counterMelody: [{ section: 'chorus', mode: 'harmony', of: 'melody' }] } },
];
const shares = [];
for (const c of shareCases) {
  const cidPayload = clone(c.payload);
  if (c.netsFrom) cidPayload.nets = wireOf(composeBase(c.netsFrom.genre, c.netsFrom.seed, '', c.netsFrom.cohesion)).nets;
  const cid = await codec.computeCidForJsonLd(cidPayload);
  const result = attempt(() => runShare(c.payload, cid, c.netsFrom));
  record(shares, 'shares', { payload: c.payload, netsFrom: c.netsFrom || null, cid, result });
}

// --- E. share overrides on composed projects ------------------------------

const overrideCases = [
  { tracks: { 10: { mix: { vol: 0.5 } } } },
  { tracks: { 1: { instrument: 'vibes' }, 2: { instrument: 'piano', instrumentSet: ['piano', 'vibes', 'marimba'], mix: { pan: 0.4, vol: 0.8 } } } },
  { tracks: { ' 11': { mix: { vol: 0.2 } }, '12abc': { instrument: 'x' }, 'zz': { instrument: 'nope' }, '-1': { instrument: 'neg' }, 7.0: { mix: { vol: 1 } } } },
  { tracks: { 10: {} , 11: { mix: null, instrument: '' } } },
  { fx: { reverbWet: 0.4, delayWet: 0.2, _bypassed: true } },
  { initialMutes: ['kick', 'bass'] },
  { initialMutes: [] },
  { note: 'hello', tempo: 90, swing: 0.2, humanize: 0.1 },
  { tracks: { 10: { mix: { vol: 0.3 } } }, fx: { reverbWet: 0.1 }, initialMutes: ['melody'], note: 'n' },
];
const overrides = [];
for (const [genre, seed, structure] of [['techno', 42, ''], ['house', 7, 'minimal'], ['jazz', 3, 'standard']]) {
  const none = digest(composeBase(genre, seed, structure, 'v2'));
  overrideCases.forEach((ov) => {
    const proj = composeBase(genre, seed, structure, 'v2');
    applyShareOverrides(stubEl(proj), clone(ov));
    const result = digest(proj);
    record(overrides, 'overrides', { genre, seed, structure, cohesion: 'v2', ov, result, plain: none.docSha });
  });
}

// --- write ----------------------------------------------------------------

const counts = { overlays: overlays.length, arranges: arranges.length, docs: docs.length, shares: shares.length, overrides: overrides.length };
const errors = [...overlays, ...arranges, ...docs, ...shares].filter((x) => x.result.error).map((x) => x.result.error);
const counterNets = overlays.filter((o) => o.opts.counterMelody && !o.result.error).length;
if (DUMP) { console.error(`no case ${DUMP.section}:${DUMP.index}`); process.exit(1); }
console.log(JSON.stringify(counts), 'errors:', errors.length, [...new Set(errors)], 'counter overlays ok:', counterNets, 'wireProbe:', JSON.stringify(wireProbe));
mkdirSync(outDir, { recursive: true });
writeFileSync(path.join(outDir, 'arrange.json'), JSON.stringify({ meta, tables, overlays, wireProbe, arranges, docs, shares, overrides }) + '\n');
console.log('wrote arrange.json');
