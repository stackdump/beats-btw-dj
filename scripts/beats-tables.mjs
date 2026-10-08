#!/usr/bin/env node
// Lift beats' generator data tables (genres, theory, instrument sets, structure
// blueprints, energy profiles, name words, ...) into one JSON resource the Swift
// composer loads. The tables are DATA; transcribing ~1500 lines of them by hand
// would be the most error-prone part of the port, so they are generated from the
// JS and the Swift parity tests prove the composer built on them matches beats.
//
//   BEATS_PUBLIC=~/Workspace/beats-bitwrap-io/public node scripts/beats-tables.mjs
//
// Output: Sources/DJCore/Resources/beats/tables.json   (deterministic)
//
// Public exports are read straight from the modules. Module-private `const`s are
// lifted from the source text with a bracket-matching scanner and evaluated, so
// they cannot drift either.

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC = path.resolve(process.env.BEATS_PUBLIC || path.join(process.env.HOME, 'Workspace/beats-bitwrap-io/public'));
const out = path.resolve(process.argv[2] || path.join(here, '../Sources/DJCore/Resources/beats/tables.json'));
const gdir = path.join(PUBLIC, 'lib/generator');
const mod = (f) => import(pathToFileURL(path.join(gdir, f)).href);

// --- source lifting ---

function skipString(src, i) {
  const q = src[i]; i++;
  while (i < src.length) {
    if (src[i] === '\\') { i += 2; continue; }
    if (src[i] === q) return i + 1;
    i++;
  }
  throw new Error('unterminated string');
}

/** End index (exclusive) of the top-level statement starting at `start` (a `const` decl). */
function statementEnd(src, start) {
  let depth = 0, i = start;
  while (i < src.length) {
    const c = src[i];
    if (c === '"' || c === "'" || c === '`') { i = skipString(src, i); continue; }
    if (c === '/' && src[i + 1] === '/') { while (i < src.length && src[i] !== '\n') i++; continue; }
    if (c === '/' && src[i + 1] === '*') { i = src.indexOf('*/', i) + 2; continue; }
    if ('([{'.includes(c)) depth++;
    else if (')]}'.includes(c)) depth--;
    else if (c === ';' && depth === 0) return i + 1;
    i++;
  }
  throw new Error('no statement end');
}

function lift(file, names, ctx = {}) {
  const src = readFileSync(path.join(gdir, file), 'utf8');
  const stmts = names.map((n) => {
    const m = new RegExp(`^[ \\t]*(?:export )?const ${n} = `, 'm').exec(src);
    if (!m) throw new Error(`${n} not found in ${file}`);
    return src.slice(m.index, statementEnd(src, m.index)).trim().replace(/^export /, '');
  });
  const keys = Object.keys(ctx);
  const fn = new Function(...keys, `${stmts.join('\n')}\nreturn { ${names.join(', ')} };`);
  return fn(...keys.map((k) => ctx[k]));
}

// --- gather ---

const core = await mod('core.js');
const composer = await mod('composer.js');
const theory = await mod('theory.js');
const theme = await mod('theme.js');

const scaleNames = { MajorScale: 1, MinorScale: 1, DorianScale: 1, PentatonicScale: 1, MinPentatonicScale: 1, BluesScale: 1, MixolydianScale: 1, PhrygianScale: 1, HarmonicMinScale: 1 };
const genres = {};
for (const [id, g] of Object.entries(composer.Genres)) {
  const { scale, theory: th, ...rest } = g;
  if (!scaleNames[scale.name]) throw new Error(`unknown scale function ${scale.name}`);
  if (th !== theory.GenreTheories[id]) throw new Error(`genre ${id} theory is not GenreTheories[${id}]`);
  genres[id] = { ...rest, scale: scale.name };
}

const structureConsts = lift('structure.js',
  ['sectionArchetypes', 'sectionArchetypesByFamily', 'genreFamilies', 'structureBlueprints'],
  { familyEDM: 0, familySong: 1, familyJazz: 2, familyChill: 3 });

const composerConsts = lift('composer.js', ['STINGER_SPECS', 'STINGER_INSTRUMENT_SET', 'FALLBACK_SETS']);
const nameWords = lift('composer.js', ['adjectives', 'nouns']);

// Per-genre theme tables (functions of the genre only).
const themeTables = {};
for (const id of Object.keys(composer.Genres)) {
  const family = theme.familyFor(id);
  themeTables[id] = {
    family,
    groove: theme.defaultGrooveFor(id),
    supported: theme.cohesionGenreSupported(id),
    energy: theme.energyProfilesFor(family, id),
  };
}

// Section-name predicates used by composer.js live in code, not data; nothing to lift.

let beatsCommit = 'unknown';
try { beatsCommit = execFileSync('git', ['-C', PUBLIC, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(); } catch {}

const tables = {
  meta: { generator: 'scripts/beats-tables.mjs', beatsCommit },
  grooves: theme.Groove,
  motifModes: theme.MotifMode,
  genres,
  theories: theory.GenreTheories,
  instrumentSets: composer.GenreInstrumentSets,
  minorChordProg: core.MinorChordProg,
  majorChordProg: core.MajorChordProg,
  themes: themeTables,
  structure: structureConsts,
  stingers: composerConsts,
  nameWords,
};

mkdirSync(path.dirname(out), { recursive: true });
writeFileSync(out, JSON.stringify(tables) + '\n');
console.log('wrote', path.relative(process.cwd(), out), `(${JSON.stringify(tables).length} bytes)`);
