#!/usr/bin/env node
// Parity harness (ROADMAP 2.2): import beats' real JS and write fixtures the
// Swift tests compare byte-for-byte. The JS is the oracle; nothing here
// re-implements it except `canonicalStringify`, which pflow.js does not export —
// it is lifted verbatim from the source text so it cannot drift.
//
//   BEATS_PUBLIC=~/Workspace/beats-bitwrap-io/public node scripts/beats-parity.mjs [outDir]
//
// Output: Tests/DJCoreTests/Fixtures/beats/{foundation,modules,envelopes,projects}.json
// Everything is deterministic: rerunning against the same beats commit must be a
// no-op diff (the harness sorts nothing it does not have to and uses no clocks).

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC = path.resolve(process.env.BEATS_PUBLIC || path.join(process.env.HOME, 'Workspace/beats-bitwrap-io/public'));
const outDir = path.resolve(process.argv[2] || path.join(here, '../Tests/DJCoreTests/Fixtures/beats'));
const lib = (p) => import(pathToFileURL(path.join(PUBLIC, 'lib', p)).href);

const codec = await lib('share/codec.js');
const pflow = await lib('pflow.js');
const core = await lib('generator/core.js');
const euclid = await lib('generator/euclidean.js');
const structure = await lib('generator/structure.js');
const theme = await lib('generator/theme.js');
const gen = await lib('generator/index.js');
const url = await lib('share/url.js');

// canonicalStringify is module-private in pflow.js: extract it from the source.
const pflowSrc = readFileSync(path.join(PUBLIC, 'lib/pflow.js'), 'utf8');
const m = pflowSrc.match(/function canonicalStringify\(v\) \{[\s\S]*?\n\}\n/);
if (!m) throw new Error('canonicalStringify not found in pflow.js');
const canonicalStringify = new Function(`${m[0]}; return canonicalStringify;`)();

const sha256hex = (s) => createHash('sha256').update(s, 'utf8').digest('hex');
const f64bits = (d) => { const b = new DataView(new ArrayBuffer(8)); b.setFloat64(0, d); return b.getBigUint64(0).toString(16).padStart(16, '0'); };
const bitsToF64 = (h) => { const b = new DataView(new ArrayBuffer(8)); b.setBigUint64(0, BigInt('0x' + h)); return b.getFloat64(0); };
const hex = (u8) => Buffer.from(u8).toString('hex');

let beatsCommit = 'unknown';
try { beatsCommit = execFileSync('git', ['-C', PUBLIC, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(); } catch {}
const meta = { generator: 'scripts/beats-parity.mjs', beatsCommit };

// --- foundation ---------------------------------------------------------

// Deterministic spread of doubles: edge cases + pseudo-random bit patterns.
const numberBits = new Set();
const edge = [0, -0, 1, -1, 0.5, 0.1, 0.2, 0.1 + 0.2, 1 / 3, 100, 123456789, 1e20, 1e21, 1.5e21, 123456789012345680000, 1e-5, 1e-6, 1e-7, 1.5e-7, 0.000001234,
  5e-324, 2.2250738585072014e-308, 1.7976931348623157e308, 2 ** 53, 2 ** 53 + 2, -(2 ** 31), 2 ** 31, 2 ** 32, 4294967295, 4294967296.5, 0.30000000000000004,
  120, 128.5, 0.07, 0.35, 440, 261.6255653005986, 1e100, 1.2345e-10, 9.999999999999999e22, 1e23, NaN, Infinity, -Infinity];
for (const d of edge) numberBits.add(f64bits(d));
{
  const r = core.createRng(20261008);
  for (let i = 0; i < 200; i++) {
    // random mantissa/exponent spread, kept finite
    const hi = Math.floor(r.next() * 0x7fe00000) | 0, lo = Math.floor(r.next() * 4294967296) >>> 0;
    const sign = r.next() < 0.5 ? 0 : 0x80000000;
    const dv = new DataView(new ArrayBuffer(8));
    dv.setUint32(0, (hi | sign) >>> 0); dv.setUint32(4, lo);
    numberBits.add(f64bits(dv.getFloat64(0)));
    // plain decimals like the ones composers use
    numberBits.add(f64bits(Math.round(r.next() * 100000) / 1000));
    numberBits.add(f64bits(Math.floor(r.next() * 4000000000) - 2000000000));
  }
}
const numbers = [...numberBits].map((bits) => {
  const d = bitsToF64(bits);
  return { bits, str: String(d), json: JSON.stringify(d), int32: d | 0 };
});

const jsonInputs = [
  '{}', '[]', 'null', 'true', '"x"', '0', '-0', '1.50', '1e3', '12345678901234567890',
  '{"b":1,"a":2}', '{"a":1,"a":2,"b":3}', '{"10":"x","9":"y","b":1,"01":"z","a":2,"4294967295":"max","4294967294":"lim"}',
  '{"nested":{"z":[1,2,{"y":null,"x":true}],"a":"<&>"}}',
  '"a<b>c&d\\u2028\\u2029e"', '"tab\\there\\nnl \\"q\\" \\\\ \\/ \\u0001 \\u001f \\u007f"',
  '"é ñ 日本語 😀 \\ud83d\\ude00"', '{"é":1,"e":2,"😀":3,"\\uffff":4,"z":5}',
  '[1,2.5,-3e-7,1e21,1e-7,0.1,100000000000000000000]',
  ' { "pad" : [ 1 , 2 ] } ',
  '{"name":"techno · aurora-7","tempo":128,"nets":{"drums":{"places":{"p0":{"initial":[1]}}}}}',
];
const json = jsonInputs.map((input) => {
  const v = JSON.parse(input);
  return { input, stringified: JSON.stringify(v), canonical: codec.canonicalizeJSON(v), canonicalGo: canonicalStringify(v) };
});

const rngSeeds = [0, 1, 2, 42, 12345, 20261008, -1, -5, 2147483647, 2147483648, 4294967295, 4294967296 + 7, 1.5, 99999999999, 1e10, 3735928559];
const rng = rngSeeds.map((seed) => {
  const a = core.createRng(seed), b = core.createRng(seed), c = core.createRng(seed);
  return {
    seed,
    next: Array.from({ length: 24 }, () => f64bits(a.next())),
    nextInt7: Array.from({ length: 24 }, () => b.nextInt(7)),
    nextInt63: Array.from({ length: 8 }, () => c.nextInt63()),
  };
});

const b58 = [
  '', '00', '0000', '01', '00ff', 'ff', 'deadbeef', '0000deadbeef', '00'.repeat(32), 'ff'.repeat(32),
  '0129' + '12' + '20' + '00'.repeat(32), '01a9021220' + createHash('sha256').update('x').digest('hex'),
].map((h) => ({ hex: h, b58: codec.encodeBase58(Buffer.from(h, 'hex')) }));

const cidInputs = ['', '{}', '[]', '{"a":1}', '{"genre":"techno","seed":42}', 'héllo <&> 😀', '{"b":1,"a":2}'];
const cids = [];
for (const input of cidInputs) {
  const h = await codec.sha256(input);
  cids.push({ input, sha256: hex(h), cidBytes: hex(codec.createCIDv1Bytes(h)), cid: 'z' + codec.encodeBase58(codec.createCIDv1Bytes(h)) });
}

writeFileSync0('foundation.json', { meta, numbers, json, rng, base58: b58, cids });

// --- module vectors -----------------------------------------------------

const bjorklund = [];
for (let n = 1; n <= 16; n++) for (let k = 0; k <= n + 1; k++) bjorklund.push({ k, n, bits: euclid.bjorklund(k, n) });
for (const [k, n] of [[5, 13], [7, 16], [9, 16], [11, 24], [13, 32], [3, 32]]) bjorklund.push({ k, n, bits: euclid.bjorklund(k, n) });

const genres = Object.keys(gen.Genres);
const sizes = ['minimal', 'standard', 'extended', 'ab', 'drop', 'build', 'jam', 'bogus'];
const structures = [];
for (const genre of genres) for (const size of sizes) for (const seed of [1, 42]) {
  structures.push({ genre, size, seed, result: structure.generateStructure(genre, size, core.createRng(seed)) });
}

const themes = [];
for (const genre of genres) for (const seed of [1, 42, 20261008, 4294967295]) {
  themes.push({ genre, seed, supported: theme.cohesionGenreSupported(genre), theme: theme.buildTrackTheme(genre, seed) });
}
const motifs = [];
for (const t of themes.filter((x) => x.seed === 42 && x.supported)) {
  for (const mode of Object.values(theme.MotifMode)) for (const off of [0, 2, -3]) {
    motifs.push({ genre: t.genre, seed: 42, mode, offset: off, out: theme.renderMotif(t.theme.motif, mode, off) });
  }
}
writeFileSync0('modules.json', { meta, bjorklund, structures, themes, motifs });

// --- share envelopes ----------------------------------------------------

const payloads = [
  { genre: 'techno', seed: 42 },
  { genre: 'house', seed: 7, structure: 'standard' },
  { genre: 'jazz', seed: 12345, structure: 'extended', cohesion: 'v2' },
  { genre: 'lofi', seed: 99, structure: 'minimal', cohesion: 'v1' },
  { genre: 'dnb', seed: 3, tempo: 174, swing: 0.1, humanize: 0.25 },
  { genre: 'ambient', seed: 5, traits: { 'ghost-notes': 0.3, 'modal-interchange': 0.2 } },
  { genre: 'trance', seed: 8, macroCurve: [[0, 'build'], [16, 'drop']], fx: { reverbWet: 0.35 } },
  { genre: 'funk', seed: 11, tracks: { bass: { mute: true } }, name: 'Funk <&> "test" · é', note: 'tab\there 😀' },
  { genre: 'metal', seed: 2147483648, structure: 'loop', parents: ['zdj3abc'] },
  { genre: 'blues', seed: 1, cohesion: 'v3' },
  { b: 1, a: { z: 1, y: [3, 2, 1], '10': 'ten', '9': 'nine' }, genre: 'garage', seed: 0.5 },
];
const envelopes = [];
for (const payload of payloads) {
  const canonical = codec.canonicalizeJSON(payload);
  const cid = await codec.computeCidForJsonLd(payload);
  envelopes.push({ payload, canonical, cid, share: url.shareFromPayload(payload, cid) });
}
writeFileSync0('envelopes.json', { meta, envelopes });

// --- generated projects -------------------------------------------------

// (genre, seed, structure, cohesion) -> project -> canonical model JSON -> model CID.
// Full canonical text is stored for a handful (readable diffs, 2.3 round-trips);
// the rest carry length + sha256, which is enough to prove byte identity.
const FULL = new Set(['techno/42/loop/v2', 'jazz/7/standard/v1', 'dnb/3/extended/v2']);
const projects = [];
const projSizes = ['loop', 'minimal', 'standard', 'extended'];
for (const genre of genres) for (const size of projSizes) for (const cohesion of ['v1', 'v2']) for (const seed of [1, 42]) {
  const overrides = { seed, cohesion };
  if (size !== 'loop') overrides.structure = size;
  const proj = gen.compose(genre, overrides);
  const canonical = pflow.canonicalProjectJSON(proj);
  const key = `${genre}/${seed}/${size}/${cohesion}`;
  const entry = { genre, seed, structure: size, cohesion, name: proj.name, tempo: proj.tempo,
    nets: Object.keys(proj.nets).length, canonicalBytes: Buffer.byteLength(canonical), modelCID: sha256hex(canonical) };
  if (FULL.has(key)) entry.canonical = canonical;
  projects.push(entry);
}
// Determinism self-check: the oracle must agree with itself or the fixtures are noise.
{
  const a = pflow.canonicalProjectJSON(gen.compose('techno', { seed: 42, cohesion: 'v2' }));
  const b = pflow.canonicalProjectJSON(gen.compose('techno', { seed: 42, cohesion: 'v2' }));
  if (a !== b) throw new Error('compose is not deterministic in this process');
}
writeFileSync0('projects.json', { meta, projects });

function writeFileSync0(name, obj) {
  mkdirSync(outDir, { recursive: true });
  writeFileSync(path.join(outDir, name), JSON.stringify(obj) + '\n');
  console.log('wrote', name);
}
