#!/usr/bin/env node
// Second oracle (ROADMAP 2.7): run beats' Go generator on every case the JS fixtures
// cover and record its model CIDs next to the JS ones.
//
//   BEATS_REPO=~/Workspace/beats-bitwrap-io node scripts/beats-go-oracle.mjs
//
// Needs `go` on PATH and a beats checkout (the driver is copied into
// $BEATS_REPO/tools/dj-vevr-go-oracle for the run and removed afterwards).
// Output: Tests/DJCoreTests/Fixtures/beats/go.json
//   { cases: [{ id, genre, overrides, js: {bytes, cid}, go: {bytes, cid, name}, agree }] }
// `agree` is recorded, not asserted: where Go and JS differ the fixture says so and
// the Swift tests pin which side Swift follows (the JS, which is what shipped links use).

import { readFileSync, writeFileSync, mkdirSync, rmSync, copyFileSync } from 'node:fs';
import { spawnSync, execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { pathToFileURL } from 'node:url';
const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(process.env.BEATS_REPO || path.join(process.env.HOME, 'Workspace/beats-bitwrap-io'));
const fx = path.join(here, '../Tests/DJCoreTests/Fixtures/beats');
const load = (n) => JSON.parse(readFileSync(path.join(fx, n), 'utf8'));

// --- the cases: everything the JS fixtures already pin ---
const cases = [];
for (const p of load('projects.json').projects) {
  const overrides = { seed: p.seed, cohesion: p.cohesion };
  if (p.structure !== 'loop') overrides.structure = p.structure;
  cases.push({ id: `matrix/${p.genre}/${p.seed}/${p.structure}/${p.cohesion}`, genre: p.genre, overrides, js: { bytes: p.canonicalBytes, cid: p.modelCID } });
}
for (const c of load('compose.json').cases) {
  cases.push({ id: `compose/${c.genre}/${JSON.stringify(c.overrides)}`, genre: c.genre, overrides: c.overrides, js: { bytes: c.canonicalBytes, cid: c.modelCID } });
}
for (const e of load('envelopes.json').envelopes) {
  if (!e.project) continue;
  cases.push({ id: `envelope/${e.cid}`, genre: e.share.genre, overrides: e.share.params, js: { bytes: e.project.canonicalBytes, cid: e.project.modelCID } });
}

// --- JS per-net digests (loop matrix cases only: keeps the fixture small) ---
const PUBLIC = path.join(repo, 'public');
const gen = await import(pathToFileURL(path.join(PUBLIC, 'lib/generator/index.js')).href);
const pflow = await import(pathToFileURL(path.join(PUBLIC, 'lib/pflow.js')).href);
const src = readFileSync(path.join(PUBLIC, 'lib/pflow.js'), 'utf8');
const m = src.match(/function canonicalStringify\(v\) \{[\s\S]*?\n\}\n/);
const canonicalStringify = new Function(`${m[0]}; return canonicalStringify;`)();
const sha = (s) => createHash('sha256').update(s, 'utf8').digest('hex');
// Go gives every drum voice MIDI channel 10; JS gives kick/snare/hihat/clap 10/11/12/13.
// `drumChannelsTo10` re-maps JS output so the rest of the comparison is not drowned by it.
const drumChannelsTo10 = (doc) => {
  for (const n of Object.values(doc.nets)) for (const t of Object.values(n.transitions)) {
    if (t.midi && t.midi.channel >= 10 && t.midi.channel <= 15) t.midi.channel = 10;
  }
  return doc;
};
const jsDoc = (c) => {
  const proj = gen.compose(c.genre, JSON.parse(JSON.stringify(c.overrides)));
  for (const [id, nb] of Object.entries(proj.nets)) if (!(nb instanceof pflow.NetBundle)) proj.nets[id] = pflow.parseNetBundle(nb);
  const canon = pflow.canonicalProjectJSON(proj);
  const doc = JSON.parse(canon);
  if (canonicalStringify(doc) !== canon) throw new Error('canonicalStringify(parse(canon)) != canon');
  return doc;
};
const jsPerNet = (doc) => Object.fromEntries(Object.entries(doc.nets).map(([id, n]) => [id, sha(canonicalStringify(n))]));

// --- run the Go side inside the beats module ---
const dir = path.join(repo, 'tools', 'dj-vevr-go-oracle');
mkdirSync(dir, { recursive: true });
let out;
try {
  copyFileSync(path.join(here, '../tools/_go-oracle/main.go'), path.join(dir, 'main.go'));
  const r = spawnSync('go', ['run', './tools/dj-vevr-go-oracle'], {
    cwd: repo, input: JSON.stringify(cases.map(({ id, genre, overrides }) => ({ id, genre, overrides }))),
    encoding: 'utf8', maxBuffer: 1 << 28,
  });
  if (r.status !== 0) { console.error(r.stderr); throw new Error(`go run failed (${r.status})`); }
  out = JSON.parse(r.stdout);
} finally {
  rmSync(dir, { recursive: true, force: true });
}

let beatsCommit = 'unknown', goVersion = 'unknown';
try { beatsCommit = execFileSync('git', ['-C', repo, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(); } catch {}
try { goVersion = execFileSync('go', ['version'], { encoding: 'utf8' }).trim(); } catch {}

const byId = new Map(out.map((o) => [o.id, o]));
const rows = cases.map((c) => {
  const g = byId.get(c.id);
  const row = { id: c.id, genre: c.genre, overrides: c.overrides, js: c.js, go: { bytes: g.bytes, cid: g.cid, name: g.name, nets: g.nets }, agree: g.cid === c.js.cid };
  const doc = drumChannelsTo10(jsDoc(c));
  const mapped = canonicalStringify(doc);
  row.jsDrumCh10 = { bytes: Buffer.byteLength(mapped), cid: sha(mapped) };
  row.agreeModuloDrumChannel = g.cid === row.jsDrumCh10.cid;
  if (c.id.startsWith('matrix/') && c.id.includes('/loop/')) {
    const js = jsPerNet(doc);
    // Only the nets Go and JS both produce identically are recorded, with the Go digest
    // (== the JS digest): Swift is checked against it. `onlyJs` / `onlyGo` / `differ` name the rest.
    row.nets = { same: {}, differ: [], onlyJs: [], onlyGo: [] };
    for (const id of Object.keys(js)) {
      if (!(id in g.perNet)) row.nets.onlyJs.push(id);
      else if (g.perNet[id] === js[id]) row.nets.same[id] = js[id].slice(0, 16);
      else row.nets.differ.push(id);
    }
    for (const id of Object.keys(g.perNet)) if (!(id in js)) row.nets.onlyGo.push(id);
  }
  return row;
});
const agree = rows.filter((r) => r.agree).length;
console.log(`${agree}/${rows.length} cases: Go model CID == JS model CID`);
console.log(`${rows.filter((r) => r.agreeModuloDrumChannel).length}/${rows.length} cases: equal once JS drum channels 11-13 are mapped to Go's 10`);
mkdirSync(fx, { recursive: true });
writeFileSync(path.join(fx, 'go.json'), JSON.stringify({ meta: { generator: 'scripts/beats-go-oracle.mjs', beatsCommit, goVersion }, cases: rows }) + '\n');
for (const r of rows.filter((x) => !x.agreeModuloDrumChannel).slice(0, 15)) console.log('DIFF', r.id, 'js', r.jsDrumCh10.bytes, 'go', r.go.bytes);
