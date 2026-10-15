// Compose a (genre, seed, structure) with beats' canonical JS generator and run the
// whole song through the wave engine's net executor, collecting every audible note.
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const PUBLIC = path.join(process.env.HOME, 'Workspace/beats-bitwrap-io/public');
const imp = (p) => import(pathToFileURL(path.join(PUBLIC, p)).href);

const { compose, Genres } = await imp('lib/generator/composer.js');
const { projectToJSON } = await imp('lib/pflow.js');
const { compileProject, tick } = await imp('wave-engine/net.js');

export const GENRES = Object.keys(Genres);

export function roleOf(id, group) {
  if (group) return group;
  return id.replace(/-\d+$/, '');
}

export function songEvents(genre, seed, structure = 'standard', maxTicks = 20000) {
  const params = { seed };
  if (structure && structure !== 'loop') params.structure = structure;
  const json = projectToJSON(compose(genre, params));
  const g = compileProject(json);
  const events = [];
  const slotActivations = []; // [tick, targetNetId]
  const total = (json.structure || []).reduce((a, s) => a + s.steps, 0) || 256;
  let ticks = 0;
  while (!g.stopRequested && ticks < Math.min(maxTicks, total)) {
    tick(g, (n, t) => {
      events.push({
        tick: g.tick - 1, net: n.id, role: roleOf(n.id, n.group), note: n.note[t],
        vel: n.vel[t], durMs: n.durMs[t], channel: n.bundle.track?.channel,
        instrument: n.bundle.track?.instrument,
      });
    });
    for (let i = 0; i < g.controlCount; i += 2) {
      const n = g.nets[g.controls[i]];
      const t = g.controls[i + 1];
      if (n.action[t] === 7) slotActivations.push([g.tick - 1, n.actionTarget[t]]);
    }
    ticks++;
  }
  const ringSize = {};
  for (const n of g.nets) ringSize[n.id] = n.P;
  return { json, events, ticks, slotActivations, ringSize };
}
