#!/usr/bin/env node
// Share URL / gzip / raw-nets fixtures (ROADMAP 2.5 follow-up). Imports beats' real JS
// and records what it does; the Swift tests compare against that, never against a
// reading of the source.
//
//   source ~/.nvm/nvm.sh
//   BEATS_PUBLIC=~/Workspace/beats-bitwrap-io/public node scripts/beats-share-url.mjs [outDir]
//
// Output: Tests/DJCoreTests/Fixtures/beats/share-urls.json
//   urls[]   : JS-built share URLs (short + full with `z`), legacy `?p=` / `?g=` links,
//              tampered-CID and garbage links, with parseShareFromUrl's result for each.
//   rawNets[]: raw-`nets` payloads with the project JS builds for `project-load`
//              (name derivation lifted verbatim from petri-note.js) and its model digest.
//   gunzip[] : gzip streams from JS (CompressionStream) and node zlib, with the text
//              they decode to.
//   specPayloads[]: TrackSpec.payload's form (traits under `traits`) with shareFromPayload's
//              reading and compose's model CID, beside the old top-level-traits form.
// Swift-produced gzip is checked by a Swift round trip and by
// scripts/beats-share-url-check.mjs (JS decodes what Swift encoded).

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { gzipSync } from 'node:zlib';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC = path.resolve(process.env.BEATS_PUBLIC || path.join(process.env.HOME, 'Workspace/beats-bitwrap-io/public'));
const outDir = path.resolve(process.argv[2] || path.join(here, '../Tests/DJCoreTests/Fixtures/beats'));
const lib = (p) => import(pathToFileURL(path.join(PUBLIC, 'lib', p)).href);

const codec = await lib('share/codec.js');
const pflow = await lib('pflow.js');
const url = await lib('share/url.js');
const gen = await lib('generator/index.js');
const composer = await lib('generator/composer.js');

const sha256hex = (s) => createHash('sha256').update(s, 'utf8').digest('hex');
let beatsCommit = 'unknown';
try { beatsCommit = execFileSync('git', ['-C', PUBLIC, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(); } catch {}
const meta = { generator: 'scripts/beats-share-url.mjs', beatsCommit };

// deriveShareName is module-private in petri-note.js (a DOM module): lift it verbatim.
const pnSrc = readFileSync(path.join(PUBLIC, 'petri-note.js'), 'utf8');
const dm = pnSrc.match(/function deriveShareName\(share\) \{[\s\S]*?\n\}\n/);
if (!dm) throw new Error('deriveShareName not found in petri-note.js');
const deriveShareName = new Function('generateTrackName', `${dm[0]}; return deriveShareName;`)(composer.generateTrackName);

// Bad gzip input leaves an unhandled stream error in node (browsers swallow it).
process.on('uncaughtException', (e) => { if (e?.cause?.code !== 'Z_DATA_ERROR' && e?.code !== 'Z_DATA_ERROR') throw e; });
process.on('unhandledRejection', () => {});
const BASE ='https://beats.bitwrap.io/';
const parse = async (search) => {
  globalThis.location = { search, origin: 'https://beats.bitwrap.io', pathname: '/' };
  const warn = console.warn; console.warn = () => {};
  try { return await url.parseShareFromUrl({}); } finally { console.warn = warn; }
};

// Mirrors petri-note.js _bootGenerate's raw-nets branch up to (and excluding) arrange.
const bootRaw = (share) => {
  const proj = {
    name: share.name || deriveShareName(share),
    tempo: share.overrides?.tempo ?? 120,
    swing: share.overrides?.swing ?? 0,
    humanize: share.overrides?.humanize ?? 0,
    nets: share.nets,
  };
  if (share.overrides?.initialMutes) proj.initialMutes = share.overrides.initialMutes;
  if (share.overrides?.fx) proj.fx = share.overrides.fx;
  return proj;
};
const digestOf = (rawProj) => {
  const p = pflow.parseProject(JSON.parse(JSON.stringify(rawProj)));
  const canonical = pflow.canonicalProjectJSON(p);
  return { name: p.name, tempo: p.tempo, canonicalBytes: Buffer.byteLength(canonical), modelCID: sha256hex(canonical),
    docSha: sha256hex(JSON.stringify(pflow.projectToJSON(p))) };
};

const netsOf = (genre, seed, structure) => {
  const ov = { seed, cohesion: 'v2' };
  if (structure) ov.structure = structure;
  const proj = gen.compose(genre, ov);
  for (const [id, nb] of Object.entries(proj.nets)) if (!(nb instanceof pflow.NetBundle)) proj.nets[id] = pflow.parseNetBundle(nb);
  return JSON.parse(JSON.stringify(pflow.projectToJSON(proj))).nets;
};

const payloads = [
  { genre: 'techno', seed: 42 },
  { genre: 'house', seed: 7, structure: 'standard', cohesion: 'v2', tempo: 126 },
  { genre: 'funk', seed: 11, cohesion: 'v2', name: 'Funk <&> "test" · é', note: 'tab\there 😀  ', parents: ['zdj3abc'] },
  { genre: 'ambient', seed: 5, traits: { 'ghost-notes': 0.3 }, macroCurve: [[0, 'build'], [16, 'drop']] },
];
const rawPayloads = [
  { genre: 'techno', name: 'Hand Made', tempo: 133, swing: 0.2, humanize: 0.1, nets: netsOf('techno', 42), initialMutes: ['bass'] },
  { genre: 'jazz', name: 'Looped', structure: 'loop', nets: netsOf('jazz', 7), fx: { reverbWet: 0.3 } },
  { genre: 'house', nets: netsOf('house', 3) },                       // nameless: name derived from the CID
  { nets: netsOf('dnb', 9), tempo: 174 },                             // nameless, genreless
  { genre: 'lofi', nets: netsOf('lofi', 5, 'minimal'), structure: 'standard', arrangeSeed: 4, maxVariants: 2 }, // needs arrange
  { genre: 'trance', name: 'Odd é <b>', nets: { 'x': { places: { p: { initial: [1] } }, transitions: { t: {} }, arcs: [{ source: 'p', target: 't' }], track: { channel: 3, instrument: 'lead' } }, 'bad': 5 } },
];

const urls = [];
const addUrl = async (label, search, extra = {}) => urls.push({ label, search, share: await parse(search), ...extra });
for (const payload of payloads) {
  const canonical = codec.canonicalizeJSON(payload);
  const cid = await codec.computeCidForJsonLd(payload);
  const z = await codec.gzipToB64Url(canonical);
  urls.push({ label: 'full', payload, canonical, cid, z, url: `${BASE}?cid=${cid}&z=${z}`, search: `?cid=${cid}&z=${z}`,
    share: await parse(`?cid=${cid}&z=${z}`) });
  // short links need a network fetch; the Swift side must report the CID it needs.
  urls.push({ label: 'short', payload, cid, url: `${BASE}?cid=${cid}`, search: `?cid=${cid}`, needsFetch: true });
}
{
  const payload = payloads[0];
  const cid = await codec.computeCidForJsonLd(payload);
  const z = await codec.gzipToB64Url(codec.canonicalizeJSON({ ...payload, seed: 43 }));
  await addUrl('tampered: z holds a different payload', `?cid=${cid}&z=${z}`);
  await addUrl('garbage z', `?cid=${cid}&z=!!!notbase64`);
  await addUrl('z is valid base64 but not gzip', `?cid=${cid}&z=${Buffer.from('hello').toString('base64url')}`);
}
// legacy links
await addUrl('legacy p', `?p=${codec.b64urlEncode({ genre: 'techno', params: { seed: 5 }, extra: [1, 2] })}`);
await addUrl('legacy p without genre', `?p=${codec.b64urlEncode({ seed: 5 })}`);
await addUrl('legacy g only', '?g=house');
await addUrl('legacy g/s/structure', '?g=dnb&s=77&structure=extended');
await addUrl('legacy g/s/t', `?g=jazz&s=12&t=${codec.b64urlEncode({ 'ghost-notes': 0.4, cohesion: 'v2' })}`);
await addUrl('legacy bad seed', '?g=jazz&s=abc');
await addUrl('legacy seed prefix', '?g=jazz&s=12abc');
await addUrl('legacy t not an object', `?g=jazz&t=${codec.b64urlEncode('str')}`);
await addUrl('no params', '');
await addUrl('unrelated params', '?foo=bar');
await addUrl('percent-encoded genre', '?g=drum%20and%20bass');
await addUrl('plus in value', '?g=a+b');

const rawNets = [];
for (const payload of rawPayloads) {
  const canonical = codec.canonicalizeJSON(payload);
  const cid = await codec.computeCidForJsonLd(payload);
  const z = await codec.gzipToB64Url(canonical);
  const search = `?cid=${cid}&z=${z}`;
  const share = await parse(search);
  const boot = bootRaw(share);
  const entry = { payload, cid, search, share };
  entry.needsArrange = !!(share.structure && share.structure !== 'loop');
  try { entry.project = digestOf(boot); } catch (e) { entry.projectError = String(e); }
  rawNets.push(entry);
}

// TrackSpec.payload (SessionModel.swift): the form the app writes for a deck's track, traits
// under `traits` where shareFromPayload reads them. Each payload is written in that form; JS's
// reading of it and the project compose builds from its params are recorded, and so is the
// older form (traits spread at the top level), which beats reads without its traits.
const composedDigest = (genre, params) => {
  const proj = gen.compose(genre, JSON.parse(JSON.stringify(params)));
  for (const [id, nb] of Object.entries(proj.nets)) if (!(nb instanceof pflow.NetBundle)) proj.nets[id] = pflow.parseNetBundle(nb);
  return sha256hex(pflow.canonicalProjectJSON(proj));
};
const specPayloads = [];
for (const payload of [
  { genre: 'house', seed: 7, structure: 'standard', cohesion: 'v2', traits: { bpm: 126 } },
  { genre: 'trance', seed: 27, structure: 'standard', cohesion: 'v1', traits: { 'tension-curve': true, 'modal-interchange': 0.35, bpm: 133 } },
  { genre: 'ambient', seed: 5, cohesion: 'v2', macroCurve: [[0, 'build'], [16, 'drop']], traits: { 'ghost-notes': 0.3, bpm: 90 } },
  { genre: 'techno', seed: 42, cohesion: 'v2', traits: { bpm: 131 }, tempo: 140, initialMutes: ['bass'], fadeIn: [{ target: 'bass' }] },
]) {
  const cid = await codec.computeCidForJsonLd(payload);
  const share = url.shareFromPayload(payload, cid);
  const { traits, ...rest } = payload;
  const oldPayload = { ...rest, ...traits };
  const oldShare = url.shareFromPayload(oldPayload, await codec.computeCidForJsonLd(oldPayload));
  specPayloads.push({ payload, cid, share, modelCID: composedDigest(share.genre, share.params),
    oldPayload, oldParams: oldShare.params, oldModelCID: composedDigest(oldShare.genre, oldShare.params) });
}

// gzip streams
const texts = ['', 'a', '{"genre":"techno","seed":42}', 'x'.repeat(100000), 'héllo 😀   \u0000 end',
  JSON.stringify(rawPayloads[0])];
const gunzip = [];
for (const t of texts) {
  gunzip.push({ label: 'js CompressionStream', text: t, z: await codec.gzipToB64Url(t) });
  gunzip.push({ label: 'node zlib level 9', text: t, z: gzipSync(Buffer.from(t, 'utf8'), { level: 9 }).toString('base64url') });
  gunzip.push({ label: 'node zlib level 0 (stored)', text: t, z: gzipSync(Buffer.from(t, 'utf8'), { level: 0 }).toString('base64url') });
}
// every entry must round trip in JS itself, so a bad fixture cannot be written
for (const g of gunzip) if ((await codec.b64UrlToGunzip(g.z)) !== g.text) throw new Error('fixture self-check failed: ' + g.label);

mkdirSync(outDir, { recursive: true });
writeFileSync(path.join(outDir, 'share-urls.json'), JSON.stringify({ meta, base: BASE, urls, rawNets, gunzip, specPayloads }) + '\n');
console.log('wrote share-urls.json');
